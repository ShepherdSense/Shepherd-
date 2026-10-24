import 'dart:math' as math;

import '../models/link_sample.dart';
import '../models/tracking.dart';
import 'tracker_gating.dart';

/// Fuses disturbed mesh links into a single-target track estimate.
///
/// Method (deliberately simple and explainable):
/// - Position: 3D tomographic grid search — the point whose distances to
///   the disturbed links best explain the observed dip depths.
/// - Altitude: the grid search's z — but ONLY reported when the disturbed
///   nodes have real vertical spread (>= 1 m). All nodes on the ground
///   means altitude is unobservable, so it is null, never invented.
/// - Speed/heading: from the sequence of position fixes over time.
/// - Type: low-confidence heuristic from size + speed. Always labeled so.
///
/// No node-count limit anywhere: every link direction present in the
/// telemetry participates. Single target: if two objects cross at once,
/// the estimate is their blend (documented, not hidden).
class Tracker {
  /// Minimum seconds between position fixes used for velocity.
  final double fixMinIntervalSecs;

  /// Seconds without any disturbed link before velocity state resets.
  final double idleResetSecs;

  /// Dip falloff distance (m) of the forward model. Matches the
  /// simulator; real links vary, but the pattern-match degrades
  /// gracefully rather than collapsing.
  final double sigma;

  Tracker(
      {this.fixMinIntervalSecs = 1.5,
      this.idleResetSecs = 10.0,
      this.sigma = 11.0,
      this.clutterFingerprint,
      this.consistencyGate,
      this.consistencyGateStrict = false}) {
    imagingBands['default'] = ImagingBandParams.defaults();
    imagingBands['mesh'] = ImagingBandParams.defaults();
  }

  /// Optional BSense clutter fingerprint (tracker_gating.dart). When
  /// attached, quiet link samples teach it per-cell clutter and
  /// clutter-like disturbed links are demoted (replacing the global
  /// threshold for those links). Null = off; default behavior is
  /// byte-identical to before this change.
  final ClutterFingerprint? clutterFingerprint;

  /// Optional BSense decayed-consistency gate (tracker_gating.dart).
  /// When attached, every estimate feeds it and [lastConsistencyGate]
  /// carries its verdict. It suspends nothing by default — mirroring
  /// TrackConsistencyMonitor, which suspends corroboration upgrades,
  /// not detection — unless [consistencyGateStrict] is true, in which
  /// case a failing verdict suppresses the estimate. The fingerprint
  /// is deliberately NOT reset by [reset]: clutter learning is
  /// long-lived (BSense ~2-day refresh), not per-track state.
  final DecayedConsistencyGate? consistencyGate;

  /// Strict mode for [consistencyGate]: failing verdict → no estimate.
  /// Default false: the gate reports, it does not veto, so existing
  /// behavior is unchanged unless the caller opts in.
  /// Strict mode delays first reporting by one consistent fix:
  /// confidence starts at 0.5 and passes only when strictly above
  /// it, so the first fix is always suppressed in strict mode and
  /// the second (consistent) fix is the first one reported.
  final bool consistencyGateStrict;

  /// Verdict of [consistencyGate] for the latest estimate, or null
  /// when no gate is attached / no estimate has been produced yet.
  ConsistencyGateVerdict? lastConsistencyGate;

  /// MilaGro-style sharp-channel gate over RTI image cells: keep only
  /// cells within the gate radius of a live sharp support point.
  /// Empty live sharp set → all cells returned unchanged (fail open:
  /// sharp silence is not a veto). See MilagroGate in tracker_gating.
  List<RtiCell> gateRtiCells(
    List<RtiCell> cells,
    List<SharpSupport> sharp, {
    MilagroGate? gate,
    DateTime? now,
  }) {
    final g = gate ?? MilagroGate();
    final points = [for (final c in cells) GatePoint(x: c.x, y: c.y)];
    final kept = g.prune(points, sharp, now: now).toSet();
    return [
      for (var i = 0; i < cells.length; i++)
        if (kept.contains(points[i])) cells[i],
    ];
  }

  final List<_Fix> _fixes = [];
  double? _vx;
  double? _vy;
  DateTime? _lastDetect;

  /// Per-band imaging parameter tables for the RTI layer
  /// ([TrackerImaging]); 'default'/'mesh' seeded in the constructor.
  final Map<String, ImagingBandParams> _imagingBands = {};

  /// Band label for an undirected pair key, for the imaging tables:
  /// SDR virtual links carry `sdr:band-<label>`; mesh links are 'mesh'.
  static String _bandOfLink(String pairKey) {
    final m =
        RegExp(r'sdr:band-([a-z0-9]+)', caseSensitive: false)
            .firstMatch(pairKey);
    if (m != null) return m.group(1)!;
    return 'mesh';
  }

