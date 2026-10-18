/// ARTI geometrically-gated online reference updater + deploy-time
/// guided fade routine + between-sortie batch-refit export.
///
/// RX-only, defensive-only: everything here listens, measures, and adapts
/// reference levels. Nothing transmits, jams, deauths, spoofs, or probes.
///
/// Method ported from Kaltiokallio, Jäntti & Patwari, IEEE TVT 2017
/// (ARTI — full read; CONFIRMED single-person, indoor/through-wall,
/// static nodes). What ports is the *method* (anti-blend gating,
/// far/near split, signed phi); the paper's accuracy numbers do NOT
/// port to Shepherd's regime (6 nodes, dismounted, on the move,
/// airborne Group 2–3 UAS) and are never cited as targets.
///
/// Shepherd adaptations (the gaps the paper leaves):
///  - TRUE band wavelengths (0.125 m @ 2.4 GHz, 0.33 m @ 915 MHz,
///    0.69 m @ 433 MHz) — NEVER the paper's λ0 = 0.05 m geometry-fit
///    constant, which is meaningless at our bands and altitudes.
///  - 3D excess-path geometry from live node fixes (the paper is 2D).
///  - Divergence safeguard (the paper has none): |mu − mu_calib| capped
///    at 6 dB; exceeding marks the link suspect and freezes it.
///  - Mobility recompute (the paper's nodes are static): any node
///    moving > 1 m recomputes excess-path geometry before the split.
///  - Multi-target: a link near ANY track is near (conservative — more
///    frozen mu, less drift tracking).
///  - Vacant-window learning: with no track present the residual/motion
///    gates pass vacuously — drift is safest to learn when nothing is
///    there to blend into it. (The paper's gates assume a subject is
///    always present.)
///
/// The loitering-target behavior is load-bearing, not a bug: a
/// stationary target (speed ≤ 0.2 m/s) FREEZES all mu/phi updates, so a
/// loitering UAS can never blend into the baseline. While frozen, slow
/// environmental drift accumulates uncompensated — the divergence
/// safeguard watches, and a long loiter is a recalibration event.
///
/// Integration: this service sits NEXT TO Tripwire, not inside it.
/// Detection stays deterministic; ARTI never suppresses an alert. It
/// feeds the detector (a) mu_calib anchors, (b) drift-compensated mu
/// for the fade-level computation, and (c) phi sign for the
/// fade-signed deviation.
library;

import 'dart:math' as math;

import '../models/tracking.dart';

/// Tunables for the ARTI updater. Defaults are the paper's values
/// (EWMA alpha 0.90, phi_0 −1e-3, motion gate 0.2 m/s) plus Shepherd's
/// divergence/mobility additions.
class AdaptiveBaselineConfig {
  const AdaptiveBaselineConfig({
    this.ewmaAlpha = 0.90,
    this.phi0 = -1e-3,
    this.motionGateMps = 0.2,
    this.residualGateMadMult = 2.0,
    this.divergenceCapDb = 6.0,
    this.mobilityRecomputeM = 1.0,
    this.excessPathLambdaMult = 2.0,
    this.telemetryBufferSize = 2000,
  });

  /// EWMA weight on the OLD reference (paper: 0.90).
  final double ewmaAlpha;

  /// Initial signed magnitude (paper: −1e-3, slightly negative so the
  /// sign flips fast; ~a third of links start wrongly signed and
  /// self-correct within one pass — normal, logged, not "fixed").
  final double phi0;

  /// Target speed above which updates run (paper: 0.2 m/s).
  final double motionGateMps;

  /// Residual gate = this × the link's MAD threshold (disturbance
  /// units — the Shepherd adaptation of the paper's 1.0 m).
  final double residualGateMadMult;

  /// |mu − mu_calib| cap in dB. Exceeding marks the link suspect and
  /// freezes its updates (divergence safeguard; the paper has none).
  final double divergenceCapDb;

  /// Node movement beyond this (m) triggers a geometry recompute
  /// before the far/near split.
  final double mobilityRecomputeM;

  /// Far/near split at excess-path delta > this × λ_band.
  final double excessPathLambdaMult;

  /// Bounded ring buffer for batch-refit telemetry export.
  final int telemetryBufferSize;
}