  /// Fuse one poll of enriched samples into a track, or null when
  /// nothing is currently disturbed.
  TrackEstimate? update({
    required DateTime now,
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    required DefendedPoint defended,
    // Size-aware thresholds (Kim et al. caveat, tracker_gating.dart):
    // when both are supplied, the fallback threshold for samples that
    // carry no per-link threshold of their own becomes the
    // size-scaled threshold instead of the global [dipThreshold].
    // [expectedSizeClass] must be an EXPECTED size (operator setting
    // / prior), never the size class of the dip being thresholded —
    // that would be circular. Omitted = global threshold, unchanged.
    SizeAwareThresholds? sizeThresholds,
    String? expectedSizeClass,
  }) {
    // Link *pairs* (directions deduped, strongest dip kept) — ALL pairs,
    // not just disturbed ones: quiet links carry "the target is NOT near
    // me" information that sharpens the fix.
    final effectiveFallback = sizeThresholds == null
        ? dipThreshold
        : sizeThresholds.thresholdFor(expectedSizeClass, dipThreshold);
    final pairs = _dedupePairs(samples, nodes, effectiveFallback);
    // BSense clutter gate (tracker_gating.dart): when a fingerprint is
    // attached, quiet pairs teach it and clutter-like disturbed pairs
    // are demoted — per-cell Mahalanobis gating REPLACES the global
    // threshold for those links. Untrusted cells fail open (kept).
    final disturbed = _applyClutterGate(pairs, now);
    if (disturbed.isEmpty) {
      consistencyGate?.noteMissedPoll();
      if (_lastDetect != null &&
          now.difference(_lastDetect!).inMilliseconds / 1000 >
              idleResetSecs) {
        reset();
      }
      return null;
    }

    // Geometry gate: one link (two nodes) only says "somewhere along this
    // line", and the grid search would pick an arbitrary point on it.
    // Without 3+ positioned nodes there is nothing honest to localize --
    // the disturbance is still reported by the tripwire / banner.
    // Like the empty-disturbed path above, this counts as a missed
    // poll for the consistency gate (symmetry: no fix was produced),
    // and it does NOT refresh _lastDetect — a geometry-starved poll
    // must not keep a dead track alive past the idle reset.
    final geometryIds = <String>{};
    for (final p in pairs.values) {
      geometryIds
        ..add(p.a.nodeId)
        ..add(p.b.nodeId);
    }
    if (geometryIds.length < 3) {
      consistencyGate?.noteMissedPoll();
      return null;
    }

    // Snapshot pre-estimate tracker state for the strict-gate veto
    // below: a vetoed estimate must not advance the track. Without
    // this, _fixes/_vx/_vy committed above and _lastDetect refreshed
    // here would survive a veto, so the vetoed stream would drive
    // velocity and permanently refresh _lastDetect (a vetoed stream
    // could then never trigger the 10 s idle reset).
    final savedFixes = List<_Fix>.of(_fixes);
    final savedVx = _vx;
    final savedVy = _vy;
    final savedLastDetect = _lastDetect;
    _lastDetect = now;

    // Position: coarse 3D tomographic grid search. Each candidate point is
    // scored by how well the disturbed links' dips match a Gaussian
    // falloff of the point's distance to each link. The argmax is the
    // estimate — far sharper than a link-midpoint average.
    final linkList = pairs.values.toList();
    final maxDip = linkList.map((p) => p.dip).reduce(math.max);

    // Normalized pattern match: the candidate point whose *relative*
    // dip pattern across all links best matches the observed one.
    // Score <= 0, best = 0 (exact match).
    double scoreAt(double x, double y, double z) {
      var maxM = 0.0;
      final ms = <double>[];
      for (final p in linkList) {
        final d = _distPtSeg3D(x, y, z, p.a, p.b);
        final m = math.exp(-math.pow(d / sigma, 2));
        ms.add(m);
        if (m > maxM) maxM = m;
      }
      if (maxM < 1e-6) return -1e9;
      var err = 0.0;
      for (var i = 0; i < linkList.length; i++) {
        final o = linkList[i].dip / maxDip;
        final m = ms[i] / maxM;
        final r = o - m;
        err += r * r;
      }
      return -err;
    }

    // Pass 1: coarse grid (2.5 m by default; coarser for big meshes).
    var best = -1e9, bx = 0.0, by = 0.0, bz = 0.0;
    var minX = double.infinity,
        maxX = -double.infinity,
        minY = double.infinity,
        maxY = -double.infinity,
        maxH = 0.0;
    for (final n in nodes.values) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
      if (n.height > maxH) maxH = n.height;
    }
    minX -= 15;
    maxX += 15;
    minY -= 15;
    maxY += 15;
    final zMax = maxH + 15;

    // The solve runs on the UI isolate every poll, so cap its cost: grow
    // the coarse step until the grid is at most ~20k points. The forward
    // model's falloff (sigma ~ 11 m) makes steps up to ~8 m harmless.
    var step = 2.5;
    double gridPoints(double st) =>
        ((maxX - minX) / st + 1) *
        ((maxY - minY) / st + 1) *
        (zMax / st + 1);
    while (gridPoints(step) > 20000 && step < 8.0) {
      step *= 1.25;
    }

    for (var x = minX; x <= maxX; x += step) {
      for (var y = minY; y <= maxY; y += step) {
        for (var z = 0.0; z <= zMax; z += step) {
          final s = scoreAt(x, y, z);
          if (s > best) {
            best = s;
            bx = x;
            by = y;
            bz = z;
          }
        }
      }
    }
    // Pass 2: refine around the coarse winner. The window covers one
    // coarse step each way (>= 3 m); fine step is a fifth of it (0.6 m
    // at the default grid).
    final win = math.max(3.0, step);
    final fine = win / 5.0;
    for (var x = bx - win; x <= bx + win + 1e-9; x += fine) {
      for (var y = by - win; y <= by + win + 1e-9; y += fine) {
        for (var z = math.max(0.0, bz - win);
            z <= bz + win + 1e-9;
            z += fine) {
          final s = scoreAt(x, y, z);
          if (s > best) {
            best = s;
            bx = x;
            by = y;
            bz = z;
          }
        }
      }
    }
    final x = bx, y = by, z = bz;

    // Altitude: only with real vertical spread among disturbed nodes.
    final heights = <double>{};
    for (final p in disturbed) {
      heights.add(p.a.height);
      heights.add(p.b.height);
    }
    final hList = heights.toList();
    final spread = hList.reduce(math.max) - hList.reduce(math.min);
    double? altitude;
    var altConf = 0.0;
    if (spread >= 1.0) {
      altitude = math.max(0.0, z);
      altConf = (spread / 12.0).clamp(0.2, 0.9);
    }

    // Velocity from fix history.
    if (_fixes.isEmpty ||
        now.difference(_fixes.last.t).inMilliseconds / 1000 >=
            fixMinIntervalSecs) {
      if (_fixes.isNotEmpty) {
        final last = _fixes.last;
        final dt = now.difference(last.t).inMilliseconds / 1000;
        if (dt >= 1.0 && dt <= 120.0) {
          final nvx = (x - last.x) / dt;
          final nvy = (y - last.y) / dt;
          _vx = _vx == null ? nvx : 0.5 * _vx! + 0.5 * nvx;
          _vy = _vy == null ? nvy : 0.5 * _vy! + 0.5 * nvy;
        }
      }
      _fixes.add(_Fix(t: now, x: x, y: y));
      if (_fixes.length > 40) _fixes.removeAt(0);
      // With 3+ recent fixes, fit a line through them: far less jumpy
      // than differencing two noisy grid positions.
      final fit = _fitVelocity(now);
      if (fit != null) {
        _vx = fit.vx;
        _vy = fit.vy;
      }
    }
    double? speed;
    double? heading;
    if (_vx != null && _vy != null) {
      speed = math.sqrt(_vx! * _vx! + _vy! * _vy!);
      if (speed >= 0.4) {
        // Clockwise from north, x east / y north.
        heading = (math.atan2(_vx!, _vy!) * 180 / math.pi + 360) % 360;
      }
    }

    final peakDip =
        disturbed.map((p) => p.dip).reduce(math.max);
    final size = peakDip < 10 ? 'S' : peakDip < 20 ? 'M' : 'L';
    final type = _guessType(size, speed);