/// True physical wavelengths per band — λ = c/f. NEVER the paper's
/// λ0 = 0.05 m (a 2.4 GHz-geometry fit constant, meaningless at our
/// bands and altitudes).
class BandWavelength {
  BandWavelength._();

  static const double _c = 299792458.0;

  static double meters(double freqMhz) => _c / (freqMhz * 1e6);

  /// Band label → center frequency in MHz. Labels come from link keys
  /// (`sdr:band-433`) or explicit registration. Unknown labels fall
  /// back to 2437 MHz (documented guess, not a measurement).
  static double forBandLabel(String band) {
    final b = band.toLowerCase();
    if (b.contains('433')) return 433.92;
    if (b.contains('915') || b.contains('900')) return 915.0;
    if (b.contains('1290')) return 1290.0;
    if (b.contains('5780') || b.contains('5g') || b.contains('5.8')) {
      return 5780.0;
    }
    if (b.contains('1865') || b.contains('1.8') || b.contains('lte')) {
      return 1865.0;
    }
    if (b.contains('24')) return 2437.0;
    return 2437.0;
  }
}

/// One ARTI update input: a link-channel-direction's current level.
///
/// `direction` is 'dip' (RSS-decrease channel) or 'rise'
/// (RSS-increase channel) — the direction-split Δr the imaging spec
/// makes first-class.
class ArtiSample {
  const ArtiSample({
    required this.linkKey,
    required this.channel,
    required this.direction,
    required this.level,
    required this.madThreshold,
  });

  final String linkKey;
  final String channel;
  final String direction;
  final double level;
  final double madThreshold;
}

/// Per-entry ARTI state (one link × channel × direction).
class ArtiEntry {
  ArtiEntry({
    required this.linkKey,
    required this.channel,
    required this.direction,
    required this.bandMhz,
    required double mu0,
    required double phi0,
  })  : mu = mu0,
        phi = phi0,
        muCalib = mu0;

  final String linkKey;
  final String channel;
  final String direction;
  final double bandMhz;

  /// Online reference RSS (drift-compensated).
  double mu;

  /// Signed disturbance magnitude; weight w = sgn(phi).
  double phi;

  /// Deploy-time calibration anchor (divergence safeguard reference).
  double muCalib;

  /// True once |mu − muCalib| exceeded the cap: updates frozen.
  bool suspect = false;

  String get key => '$linkKey@$channel@$direction';

  double get driftDb => (mu - muCalib).abs();
}

/// 1/min aggregate ARTI runtime stats (schema in the spec).
class ArtiStats {
  ArtiStats();

  int gatedResidual = 0;
  int gatedMotion = 0;
  int gatedNear = 0;
  int updated = 0;
  int geomRecompute = 0;
  final Set<String> suspectLinks = {};
  double maxMuDriftDb = 0.0;

  /// linkKey → held-poll count, with the ARTI mu at hold time (the
  /// spec's "baseline-hold events carry the ARTI mu").
  final Map<String, double> holdingMu = {};

  Map<String, dynamic> toJson(DateTime t) => {
        'v': 1,
        'kind': 'arti_stats',
        't': t.toUtc().millisecondsSinceEpoch / 1000.0,
        'gated_residual': gatedResidual,
        'gated_motion': gatedMotion,
        'gated_near': gatedNear,
        'updated': updated,
        'suspect_links': suspectLinks.toList()..sort(),
        'max_mu_drift_db': maxMuDriftDb,
        'geom_recompute': geomRecompute,
        'holding_mu': Map.of(holdingMu),
      };
}

/// One deploy-time guided-routine ("Dial it in" port) calibration record.
class CalibrationRecord {
  CalibrationRecord({
    required this.t0,
    required this.t1,
    required this.vacantSecs,
    required this.rounds,
    required this.degraded,
    required this.links,
    this.pathlossN,
    this.pathlossR0Db,
    this.pathlossRmseDb,
  });

  final DateTime t0;
  final DateTime t1;
  final double vacantSecs;
  final int rounds;
  final bool degraded;
  final List<CalibrationLink> links;
  final double? pathlossN;
  final double? pathlossR0Db;
  final double? pathlossRmseDb;