    var relation = 'UNKNOWN';
    if (_vx != null && _vy != null && speed != null) {
      if (speed >= 0.5) {
        final dx = x - defended.x;
        final dy = y - defended.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist > 1.0) {
          final closing = -(_vx! * dx + _vy! * dy) / dist;
          relation = closing > 0.5
              ? 'INBOUND'
              : closing < -0.5
                  ? 'OUTBOUND'
                  : 'TRANSITING';
        } else {
          relation = 'OVERHEAD';
        }
      } else {
        relation = 'HOLDING';
      }
    }

    final estimate = TrackEstimate(
      timestamp: now,
      x: x,
      y: y,
      altitudeM: altitude,
      altitudeConfidence: altConf,
      speedMps: speed,
      headingDeg: heading,
      sizeClass: size,
      typeGuess: type.label,
      typeConfidence: type.confidence,
      linksUsed: disturbed.length,
      relation: relation,
    );
    // BSense decayed-consistency gate: report by default, veto only
    // in strict mode (see field docs). The non-strict default mirrors
    // TrackConsistencyMonitor — the gate informs the merger, it does
    // not silently delete detections the tripwire already confirmed.
    final gate = consistencyGate;
    if (gate != null) {
      lastConsistencyGate = gate.observe(now, x, y, speed);
      if (consistencyGateStrict && !lastConsistencyGate!.passes) {
        // Veto: restore pre-estimate tracker state (fixes, velocity,
        // last detection) so the vetoed estimate leaves no trace on
        // the track. The gate verdict itself is kept in
        // lastConsistencyGate — the gate did observe this fix; only
        // the tracker's committed state rolls back.
        _fixes
          ..clear()
          ..addAll(savedFixes);
        _vx = savedVx;
        _vy = savedVy;
        _lastDetect = savedLastDetect;
        return null;
      }
    }
    return estimate;
  }

  /// Partition deduped pairs through the clutter fingerprint.
  /// Returns the disturbed pairs that survive gating. Side effects
  /// (only when a fingerprint is attached): exactly one poll is
  /// counted toward the refresh frame bound (see notePoll), and
  /// ONLY genuinely quiet pairs (isDisturbed == false) feed the
  /// fingerprint at their midpoint cell with their dip. Disturbed
  /// pairs are NEVER fed — neither survivors nor clutter-demoted
  /// ones: feeding a demoted dip back in would shift the cell mean
  /// toward the very disturbance just gated out, so a real
  /// slow/loitering target demoted once could never re-emerge.
  /// Null fingerprint = the input disturbed list, untouched.
  List<_PairDip> _applyClutterGate(
      Map<String, _PairDip> pairs, DateTime now) {
    final disturbed = pairs.values.where((p) => p.isDisturbed).toList();
    final fp = clutterFingerprint;
    if (fp == null) return disturbed;
    fp.notePoll(now: now);
    final kept = <_PairDip>[];
    for (final p in disturbed) {
      final mx = (p.a.x + p.b.x) / 2;
      final my = (p.a.y + p.b.y) / 2;
      if (fp.gate(mx, my, p.dip).targetLike) {
        kept.add(p);
      }
    }
    for (final p in pairs.values) {
      if (p.isDisturbed) continue;
      final mx = (p.a.x + p.b.x) / 2;
      final my = (p.a.y + p.b.y) / 2;
      fp.observe(mx, my, p.dip, now: now);
    }
    return kept;
  }

  /// Least-squares velocity over fixes from the last [window] seconds.
  /// Null with fewer than 3 fixes or no time spread.
  ({double vx, double vy})? _fitVelocity(DateTime now,
      {double window = 12.0}) {
    final pts = [
      for (final f in _fixes)
        if (now.difference(f.t).inMilliseconds / 1000.0 <= window) f,
    ];
    if (pts.length < 3) return null;
    final t0 = pts.first.t;
    final ts = [
      for (final f in pts) f.t.difference(t0).inMilliseconds / 1000.0
    ];
    final n = pts.length;
    final mt = ts.reduce((a, b) => a + b) / n;
    final mx = pts.map((f) => f.x).reduce((a, b) => a + b) / n;
    final my = pts.map((f) => f.y).reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxt = 0.0, syt = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = ts[i] - mt;
      sxx += dt * dt;
      sxt += dt * (pts[i].x - mx);
      syt += dt * (pts[i].y - my);
    }
    if (sxx < 1e-6) return null;
    return (vx: sxt / sxx, vy: syt / sxx);
  }

  void reset() {
    _fixes.clear();
    _vx = null;
    _vy = null;
    _lastDetect = null;
    consistencyGate?.reset();
    lastConsistencyGate = null;
    // NOTE: clutterFingerprint is NOT reset here — clutter learning
    // is long-lived (BSense ~2-day refresh), not per-track state.
  }

  /// 2D shadow (attenuation) grid for the "what are the waves hitting"
  /// view. Each cell's value is the dip-weighted sum of Gaussian
  /// falloffs to every link segment: high values mark where the RF
  /// field is dimmed — the shadow the object casts in the waves.
  /// Quiet links contribute ~nothing, so empty field stays dark.
  /// Values are normalized 0..1 across the grid.
  List<ShadowCell> shadowGrid({
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    double cellM = 2.5,
  }) {
    final pairs = _dedupePairs(samples, nodes, dipThreshold);
    final out = <ShadowCell>[];
    if (pairs.isEmpty) return out;

    var minX = double.infinity,
        maxX = -double.infinity,
        minY = double.infinity,
        maxY = -double.infinity;
    for (final n in nodes.values) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
    }
    minX -= 12;
    maxX += 12;
    minY -= 12;
    maxY += 12;

    // Cap the cell count (~6k) so a large field doesn't mean thousands of
    // cells x every link, every poll.
    var cell = cellM;
    while (((maxX - minX) / cell + 1) * ((maxY - minY) / cell + 1) > 6000 &&
        cell < 20.0) {
      cell *= 1.25;
    }

    final linkList = pairs.values.toList();
    var peak = 0.0;
    final raws = <double>[];
    final xs = <double>[];
    final ys = <double>[];
    for (var x = minX; x <= maxX; x += cell) {
      for (var y = minY; y <= maxY; y += cell) {
        var v = 0.0;
        for (final p in linkList) {
          if (p.dip < p.threshold * 0.5) continue;
          final d = _distPtSeg2D(x, y, p.a, p.b);
          v += p.dip * math.exp(-math.pow(d / sigma, 2));
        }
        xs.add(x);
        ys.add(y);
        raws.add(v);
        if (v > peak) peak = v;
      }
    }
    if (peak < 1e-9) return out;
    for (var i = 0; i < raws.length; i++) {
      final v = (raws[i] / peak).clamp(0.0, 1.0);
      if (v > 0.03) out.add(ShadowCell(x: xs[i], y: ys[i], v: v));
    }
    return out;
  }

  /// Collapse link directions into undirected pairs. Of the two
  /// directions, keep the one that is furthest past ITS OWN threshold
  /// (each direction can have a different noise level, so raw dip depth
  /// is not comparable). [fallback] is used for samples that carry no
  /// threshold of their own.
  static Map<String, _PairDip> _dedupePairs(
    List<LinkSample> samples,
    Map<String, NodePosition> nodes,
    double fallback,
  ) {
    final pairs = <String, _PairDip>{};
    for (final s in samples) {
      final a = nodes[s.fromNode];
      final b = nodes[s.toNode];
      if (a == null || b == null) continue;
      final key = _pairKey(s.fromNode, s.toNode);
      final cand = _PairDip(
        a: a,
        b: b,
        dip: s.dip,
        threshold: s.effectiveThreshold(fallback),
      );
      final prev = pairs[key];
      if (prev == null || cand.margin > prev.margin) pairs[key] = cand;
    }
    return pairs;
  }

  static String _pairKey(String a, String b) {
    final ids = [a, b]..sort();
    return '${ids[0]}|${ids[1]}';
  }

  /// 2D (top-down) distance from point P to the segment A→B.
  /// Used by the shadow grid — the shadow is a ground-plane image.
  static double _distPtSeg2D(
      double px, double py, NodePosition a, NodePosition b) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final apx = px - a.x;
    final apy = py - a.y;
    final len2 = abx * abx + aby * aby;
    var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t - px;
    final cy = a.y + aby * t - py;
    return math.sqrt(cx * cx + cy * cy);
  }

  /// 3D distance from point P to the segment A→B.
  static double _distPtSeg3D(
      double px, double py, double pz, NodePosition a, NodePosition b) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.height - a.height;
    final apx = px - a.x;
    final apy = py - a.y;
    final apz = pz - a.height;
    final len2 = abx * abx + aby * aby + abz * abz;
    var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby + apz * abz) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t - px;
    final cy = a.y + aby * t - py;
    final cz = a.height + abz * t - pz;
    return math.sqrt(cx * cx + cy * cy + cz * cz);
  }

  /// Heuristic type guess. Confidence is ALWAYS low — this is a hint,
  /// not identification.
  static ({String label, double confidence}) _guessType(
      String size, double? speedMps) {
    final s = speedMps ?? 0;
    if (size == 'S' && s >= 3) {
      return (
        label: 'Fast small object — possible small drone',
        confidence: 0.35
      );
    }
    if (size == 'S') {
      return (
        label: 'Small slow mover — person / animal?',
        confidence: 0.30
      );
    }
    if (size == 'M' && s >= 5) {
      return (
        label: 'Medium fast object — possible drone / large bird',
        confidence: 0.30
      );
    }
    if (size == 'M') {
      return (label: 'Medium object — unknown', confidence: 0.25);
    }
    if (s >= 12) {
      return (
        label: 'Large fast object — possible vehicle / aircraft',
        confidence: 0.35
      );
    }
    return (label: 'Large object — unknown', confidence: 0.25);
  }
}

class _PairDip {
  _PairDip({
    required this.a,
    required this.b,
    required this.dip,
    required this.threshold,
  });

  final NodePosition a;
  final NodePosition b;
  final double dip;

  /// Dip depth at which this pair's link counts as disturbed.
  final double threshold;

  /// How far past (or short of) its own threshold the dip is.
  double get margin => dip - threshold;

  bool get isDisturbed => dip >= threshold;
}

/// One cell of the shadow (attenuation) grid: field-local meters and a
/// normalized 0..1 shadow intensity.
class ShadowCell {
  const ShadowCell({required this.x, required this.y, required this.v});

  final double x;
  final double y;
  final double v;
}

class _Fix {
  _Fix({required this.t, required this.x, required this.y});

  final DateTime t;
  final double x;
  final double y;
}

// ---------------------------------------------------------------------------
// RTI imaging weights — multi-scale spatial model (rti_imaging_weights_spec).
//
// Method ported from Kaltiokallio, Bocca & Patwari, arXiv:1302.5914
/// (CONFIRMED at 30–33 nodes, 2D, ground-plane, stationary humans).
/// What ports is the *method* — fade-signed, direction-split,
/// area-normalized weighting. The paper's ellipse parameters and its
/// ≤ 0.30 m accuracy figure do NOT port (6 nodes, airborne Group 2–3
/// UAS); field validation re-measures from zero.
///
/// Pipeline:
///  1. The tripwire's direction-split Δr (deltaDown/deltaUp on
///     LinkSample) feeds two measurement vectors, p⁻ and p⁺, each with
///     its own ellipse set and probability mapping:
///       p^δ = 1 − exp(−β^δ · |Δr^δ|),  δ ∈ {−, +}
///     stacked to 2·L·C rows (L links, C bands, 2 directions).
///  2. Ellipse excess-path parameter per direction from the link's fade
///     level: λ^δ = b^δ · e^(F / k^δ). Anti-fade links get tight
///     ellipses on δ=−, deep-fade links tight ellipses on δ=+.
///  3. Weights are inverse ellipse AREA (not 1/√d): a deep-fade link's
///     diffuse ellipse would otherwise contribute near-uniform "maybe
///     everywhere" mass that washes out tight anti-fade ellipses —
///     the highest-leverage change at 6-node sparsity.
///  4. The two direction images are fused (summed) AFTER weighting —
///     never before. Summing |Δr| first lets a rise and a dip on the
///     same pixel cancel or double-count.
///
/// Parameters are per-band starting estimates in the paper's functional
/// forms — NOT the paper's Table I numbers (CC2530-in-rooms fits).
/// Refit them from our own calibration data via
/// [refitImagingBand]; shipping with the paper's numbers would be
/// cargo-culting.
///
/// Fresnel-zone weighting is deliberately ABSENT (open research
/// question per the spec — unvalidated; do not add it).
/// ---------------------------------------------------------------------------