  /// Worst fade first — the guided routine's ranked list.
  List<CalibrationLink> get worstFirst {
    final l = links.toList()..sort((a, b) => a.fadeDb.compareTo(b.fadeDb));
    return l;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'kind': 'calibration',
        't0': t0.toUtc().millisecondsSinceEpoch / 1000.0,
        't1': t1.toUtc().millisecondsSinceEpoch / 1000.0,
        'vacant_s': vacantSecs,
        'rounds': rounds,
        'degraded': degraded,
        'pathloss': {
          'n': pathlossN,
          'r0_db': pathlossR0Db,
          'rmse_db': pathlossRmseDb,
        },
        'links': [for (final l in links) l.toJson()],
      };
}

class CalibrationLink {
  CalibrationLink({
    required this.link,
    required this.band,
    required this.fadeDb,
    required this.muCalibDbm,
  });

  final String link;
  final String band;
  final double fadeDb;
  final double muCalibDbm;

  Map<String, dynamic> toJson() => {
        'link': link,
        'band': band,
        'fade_db': fadeDb,
        'mu_calib_dbm': muCalibDbm,
      };
}

/// ARTI online updater + guided calibration routine.
class AdaptiveBaseline {
  AdaptiveBaseline({AdaptiveBaselineConfig? config})
      : config = config ?? const AdaptiveBaselineConfig();

  final AdaptiveBaselineConfig config;

  final Map<String, ArtiEntry> _entries = {};
  final ArtiStats stats = ArtiStats();

  /// Last-seen 3D node positions for the mobility recompute.
  Map<String, (double x, double y, double z)> _lastNodePos = {};

  /// Bounded telemetry ring buffer for the between-sortie batch refit.
  final List<Map<String, dynamic>> _telemetry = [];

  /// Collect refit telemetry points (bounded). Off by default —
  /// enable during a sortie you intend to refit.
  bool recordTelemetry = false;

  Map<String, ArtiEntry> get entries => Map.unmodifiable(_entries);

  Set<String> get suspectLinkKeys => {
        for (final e in _entries.values)
          if (e.suspect) e.linkKey,
      };

  /// Register a link-channel-direction. The paper's no-calibration
  /// startup is honored: the first sample becomes mu when nothing was
  /// registered explicitly.
  ArtiEntry register({
    required String linkKey,
    required String channel,
    required String direction,
    required double mu0,
    double? bandMhz,
  }) {
    final key = '$linkKey@$channel@$direction';
    return _entries.putIfAbsent(
      key,
      () => ArtiEntry(
        linkKey: linkKey,
        channel: channel,
        direction: direction,
        bandMhz: bandMhz ?? BandWavelength.forBandLabel(channel),
        mu0: mu0,
        phi0: config.phi0,
      ),
    );
  }