/// Weight scheme for the imaging layer. [area] is the shipped model;
/// [invSqrtDist] exists only as the test control proving area
/// normalization matters (spec test 2).
enum WeightScheme { area, invSqrtDist }

/// Per-band imaging parameters: the paper's functional forms with OUR
/// fitted constants (starting estimates until refit).
///
///   λ^δ(F) = b^δ · e^(F / k^δ)     (ellipse excess-path, meters)
///   β⁻     = betaMinus             (fixed, like the paper)
///   β⁺(F)  = beta0Plus · e^(F / kBeta)
///
/// F is the link fade level in the tripwire's radio units. Starting
/// estimates are round, physically-motivated placeholders (ellipse
/// excess of order meters, mild fade dependence) — refit from
/// calibration crossings before trusting them. They are NOT the
/// paper's Table I values.
class ImagingBandParams {
  const ImagingBandParams({
    required this.bMinus,
    required this.kMinus,
    required this.bPlus,
    required this.kPlus,
    required this.betaMinus,
    required this.beta0Plus,
    required this.kBeta,
  });

  /// Starting estimates — placeholders, not paper values, not truth.
  ///
  /// The paper's b^δ (≈0.21/0.50 m) was fit for 2–5 m indoor links.
  /// Shepherd's field links are 30–60 m; at that length a 0.2 m
  /// excess-path ellipse is a razor that covers almost no pixel, and
  /// the image fragments into link-crossing artifacts instead of
  /// localizing the disturbance. The starting b is therefore scaled
  /// so the ellipse's semi-minor axis covers a few meters
  /// (~link-length/10) — the plausible disturbance region at our
  /// sparsity. Refit from calibration crossings before trusting it;
  /// the refit hook exists precisely because these are guesses.
  factory ImagingBandParams.defaults() => const ImagingBandParams(
        bMinus: 2.0,
        kMinus: -8.0,
        bPlus: 2.0,
        kPlus: 80.0,
        betaMinus: 0.12,
        beta0Plus: 0.18,
        kBeta: 13.0,
      );

  final double bMinus;
  final double kMinus;
  final double bPlus;
  final double kPlus;
  final double betaMinus;
  final double beta0Plus;
  final double kBeta;

  /// Excess-path ellipse parameter for the dip direction (δ=−).
  double lambdaMinus(double fadeDb) =>
      (bMinus * math.exp(fadeDb / kMinus)).clamp(0.02, 60.0);

  /// Excess-path ellipse parameter for the rise direction (δ=+).
  double lambdaPlus(double fadeDb) =>
      (bPlus * math.exp(fadeDb / kPlus)).clamp(0.02, 60.0);

  double betaFor(String direction, double fadeDb) => direction == 'dip'
      ? betaMinus
      : (beta0Plus * math.exp(fadeDb / kBeta)).clamp(0.01, 2.0);

  /// Refit the functional-form parameters from our own calibration
  /// crossings: log-linear regression of ln(λ) and ln(β⁺) on fade
  /// level F. [points] carry measured (fade, lambdaMinus,
  /// lambdaPlus, betaPlus) from controlled crossings. β⁻ refits as the
  /// median of measured betaMinus. Needs ≥ 3 points with fade spread;
  /// otherwise returns `this` unchanged (never fit on nothing).
  ImagingBandParams refitFrom(List<ImagingFitPoint> points) {
    if (points.length < 3) return this;
    final fs = [for (final p in points) p.fadeDb];
    final spread = fs.reduce(math.max) - fs.reduce(math.min);
    if (spread < 1e-6) return this;
    final lMinus = _logLinFit(points, (p) => p.lambdaMinus);
    final lPlus = _logLinFit(points, (p) => p.lambdaPlus);
    final bPlus = _logLinFit(points, (p) => p.betaPlus);
    final betaMinusFit = _median([for (final p in points) p.betaMinus]);
    return ImagingBandParams(
      bMinus: math.exp(lMinus.intercept),
      kMinus: lMinus.slope.abs() < 1e-9 ? kMinus : 1 / lMinus.slope,
      bPlus: math.exp(lPlus.intercept),
      kPlus: lPlus.slope.abs() < 1e-9 ? kPlus : 1 / lPlus.slope,
      betaMinus: betaMinusFit > 0 ? betaMinusFit : betaMinus,
      beta0Plus: math.exp(bPlus.intercept),
      kBeta: bPlus.slope.abs() < 1e-9 ? kBeta : 1 / bPlus.slope,
    );
  }

  static ({double slope, double intercept}) _logLinFit(
      List<ImagingFitPoint> points, double Function(ImagingFitPoint) pick) {
    final xs = <double>[], ys = <double>[];
    for (final p in points) {
      final v = pick(p);
      if (v > 0 && v.isFinite) {
        xs.add(p.fadeDb);
        ys.add(math.log(v));
      }
    }
    if (xs.length < 3) return (slope: 0.0, intercept: 0.0);
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
}

/// One measured calibration crossing for the refit hook.
class ImagingFitPoint {
  const ImagingFitPoint({
    required this.fadeDb,
    required this.lambdaMinus,
    required this.lambdaPlus,
    required this.betaMinus,
    required this.betaPlus,
  });

  final double fadeDb;
  final double lambdaMinus;
  final double lambdaPlus;
  final double betaMinus;
  final double betaPlus;
}

/// One row of the stacked measurement system: (link, band, direction).
class RtiRow {
  const RtiRow({
    required this.linkKey,
    required this.band,
    required this.direction,
    required this.lambdaM,
    required this.prob,
    required this.fadeDb,
    required this.delta,
    required this.a,
    required this.b,
    required this.area,
  });

  final String linkKey;
  final String band;

  /// 'dip' (δ=−) or 'rise' (δ=+).
  final String direction;

  /// Ellipse excess-path parameter (m).
  final double lambdaM;

  /// p^δ = 1 − exp(−β^δ · |Δr^δ|).
  final double prob;
  final double fadeDb;
  final double delta;

  /// Link endpoints (field meters, ground plane).
  final NodePosition a;
  final NodePosition b;

  /// Ellipse area (m²) — the normalization weight is 1/area.
  final double area;
}

/// One cell of the fused disturbance image (ground-plane projection).
class RtiCell {
  const RtiCell({
    required this.x,
    required this.y,
    required this.v,
    this.vMinus = 0.0,
    this.vPlus = 0.0,
  });

  final double x;
  final double y;

  /// Fused normalized 0..1 intensity (v⁻ + v⁺ after weighting).
  final double v;
  final double vMinus;
  final double vPlus;
}

/// Imaging methods on [Tracker]: the weight matrix W, the probability
/// measurement vector, and the fused image. The Kalman/data-association
/// tracker itself is unchanged; it consumes the improved image.
extension TrackerImaging on Tracker {
  /// Per-band parameter table. 'default' is the fallback; add bands
  /// ('433', '915', …) via [setImagingBand] after refit.
  Map<String, ImagingBandParams> get imagingBands => _imagingBands;

  void setImagingBand(String band, ImagingBandParams params) {
    _imagingBands[band] = params;
  }

  /// Refit one band's functional-form parameters from our own
  /// calibration crossings (no paper numbers involved).
  void refitImagingBand(String band, List<ImagingFitPoint> points) {
    final cur = _imagingBands[band] ?? ImagingBandParams.defaults();
    _imagingBands[band] = cur.refitFrom(points);
  }

  /// Build the stacked measurement rows: 2 directions × L links
  /// (× C bands — one band per sample batch here; multi-band meshes
  /// stack rows across drivers' samples).
  List<RtiRow> imagingRows({
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    String Function(String linkKey)? bandOf,
  }) {
    final pairs = _dedupePairDirs(samples, nodes, dipThreshold);
    final rows = <RtiRow>[];
    for (final p in pairs.values) {
      final band =
          bandOf?.call(p.key) ?? Tracker._bandOfLink(p.key);
      final params = _imagingBands[band] ??
          _imagingBands['mesh'] ??
          _imagingBands['default']!;
      final d = _linkLen(p.a, p.b);
      for (final dir in const ['dip', 'rise']) {
        final delta = dir == 'dip' ? p.deltaDown : p.deltaUp;
        final lambda = dir == 'dip'
            ? params.lambdaMinus(p.fadeLevel)
            : params.lambdaPlus(p.fadeLevel);
        final beta = params.betaFor(dir, p.fadeLevel);
        final prob = 1 - math.exp(-beta * delta);
        final area = _ellipseArea(d, lambda);
        rows.add(RtiRow(
          linkKey: p.key,
          band: band,
          direction: dir,
          lambdaM: lambda,
          prob: prob,
          fadeDb: p.fadeLevel,
          delta: delta,
          a: p.a,
          b: p.b,
          area: area,
        ));
      }
    }
    return rows;
  }

  /// Fused disturbance image: two direction images built with
  /// area-normalized weights, fused (summed) AFTER weighting.
  ///
  /// Returns cells normalized 0..1 unless [normalize] is false (raw
  /// probability mass — for tests comparing evidence preserved across
  /// pipeline variants). This is a probability-mass image over the
  /// ground plane — "estimated disturbance location (ground
  /// projection)", never a located object.
  List<RtiCell> rtiImage({
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    double cellM = 2.5,
    WeightScheme scheme = WeightScheme.area,
    String Function(String linkKey)? bandOf,
    bool normalize = true,
  }) {
    final rows = imagingRows(
      samples: samples,
      nodes: nodes,
      dipThreshold: dipThreshold,
      bandOf: bandOf,
    );
    final live = [for (final r in rows) if (r.prob > 1e-4) r];
    if (live.isEmpty || nodes.isEmpty) return const [];

    var minX = double.infinity,
        maxX = -double.infinity,
        minY = double.infinity,
        maxY = -double.infinity;
    for (final n in nodes.values) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
    }
    minX -= 12;
    maxX += 12;
    minY -= 12;
    maxY += 12;
    var cell = cellM;
    while (((maxX - minX) / cell + 1) * ((maxY - minY) / cell + 1) > 6000 &&
        cell < 20.0) {
      cell *= 1.25;
    }