  /// One ARTI update cycle over a batch of link samples.
  ///
  /// [tracks] is the tracker's current estimate list (empty when the
  /// air is clear — vacant-window learning). [nodes] are live 3D
  /// fixes for the excess-path geometry. [heldLinks] optionally maps
  /// linkKey → held-poll count from the tripwire's baseline hold, so
  /// the stats carry the ARTI mu at hold start/end.
  void update({
    required DateTime now,
    required List<ArtiSample> samples,
    required List<TrackEstimate> tracks,
    required Map<String, NodePosition> nodes,
    Map<String, int> heldLinks = const {},
  }) {
    _mobilityCheck(nodes);
    final vacant = tracks.isEmpty;
    final maxSpeed = _maxTrackSpeed(tracks);
    final motionOpen = vacant || maxSpeed > config.motionGateMps;

    for (final s in samples) {
      if (!s.level.isFinite || !s.madThreshold.isFinite) continue;
      final entry = register(
        linkKey: s.linkKey,
        channel: s.channel,
        direction: s.direction,
        mu0: s.level,
      );
      if (entry.suspect) continue; // frozen by the divergence safeguard

      final lambda = BandWavelength.meters(entry.bandMhz);
      final near = vacant ? false : _isNearAnyTrack(entry, s, tracks, nodes, lambda);

      // Residual gate (disturbance units): the track estimate must be
      // consistent with the measurement before the measurement teaches
      // the REFERENCE. It guards far-link mu updates only — near links
      // never touch mu (anti-blend), they only update phi, and phi is
      // explicitly the learned disturbance magnitude: gating it on its
      // own unlearned value would deadlock learning. A wrong phi just
      // self-corrects on the next pass (the paper's CONFIRMED
      // behavior); a contaminated mu does not.
      var residualOk = true;
      if (!vacant && !near) {
        final obs = _observedDisturbance(s.direction, s.level, entry.mu);
        final predicted = _predictedDisturbance(entry, s, tracks, nodes, lambda);
        final residual = (obs - predicted).abs();
        residualOk =
            residual <= config.residualGateMadMult * s.madThreshold;
      }
      if (!residualOk) {
        stats.gatedResidual++;
        continue;
      }
      if (!motionOpen) {
        stats.gatedMotion++;
        continue;
      }
      if (near) {
        // Anti-blend: near links update phi ONLY — mu is untouched, so
        // the target never contaminates its own reference.
        final obs = _observedDisturbance(s.direction, s.level, entry.mu);
        final signed = s.direction == 'dip' ? -obs : obs;
        final a = config.ewmaAlpha;
        entry.phi = a * entry.phi + (1 - a) * signed;
        stats.gatedNear++;
        _noteTelemetry(now, entry, s, tracks, near: true);
      } else {
        final a = config.ewmaAlpha;
        entry.mu = a * entry.mu + (1 - a) * s.level;
        stats.updated++;
        // Divergence safeguard: the paper has none; we need one. A
        // runaway estimator is worse than a stale one.
        if (entry.driftDb > config.divergenceCapDb) {
          entry.suspect = true;
          stats.suspectLinks.add(entry.linkKey);
        }
        _noteTelemetry(now, entry, s, tracks, near: false);
      }
      if (entry.driftDb > stats.maxMuDriftDb) {
        stats.maxMuDriftDb = entry.driftDb;
      }
    }

    for (final e in heldLinks.entries) {
      final mu = _entries.values
          .where((en) => en.linkKey == e.key)
          .map((en) => en.mu)
          .firstOrNull;
      if (mu != null) stats.holdingMu[e.key] = mu;
    }
  }

  /// Drift-compensated reference for one link-channel-direction, or
  /// null when unregistered or suspect (frozen).
  double? muFor(String linkKey, String channel, String direction) {
    final e = _entries['$linkKey@$channel@$direction'];
    if (e == null || e.suspect) return null;
    return e.mu;
  }