    final xs = <double>[];
    final ys = <double>[];
    for (var x = minX; x <= maxX; x += cell) {
      for (var y = minY; y <= maxY; y += cell) {
        xs.add(x);
        ys.add(y);
      }
    }
    final vMinus = List<double>.filled(xs.length, 0.0);
    final vPlus = List<double>.filled(xs.length, 0.0);
    for (final r in live) {
      final w = scheme == WeightScheme.area
          ? 1.0 / r.area
          : null; // per-pixel below
      final d = _linkLen(r.a, r.b);
      final aSemi = (d + r.lambdaM) / 2;
      final bSemi = math.sqrt(
          math.max(r.lambdaM * (2 * d + r.lambdaM), 1e-9)) /
          2;
      final ux = (r.b.x - r.a.x) / math.max(d, 1e-9);
      final uy = (r.b.y - r.a.y) / math.max(d, 1e-9);
      final target = r.direction == 'dip' ? vMinus : vPlus;
      for (var i = 0; i < xs.length; i++) {
        final px = xs[i] - r.a.x, py = ys[i] - r.a.y;
        // Link-aligned coords: u along the link, v perpendicular.
        final u = px * ux + py * uy;
        final v = -px * uy + py * ux;
        final uc = u - d / 2;
        final inside = (uc * uc) / (aSemi * aSemi) +
                (v * v) / math.max(bSemi * bSemi, 1e-9) <=
            1.0;
        if (!inside) continue;
        double weight;
        if (w != null) {
          weight = w;
        } else {
          // Control scheme: 1/sqrt(distance to link), the pre-change
          // falloff the area model replaces.
          final dist = Tracker._distPtSeg2D(xs[i], ys[i], r.a, r.b);
          weight = 1.0 / math.sqrt(math.max(dist, 0.25));
        }
        target[i] += r.prob * weight;
      }
    }
    var peak = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final s = vMinus[i] + vPlus[i];
      if (s > peak) peak = s;
    }
    if (peak < 1e-12) return const [];
    final out = <RtiCell>[];
    for (var i = 0; i < xs.length; i++) {
      final vm = normalize ? vMinus[i] / peak : vMinus[i];
      final vp = normalize ? vPlus[i] / peak : vPlus[i];
      final v = vm + vp;
      if (!normalize || v > 0.03) {
        out.add(RtiCell(x: xs[i], y: ys[i], v: v, vMinus: vm, vPlus: vp));
      }
    }
    return out;
  }

  static double _linkLen(NodePosition a, NodePosition b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Ellipse area for excess-path λ over link length d: a = (d+λ)/2,
  /// b = √(λ(2d+λ))/2, area = πab. Guarded: never below 1e-6.
  static double _ellipseArea(double d, double lambda) {
    final a = (d + lambda) / 2;
    final b = math.sqrt(math.max(lambda * (2 * d + lambda), 1e-9)) / 2;
    return math.max(math.pi * a * b, 1e-6);
  }

  /// Collapse directed samples into undirected pairs, keeping the max
  /// per-direction Δr (no cancellation: dip and rise stay separate).
  static Map<String, _PairDirs> _dedupePairDirs(
    List<LinkSample> samples,
    Map<String, NodePosition> nodes,
    double dipThreshold,
  ) {
    final pairs = <String, _PairDirs>{};
    for (final s in samples) {
      final a = nodes[s.fromNode];
      final b = nodes[s.toNode];
      if (a == null || b == null) continue;
      final key = Tracker._pairKey(s.fromNode, s.toNode);
      final prev = pairs[key];
      if (prev == null) {
        pairs[key] = _PairDirs(
          key: key,
          a: a,
          b: b,
          deltaDown: s.deltaDown,
          deltaUp: s.deltaUp,
          fadeLevel: s.fadeLevel,
          threshold: s.effectiveThreshold(dipThreshold),
        );
      } else {
        final down = math.max(prev.deltaDown, s.deltaDown);
        final up = math.max(prev.deltaUp, s.deltaUp);
        // Fade level follows the direction carrying the disturbance.
        final fade = (s.deltaDown + s.deltaUp) >=
                (prev.deltaDown + prev.deltaUp)
            ? s.fadeLevel
            : prev.fadeLevel;
        pairs[key] = _PairDirs(
          key: key,
          a: a,
          b: b,
          deltaDown: down,
          deltaUp: up,
          fadeLevel: fade,
          threshold: math.min(
              prev.threshold, s.effectiveThreshold(dipThreshold)),
        );
      }
    }
    return pairs;
  }
}

class _PairDirs {
  _PairDirs({
    required this.key,
    required this.a,
    required this.b,
    required this.deltaDown,
    required this.deltaUp,
    required this.fadeLevel,
    required this.threshold,
  });

  final String key;
  final NodePosition a;
  final NodePosition b;
  final double deltaDown;
  final double deltaUp;
  final double fadeLevel;
  final double threshold;
}