  /// Drift-compensated reference for a whole link (mean of its
  /// non-suspect entry mus), or null when the link has no usable ARTI
  /// state. This is feed (b) of the spec's integration contract: it
  /// goes to the tripwire's fade-level (F_l) computation ONLY — never
  /// to the deviation baseline or the MAD thresholds, so detection
  /// stays deterministic and ARTI can never suppress an alert.
  /// Suspect (frozen) entries are excluded: runaway estimators do not
  /// feed the detector.
  double? muForLink(String linkKey) {
    var sum = 0.0;
    var n = 0;
    for (final e in _entries.values) {
      if (e.linkKey != linkKey || e.suspect) continue;
      sum += e.mu;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  /// Sign of phi for one entry: −1 (dip-side), +1 (rise-side), 0 (unset).
  int phiSignFor(String linkKey, String channel, String direction) {
    final e = _entries['$linkKey@$channel@$direction'];
    if (e == null) return 0;
    if (e.phi < -1e-9) return -1;
    if (e.phi > 1e-9) return 1;
    return 0;
  }

  /// Combined expected disturbance direction for a link across all its
  /// registered channels/directions: +1 = dip (baseline−level),
  /// −1 = rise (level−baseline), 0 = unknown (fall back to fade level).
  int expectedDirectionSign(String linkKey) {
    var net = 0.0;
    var n = 0;
    for (final e in _entries.values) {
      if (e.linkKey != linkKey || e.suspect) continue;
      net += e.phi;
      n++;
    }
    if (n == 0) return 0;
    if (net < -1e-9) return 1;
    if (net > 1e-9) return -1;
    return 0;
  }

  /// Deploy-time anchor: set mu_calib from a finished guided routine
  /// (or any trusted vacant-window mean). Clears suspect/frozen flags —
  /// a fresh calibration is the sanctioned un-freeze.
  void anchorCalibration(Map<String, double> muCalibByEntryKey) {
    for (final e in muCalibByEntryKey.entries) {
      final entry = _entries[e.key];
      if (entry == null) continue;
      entry.muCalib = e.value;
      entry.mu = e.value;
      entry.suspect = false;
    }
    stats.suspectLinks.clear();
    stats.maxMuDriftDb = 0.0;
  }

  /// Export the buffered telemetry for the between-sortie batch refit.
  ///
  /// Offline procedure (documented, not implemented here — do not
  /// overbuild): load this JSON, reconstruct per-entry (mu, phi)
  /// trajectories against the sortie's smoothed own tracks (no labels
  /// needed, per the paper), and run Nelder–Mead on the reference
  /// parameters minimizing the track-prediction residual. The refit
  /// mu becomes the next sortie's mu_calib prior via
  /// [anchorCalibration]. Runs offline, never live.
  Map<String, dynamic> exportRefitTelemetry() => {
        'v': 1,
        'kind': 'refit_telemetry',
        'exported_at':
            DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0,
        'procedure': 'Offline Nelder-Mead refit of (mu, phi) over the '
            'sortie\'s smoothed own tracks, no labels needed. Minimize '
            'sum of squared track-prediction residuals. Apply the refit '
            'mu as next-sortie mu_calib anchors via anchorCalibration(). '
            'Never run live.',
        'points': List.of(_telemetry),
      };

  void clearTelemetry() => _telemetry.clear();

  // ---- Guided "Dial it in" routine (operator-driven, deploy-time) ----

  final List<({String linkKey, String channel, double rssi})> _calibSamples =
      [];
  DateTime? _calibT0;
  int calibRounds = 0;
  bool _calibDegraded = false;

  /// Start the vacant-window collection. The app requires 30–60 s of
  /// quiet where possible; degraded mode runs on whatever quiet it gets
  /// and says so.
  void beginGuidedCalibration({bool degraded = false}) {
    _calibSamples.clear();
    _calibT0 = DateTime.now();
    calibRounds = 0;
    _calibDegraded = degraded;
  }

  bool get calibrating => _calibT0 != null;

  void observeCalibration({
    required String linkKey,
    required String channel,
    required double rssi,
  }) {
    if (_calibT0 == null || !rssi.isFinite) return;
    _calibSamples.add((linkKey: linkKey, channel: channel, rssi: rssi));
  }

  /// One nudge/re-measure round completed (operator moved the named
  /// node, ~10 s re-measure). The app stops prompting when no link
  /// improves > 1 dB across two consecutive rounds, or on Done.
  void nudgeRound() => calibRounds++;

  /// Abort the routine without anchoring anything.
  void cancelGuidedCalibration() {
    _calibT0 = null;
    _calibSamples.clear();
    calibRounds = 0;
  }

  /// Finish the routine: fit the path-loss model, rank links by fade
  /// level, set mu_calib anchors. Returns null when nothing was
  /// collected.
  CalibrationRecord? finishGuidedCalibration({
    required Map<String, NodePosition> nodes,
    required double vacantSecs,
  }) {
    final t0 = _calibT0;
    _calibT0 = null;
    if (t0 == null || _calibSamples.isEmpty) return null;
    final t1 = DateTime.now();

    // Per link-channel static mean.
    final byKey = <String, List<double>>{};
    final meta = <String, ({String linkKey, String channel})>{};
    for (final s in _calibSamples) {
      final k = '${s.linkKey}@${s.channel}';
      (byKey[k] ??= []).add(s.rssi);
      meta[k] = (linkKey: s.linkKey, channel: s.channel);
    }
    final meanByKey = <String, double>{};
    for (final e in byKey.entries) {
      final xs = e.value..sort();
      final n = xs.length;
      meanByKey[e.key] =
          n.isOdd ? xs[n ~/ 2] : (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
    }

    // Path-loss fit over link distances (least squares on log10(d)):
    // rssi = r0 − 10·n·log10(d). Links without geometry fall back to
    // the network-median proxy (the tripwire's honest no-model
    // reference).
    final fitXs = <double>[];
    final fitYs = <double>[];
    final distByKey = <String, double>{};
    for (final e in meanByKey.entries) {
      final m = meta[e.key]!;
      final d = _linkDistance(m.linkKey, nodes);
      if (d != null && d > 0.5) {
        distByKey[e.key] = d;
        fitXs.add(math.log(d) / math.ln10);
        fitYs.add(e.value);
      }
    }
    double? nFit, r0Fit, rmseFit;
    if (fitXs.length >= 3) {
      final fit = _linFit(fitXs, fitYs);
      // slope = −10·n  ⇒  n = −slope/10; intercept = r0 (at d = 1 m).
      nFit = -fit.slope / 10.0;
      r0Fit = fit.intercept;
      var se = 0.0;
      for (var i = 0; i < fitXs.length; i++) {
        final r = fitYs[i] - (fit.slope * fitXs[i] + fit.intercept);
        se += r * r;
      }
      rmseFit = math.sqrt(se / fitXs.length);
    }
    final netMedian = _median(meanByKey.values.toList());

    final links = <CalibrationLink>[];
    final anchors = <String, double>{};
    for (final e in meanByKey.entries) {
      final m = meta[e.key]!;
      final d = distByKey[e.key];
      final predicted = (d != null && nFit != null && r0Fit != null)
          ? r0Fit - 10 * nFit * (math.log(d) / math.ln10)
          : netMedian;
      final fade = e.value - predicted;
      links.add(CalibrationLink(
        link: m.linkKey,
        band: m.channel,
        fadeDb: fade,
        muCalibDbm: e.value,
      ));
      // Register the entry so the ARTI updater has it (per direction),
      // and key the anchor to the entry's REAL key
      // ('linkKey@channel@direction'). Keying it 'linkKey@channel'
      // never matched an entry, so anchorCalibration silently no-opped
      // on pre-existing (drifted) entries and the routine anchored
      // nothing.
      for (final dir in const ['dip', 'rise']) {
        final entry = register(
          linkKey: m.linkKey,
          channel: m.channel,
          direction: dir,
          mu0: e.value,
        );
        anchors[entry.key] = e.value;
      }
    }
    anchorCalibration(anchors);

    return CalibrationRecord(
      t0: t0,
      t1: t1,
      vacantSecs: vacantSecs,
      rounds: calibRounds,
      degraded: _calibDegraded,
      links: links,
      pathlossN: nFit,
      pathlossR0Db: r0Fit,
      pathlossRmseDb: rmseFit,
    );
  }

  // ---- internals ----

  void _mobilityCheck(Map<String, NodePosition> nodes) {
    var moved = false;
    final cur = <String, (double x, double y, double z)>{};
    for (final e in nodes.entries) {
      final n = e.value;
      cur[e.key] = (n.x, n.y, n.height);
      final prev = _lastNodePos[e.key];
      if (prev != null) {
        final dx = n.x - prev.$1, dy = n.y - prev.$2, dz = n.height - prev.$3;
        if (math.sqrt(dx * dx + dy * dy + dz * dz) >
            config.mobilityRecomputeM) {
          moved = true;
        }
      }
    }
    _lastNodePos = cur;
    if (moved) stats.geomRecompute++;
  }

  static double _maxTrackSpeed(List<TrackEstimate> tracks) {
    var m = 0.0;
    for (final t in tracks) {
      final s = t.speedMps ?? 0.0;
      if (s > m) m = s;
    }
    return m;
  }

  /// Multi-target, conservative: near ANY track ⇒ near.
  bool _isNearAnyTrack(ArtiEntry entry, ArtiSample s,
      List<TrackEstimate> tracks, Map<String, NodePosition> nodes, double lambda) {
    final ab = _linkEndpoints(s.linkKey, nodes);
    if (ab == null) return false; // no geometry: cannot be near
    for (final t in tracks) {
      final tz = t.altitudeM ?? 0.0;
      final delta = _excessPath(ab.$1, ab.$2, t.x, t.y, tz);
      if (delta <= config.excessPathLambdaMult * lambda) return true;
    }
    return false;
  }

  static double _observedDisturbance(
      String direction, double level, double mu) {
    final d = direction == 'dip' ? mu - level : level - mu;
    return math.max(0.0, d);
  }

  /// Track-predicted disturbance: the learned magnitude |phi| scaled by
  /// spatial overlap (1 on the link, decaying with excess-path-scale
  /// distance). Far from every track the prediction is ~0, so any real
  /// disturbance on a far link fails the residual gate — exactly the
  /// "don't teach the reference with unmodeled events" behavior.
  double _predictedDisturbance(ArtiEntry entry, ArtiSample s,
      List<TrackEstimate> tracks, Map<String, NodePosition> nodes, double lambda) {
    final ab = _linkEndpoints(s.linkKey, nodes);
    if (ab == null || entry.phi.abs() < 1e-9) return 0.0;
    var best = 0.0;
    for (final t in tracks) {
      final tz = t.altitudeM ?? 0.0;
      final d = _distPtSeg3D(t.x, t.y, tz, ab.$1, ab.$2);
      final overlap = math.exp(-math.pow(d / math.max(lambda, 1e-6), 2));
      if (overlap > best) best = overlap;
    }
    return entry.phi.abs() * best;
  }

  (NodePosition, NodePosition)? _linkEndpoints(
      String linkKey, Map<String, NodePosition> nodes) {
    final parts = linkKey.split(' → ');
    if (parts.length != 2) return null;
    final a = nodes[parts[0]];
    final b = nodes[parts[1]];
    if (a == null || b == null) return null;
    return (a, b);
  }

  double? _linkDistance(String linkKey, Map<String, NodePosition> nodes) {
    final ab = _linkEndpoints(linkKey, nodes);
    if (ab == null) return null;
    final dx = ab.$1.x - ab.$2.x;
    final dy = ab.$1.y - ab.$2.y;
    final dz = ab.$1.height - ab.$2.height;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static double _excessPath(
      NodePosition a, NodePosition b, double tx, double ty, double tz) {
    final dab = _dist3(a.x, a.y, a.height, b.x, b.y, b.height);
    final dat = _dist3(a.x, a.y, a.height, tx, ty, tz);
    final dbt = _dist3(b.x, b.y, b.height, tx, ty, tz);
    return math.max(0.0, dat + dbt - dab);
  }

  static double _dist3(
      double ax, double ay, double az, double bx, double by, double bz) {
    final dx = ax - bx, dy = ay - by, dz = az - bz;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static double _distPtSeg3D(double px, double py, double pz,
      NodePosition a, NodePosition b) {
    final abx = b.x - a.x, aby = b.y - a.y, abz = b.height - a.height;
    final apx = px - a.x, apy = py - a.y, apz = pz - a.height;
    final len2 = abx * abx + aby * aby + abz * abz;
    var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby + apz * abz) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t - px;
    final cy = a.y + aby * t - py;
    final cz = a.height + abz * t - pz;
    return math.sqrt(cx * cx + cy * cy + cz * cz);
  }

  static ({double slope, double intercept}) _linFit(
      List<double> xs, List<double> ys) {
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sxx += (xs[i] - mx) * (xs[i] - mx);
      sxy += (xs[i] - mx) * (ys[i] - my);
    }
    final slope = sxx < 1e-12 ? 0.0 : sxy / sxx;
    return (slope: slope, intercept: my - slope * mx);
  }

  static double _median(List<double> xs) {
    if (xs.isEmpty) return 0.0;
    xs.sort();
    final n = xs.length;
    return n.isOdd ? xs[n ~/ 2] : (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
  }

  void _noteTelemetry(DateTime now, ArtiEntry entry, ArtiSample s,
      List<TrackEstimate> tracks,
      {required bool near}) {
    if (!recordTelemetry) return;
    if (_telemetry.length >= config.telemetryBufferSize) {
      _telemetry.removeAt(0);
    }
    final t = tracks.isEmpty
        ? null
        : tracks.reduce((a, b) =>
            (a.speedMps ?? 0) >= (b.speedMps ?? 0) ? a : b);
    _telemetry.add({
      't': now.toUtc().millisecondsSinceEpoch / 1000.0,
      'link': entry.linkKey,
      'channel': entry.channel,
      'direction': entry.direction,
      'level': s.level,
      'mu': entry.mu,
      'phi': entry.phi,
      'near': near,
      'track_x': t?.x,
      'track_y': t?.y,
      'track_speed': t?.speedMps,
    });
  }
}
