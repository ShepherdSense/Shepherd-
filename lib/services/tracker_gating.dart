/// BSense / MilaGro / size-aware gating layers for the Shepherd tracker
/// (v0.25.0, Builder A — Dart tracker).
///
/// This file ports the *portable* parts of three papers into the existing
/// tracker architecture (gated confidence merger, tripwire). It does NOT
/// rewrite the tracker, does NOT add ML, and changes NO wire format
/// (UDP formats and the 10-feature classifier contract are untouched).
///
/// Sources (see docs/bsense_tracker_gating_spec.md for the full mapping
/// tables, including paper value → Shepherd value → why):
///  - BSense (Meng et al., arXiv:2603.29187, MobiSys '26): per-cell
///    Gaussian clutter fingerprint + Mahalanobis gating, and decayed
///    (0.9) spatial/velocity consistency confidence as a false-track
///    gate.
///  - MilaGro (Picazo-Martinez et al., arXiv:2507.22591v2): the
///    sharpest/shortest-range channel as a GATE that prunes the search
///    space for the broad-coverage channel. NO CNN, no ML here — only
///    the gate shape, the same shape as Shepherd's anti-fade-link
///    gating.
///  - Kim et al. (arXiv:2505.04085v2, lane1 §6.12.1 caveat): slim
///    targets degrade detection, so thresholds must be size-aware, not
///    one global threshold.
///
/// HONESTY — READ BEFORE QUOTING ANY NUMBER FROM THIS FILE:
///  - Shepherd has NO 5G-A base station. BSense's 1 km range and
///    F1 95.56% belong to carrier hardware and are NEVER claimed for
///    Shepherd. What ports is the layered false-alarm *recipe*, at
///    Shepherd scale, with Shepherd-scale parameters documented as
///    starting estimates to field-calibrate.
///  - The 6-node / 15-link ~1–2 m imaging bound is NOT upgraded by any
///    paper in this scope. No paper here supports that.
///  - Everything this file emits is a disturbance / blob / trail /
///    bearing / estimate — never imagery, silhouettes, confirmed
///    identity, or fire-control-quality tracks. Confidence saturates
///    below 1.0, exactly like the confidence merger.
///
/// KNOWN LIMITS (BSense's failure modes, inherited by any gate built on
/// the same assumptions — see the spec doc):
///  - Tangential-flight blindness: a target moving so it produces no
///    new link disturbance yields no fixes; a gate over fixes cannot
///    confirm what the sensor never saw. Absence of fixes is NOT
///    confirmation of absence.
///  - Occlusion gaps (BSense: 50–100 m trajectory gaps): a long gap
///    breaks continuity; the gate resets instead of bridging it.
///  - Doppler/continuity assumptions are exploitable by a knowledgeable
///    operator (BSense authors' own caveat, CONFIRMED from the paper):
///    flying to defeat spatial-continuity + velocity-consistency checks
///    defeats this gate too. It is a false-alarm reducer, not a
///    guarantee.
///  - Defensive-only: sensing/detection only. No jamming, spoofing, or
///    transmit-to-disrupt anywhere in this file or its callers.
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 1a. BSense per-spatial-cell clutter fingerprint + Mahalanobis gating.
// ---------------------------------------------------------------------------

/// Per-cell Gaussian clutter fingerprint for link-shadow false alarms.
///
/// Paper form, Shepherd scale:
///  - Paper: one multivariate Gaussian per 40 m cube of the 5G-A cell,
///    Mahalanobis distance, k = 80th percentile, ~10 min init, refresh
///    ~every 2 days / 700 frames.
///  - Shepherd: one UNIVARIATE Gaussian per field cell over the link
///    dip (radio units) observed while quiet. Multivariate point-cloud
///    features do not exist in Shepherd's input — the tracker sees link
///    dips, so the fingerprint feature is the dip. The *form* ports
///    (per-cell Gaussian, percentile Mahalanobis gate, periodic
///    refresh); the feature vector does not, and that is stated, not
///    hidden.
///
/// Cell keying: a link contributes its quiet dip to the cell containing
/// its midpoint. A disturbed link is gated against ITS midpoint cell's
/// fingerprint: close to the cell's clutter distribution = clutter-like
/// (gated out); far from it = target-like (kept).
///
/// Fail-open by design: an untrusted cell (too few quiet samples) or a
/// cell with no history NEVER gates anything out. A gate that blocks
/// detections on cells it has never seen would trade false alarms for
/// blind spots. Learning uses QUIET samples only — feeding disturbed
/// samples into the fingerprint would teach it that targets are clutter.
class ClutterFingerprint {
  ClutterFingerprint({
    this.cellSizeM = 10.0,
    this.percentileK = 0.80,
    this.minSamplesPerCell = 20,
    this.refreshFrames = 700,
    this.refreshAge = const Duration(days: 2),
    this.sigmaFloor = 0.5,
  }) {
    // Only the paper's k = 0.80 is supported (see _zForPercentile):
    // silently retuning the gate level would be a lie, so a
    // non-0.80 value is rejected loudly, not clamped.
    if ((percentileK - 0.80).abs() > 1e-9) {
      throw ArgumentError.value(
        percentileK,
        'percentileK',
        'Only 0.80 is supported (BSense k); '
        'no quantile function exists for other values.',
      );
    }
  }

  /// Paper 40 m → Shepherd 10 m. Why: BSense's field is a 1,000 m
  /// 5G-A cell; Shepherd's mesh field is of order 100 m across with
  /// 30–60 m links and a tracker falloff sigma ≈ 11 m. A 40 m cell
  /// would be most of the field (2–3 cells, no locality at all).
  /// 10 m is ~the tracker sigma, small against the field, and large
  /// enough that a link midpoint cell actually accumulates samples.
  /// Starting estimate — refit if fields get much larger.
  final double cellSizeM;

  /// Paper k = 80th percentile, ported verbatim as the gate level.
  /// Univariate analogue: the two-sided 80% interval of a standard
  /// normal is |z| ≤ 1.2816, so [mahalanobisThreshold] = 1.2816.
  /// (BSense's multivariate version uses a chi-square percentile; the
  /// univariate |z| form is the honest 1-D equivalent, not the same
  /// statistic — see the spec doc.)
  final double percentileK;

  /// Paper ~10 min init → Shepherd 20 quiet samples per cell. Why not
  /// a frame count: BSense sees ~168 points/frame; Shepherd sees ~1
  /// track poll's worth of link samples, so per-cell frame counts do
  /// not port. 20 quiet samples is attainable in one quiet session
  /// while still being a distribution, not a single reading. Cells
  /// below this stay untrusted and fail open.
  final int minSamplesPerCell;

  /// Paper refresh ~every 700 frames → Shepherd 700 Tracker.update
  /// polls. Counted by [notePoll] (one call per tracker poll), NOT by
  /// observe() calls: one poll feeds ~15 pairs, so counting observes
  /// would fire the refresh every ~50 polls instead of every 700.
  /// Combined with [refreshAge] (paper ~2 days, ported verbatim):
  /// whichever comes first halves the effective sample weight (see
  /// [refresh]), so new clutter re-anchors the fingerprint without a
  /// blind re-init window.
  final int refreshFrames;

  /// Paper ~2 days, ported verbatim.
  final Duration refreshAge;

  /// Minimum sigma (radio units). Stops a perfectly flat (quantized)
  /// link from giving sigma ≈ 0, which would make any tiny wiggle an
  /// infinite Mahalanobis distance and pass everything as target-like.
  final double sigmaFloor;

  /// |z| gate for the 80th percentile (two-sided standard normal).
  /// percentileK is kept as the documented paper parameter; the
  /// threshold itself is the 80% value because that is the only k this
  /// implementation supports. The constructor rejects any other k
  /// with ArgumentError, and [_zForPercentile] throws for one too —
  /// changing percentileK without a real quantile function would be
  /// a lie, so it is never silently clamped.
  double get mahalanobisThreshold => _zForPercentile(percentileK);

  static double _zForPercentile(double k) {
    // Only the paper's k = 0.80 is supported; the two-sided 80%
    // standard-normal quantile is 1.2816. Any other k throws rather
    // than inventing a quantile function — callers must not silently
    // retune the gate.
    if ((k - 0.80).abs() > 1e-9) {
      throw ArgumentError.value(
        k,
        'k',
        'Only 0.80 is supported (BSense k); '
        'no quantile function exists for other values.',
      );
    }
    return 1.2816;
  }

  final Map<String, _CellStats> _cells = {};
  int _pollCount = 0;
  int _lastRefreshPoll = 0;
  DateTime? _lastRefreshAt;

  /// Cell key for a field position (meters, field-local).
  /// Callers guard non-finite inputs before reaching here: NaN/Inf
  /// coordinates would make `.floor()` throw, so [observe],
  /// [mahalanobisAt], [gate], and the accessors below all return
  /// early / fail open on non-finite inputs instead of keying a cell.
  String cellKey(double x, double y) =>
      '${(x / cellSizeM).floor()},${(y / cellSizeM).floor()}';

  /// Number of quiet samples recorded for the cell at (x, y).
  /// Non-finite coordinates → 0 (no cell exists for them).
  int samplesFor(double x, double y) {
    if (!x.isFinite || !y.isFinite) return 0;
    return _cells[cellKey(x, y)]?.count ?? 0;
  }

  /// True once the cell has enough quiet samples to gate.
  bool trustedAt(double x, double y) =>
      samplesFor(x, y) >= minSamplesPerCell;

  /// Current (mean, sigma) for a cell, or null when unseen.
  /// Non-finite coordinates → null.
  ({double mean, double sigma})? statsAt(double x, double y) {
    if (!x.isFinite || !y.isFinite) return null;
    final c = _cells[cellKey(x, y)];
    if (c == null || c.count == 0) return null;
    return (mean: c.mean, sigma: c.sigma(sigmaFloor));
  }

  /// Feed one QUIET dip observation (radio units) at (x, y) — the
  /// caller must only pass samples that were NOT disturbed.
  /// Disturbed samples must never reach this method, including
  /// disturbed samples the gate demoted as clutter-like: feeding a
  /// demoted dip back in would shift the cell mean toward the very
  /// disturbance it just gated out, so a slow/loitering target could
  /// never re-emerge (see Tracker._applyClutterGate). Non-finite
  /// coordinates or values are ignored (they cannot key a cell).
  void observe(double x, double y, double value, {DateTime? now}) {
    if (!x.isFinite || !y.isFinite || !value.isFinite) return;
    final t = now ?? DateTime.now();
    _lastRefreshAt ??= t;
    // Age bound only: the frame bound is counted by notePoll (one
    // tracker poll feeds many observes, so counting observes would
    // fire the refresh ~15x too often).
    if (t.difference(_lastRefreshAt!) > refreshAge) {
      refresh(now: t);
    }
    final cell = _cells.putIfAbsent(cellKey(x, y), () => _CellStats());
    cell.add(value);
  }

  /// Count one Tracker.update poll toward the refresh frame bound.
  /// Called once per poll by Tracker._applyClutterGate (never per
  /// observe). Refresh fires when [refreshFrames] polls have passed
  /// since the last refresh, or the [refreshAge] bound is exceeded,
  /// whichever comes first.
  void notePoll({DateTime? now}) {
    _pollCount++;
    final t = now ?? DateTime.now();
    _lastRefreshAt ??= t;
    if (_pollCount - _lastRefreshPoll >= refreshFrames ||
        t.difference(_lastRefreshAt!) > refreshAge) {
      refresh(now: t);
    }
  }

  /// Mahalanobis distance (|z|) of [value] from the cell's clutter
  /// distribution. Null when the cell is untrusted — the caller must
  /// fail open (see [gate]) — and null for non-finite inputs, which
  /// likewise fail open rather than throwing inside cellKey.
  double? mahalanobisAt(double x, double y, double value) {
    if (!x.isFinite || !y.isFinite || !value.isFinite) return null;
    final c = _cells[cellKey(x, y)];
    if (c == null || c.count < minSamplesPerCell) return null;
    return (value - c.mean).abs() / c.sigma(sigmaFloor);
  }

  /// Gate verdict for a disturbed dip at (x, y):
  ///  - non-finite position/value → target-like (fail open, never
  ///    throw, never blind);
  ///  - untrusted cell → target-like (fail open, never blind);
  ///  - |z| ≤ threshold → clutter-like (gated out: the dip looks like
  ///    this cell's ordinary clutter, not a new disturbance);
  ///  - |z| > threshold → target-like (kept).
  ClutterVerdict gate(double x, double y, double value) {
    if (!x.isFinite || !y.isFinite || !value.isFinite) {
      return const ClutterVerdict(
        targetLike: true,
        trusted: false,
        mahalanobis: null,
        reason: 'Non-finite position or dip — fail open, '
            'detection kept.',
      );
    }
    final z = mahalanobisAt(x, y, value);
    if (z == null) {
      return ClutterVerdict(
        targetLike: true,
        trusted: false,
        mahalanobis: null,
        reason: 'Cell untrusted (< $minSamplesPerCell quiet samples) — '
            'fail open, detection kept.',
      );
    }
    if (z <= mahalanobisThreshold) {
      return ClutterVerdict(
        targetLike: false,
        trusted: true,
        mahalanobis: z,
        reason: 'Dip within clutter fingerprint (|z|=${z.toStringAsFixed(2)} '
            '≤ ${mahalanobisThreshold.toStringAsFixed(2)}) — gated as '
            'link-shadow false alarm.',
      );
    }
    return ClutterVerdict(
      targetLike: true,
      trusted: true,
      mahalanobis: z,
      reason: 'Dip deviates from clutter fingerprint '
          '(|z|=${z.toStringAsFixed(2)} > '
          '${mahalanobisThreshold.toStringAsFixed(2)}) — kept.',
    );
  }

  /// Periodic refresh: halve every cell's effective sample weight
  /// (count and M2 scaled by 0.5, mean preserved as prior) — but
  /// floored at [minSamplesPerCell], with M2 scaled by the SAME ratio
  /// as the count, so a trusted cell stays trusted: a cell at 25
  /// samples with the default floor of 20 goes to 20 (ratio 0.8),
  /// not to 12 (which would drop it below the trust bar and
  /// contradict the "without a blind re-init window" promise). New
  /// observations then re-anchor the fingerprint without a blind
  /// window in which the gate is untrusted everywhere. This is the
  /// Shepherd-scale reading of BSense's "update every ~2 days /
  /// 700 frames" — a full reset would discard a session's clutter
  /// learning and fail open everywhere at once.
  void refresh({DateTime? now}) {
    for (final c in _cells.values) {
      c.halveWeight(minSamplesPerCell);
    }
    _lastRefreshPoll = _pollCount;
    _lastRefreshAt = now ?? DateTime.now();
  }
}

/// One gate verdict from [ClutterFingerprint.gate].
class ClutterVerdict {
  const ClutterVerdict({
    required this.targetLike,
    required this.trusted,
    required this.mahalanobis,
    required this.reason,
  });

  /// False = gated out as clutter; true = kept as a candidate disturbance.
  final bool targetLike;
  final bool trusted;
  final double? mahalanobis;
  final String reason;
}

/// Welford running mean / variance for one cell.
class _CellStats {
  double mean = 0.0;
  double m2 = 0.0;
  int count = 0;

  void add(double v) {
    count++;
    final d = v - mean;
    mean += d / count;
    m2 += d * (v - mean);
  }

  double sigma(double floor) {
    if (count < 2) return floor;
    final s = math.sqrt(m2 / (count - 1));
    return s.isFinite && s > floor ? s : floor;
  }

  void halveWeight([int floorCount = 1]) {
    if (count == 0) return;
    final newCount = math.max(floorCount, count ~/ 2);
    // Scale M2 by the same ratio as the count so the variance (and
    // hence sigma) is preserved when the floor binds; halving M2
    // while flooring the count would silently shrink sigma.
    m2 *= newCount / count;
    count = newCount;
  }
}

// ---------------------------------------------------------------------------
// 1b. BSense decayed spatial/velocity consistency confidence gate.
// ---------------------------------------------------------------------------

/// Decayed-consistency false-track gate (BSense stage 2, portable part).
///
/// Paper: spatial + velocity consistency with decay 0.9, match < 15 m,
/// thresholds τ_s = 1.7, τ_v = 1.1 — cuts false objects 61.34 → 2.58
/// per frame on 5G-A point clouds. Shepherd has no point clouds and no
/// Doppler stream, so the gate runs over the tracker's own fix
/// sequence (same constant-velocity prediction shape as
/// TrackConsistencyMonitor, which stays the operator-visible
/// inconsistency flag — this gate is the *false-track* verdict that
/// the merger / strict tracker mode can act on).
///
/// Parameter mapping (full table in the spec doc):
///  - decay 0.9 → ported verbatim. Confidence c ← 0.9·c + 0.1·instant,
///    instant = 1 when the fix matches prediction, else 0.
///  - match < 15 m → Shepherd spatialMatchM = 6.0 m. Why: BSense
///    localization error is 4.9 m mean, so 15 m ≈ 3× its error.
///    Shepherd's 6-node imaging bound is ~1–2 m, so 3× ≈ 6 m — same
///    3×-error rule, Shepherd error scale. Must also exceed the
///    tracker grid step (2.5 m) plus fix error (~1 m), which 6 m does.
///  - τ_s = 1.7 → ported verbatim as the dimensionless threshold on
///    the normalized spatial score residual / spatialMatchM. A fix
///    passes spatially when residual ≤ 1.7 × 6 m = 10.2 m. Loose on
///    purpose: this is a false-track gate (prune wild jumps), not a
///    localization test, and the 0.9 decay requires sustained passing.
///  - τ_v = 1.1 → ported verbatim as the dimensionless threshold on
///    the normalized velocity score |Δspeed| / 1 m/s, i.e. a 1.1 m/s
///    speed-mismatch tolerance. The 1 m/s scale is the Shepherd fix
///    scale (fix error ~1 m over ~1 s fixes). Starting estimate —
///    field-calibrate, do not quote as a paper result.
///  - Gate threshold: a track passes only when decayed confidence is
///    STRICTLY above 0.5. A single fix starts at 0.5 and therefore
///    never passes alone — the gate needs ≥ 2 consistent fixes. This
///    threshold is Shepherd's (not a paper number) and is labeled so.
///
/// KNOWN LIMITS (see file header): tangential motion that produces no
/// new disturbance yields no fixes, so this gate says nothing about
/// it; a long gap resets the gate instead of bridging it; an operator
/// who flies to defeat continuity/velocity checks defeats this gate.
class DecayedConsistencyGate {
  DecayedConsistencyGate({
    this.decay = 0.9,
    this.spatialMatchM = 6.0,
    this.tauS = 1.7,
    this.tauV = 1.1,
    this.velocityScaleMps = 1.0,
    this.gateThreshold = 0.5,
    this.gapReset = const Duration(seconds: 10),
  });

  /// Paper decay, verbatim.
  final double decay;

  /// Paper 15 m → Shepherd 6 m (3× the ~1–2 m imaging bound; see above).
  final double spatialMatchM;

  /// Paper τ_s, verbatim (dimensionless, on residual / spatialMatchM).
  final double tauS;

  /// Paper τ_v, verbatim (dimensionless, on |Δspeed| / velocityScale).
  final double tauV;

  /// Shepherd velocity scale for the τ_v normalization (1 m/s).
  final double velocityScaleMps;

  /// Shepherd gate level (NOT a paper number): strictly above 0.5.
  final double gateThreshold;

  /// Gap beyond this resets the gate (matches the tracker's 10 s idle
  /// reset and TrackConsistencyMonitor's gapReset). A reset after a
  /// gap is the occlusion-gap limit made explicit: the gate does NOT
  /// bridge 50–100 m BSense-style gaps, it re-acquires after them.
  final Duration gapReset;

  final List<_GateFix> _fixes = [];
  double _confidence = 0.5;
  bool _gapFlag = false;
  bool _reacquiring = false;
  String? _reason;

  /// Current decayed confidence (0..1). 0.5 = no evidence yet.
  double get confidence => _confidence;

  /// True when the last verdict passed the gate.
  bool get passes => _confidence > gateThreshold && !_gapFlag;

  /// Operator-readable reason for the last verdict.
  String? get reason => _reason;

  /// Feed one track fix. [speedMps] is the tracker's smoothed speed
  /// (may be null before velocity exists — then the velocity check is
  /// skipped, never failed: missing velocity info is uninformative,
  /// not evidence against the track).
  ConsistencyGateVerdict observe(
      DateTime t, double x, double y, double? speedMps) {
    if (_gapFlag) {
      // Re-acquiring after an occlusion gap: fresh history, neutral
      // confidence. The gap itself was already reported by noteGap /
      // the auto-reset below; the new fix is not yet a confirmed track.
      _fixes.clear();
      _confidence = 0.5;
      _gapFlag = false;
      _reacquiring = true;
      _reason = 'Re-acquiring after occlusion gap — confidence reset, '
          'track not yet re-confirmed.';
    } else if (_fixes.isNotEmpty &&
        t.difference(_fixes.last.t) > gapReset) {
      _fixes.clear();
      _confidence = 0.5;
      _reacquiring = true;
      _reason = 'Occlusion gap (> ${gapReset.inSeconds}s without a fix) '
          '— continuity broken, confidence reset, track not yet '
          're-confirmed. KNOWN LIMIT: this gate does not bridge '
          'occlusion gaps (cf. BSense 50–100 m gaps).';
    }
    var spatialPass = true;
    var velocityPass = true;
    double? spatialScore;
    double? velocityScore;
    // A prediction genuinely cannot be computed only when there are
    // >= 2 prior fixes but a time step is zero (duplicate
    // timestamps): then confidence is left UNCHANGED below — a
    // skipped prediction is never scored as a pass (instant = 1.0
    // would let an untested track through) and never as a fail.
    // With < 2 prior fixes there is no prediction either, but the
    // second fix is what establishes the track (see the first-fix /
    // second-fix branch below), so that case keeps its established
    // pass semantics and is NOT a skip.
    var predictionSkipped = false;
    if (_fixes.length >= 2) {
      final f1 = _fixes[_fixes.length - 1];
      final f2 = _fixes[_fixes.length - 2];
      final dt1 = t.difference(f1.t).inMicroseconds / 1e6;
      final dt0 = f1.t.difference(f2.t).inMicroseconds / 1e6;
      // Evaluated whenever both steps are positive — drivers poll
      // at ~0.25 s, and the old dt >= 0.5 s guard meant the
      // prediction was NEVER tested at app cadence, so strict mode
      // could never veto. The extrapolation clamp (≤ 4x) is kept,
      // so a long dt1 after a short dt0 cannot fling the prediction
      // across the field.
      if (dt1 > 0 && dt0 > 0) {
        final extrap = (dt1 / dt0).clamp(0.0, 4.0);
        final px = f1.x + (f1.x - f2.x) * extrap;
        final py = f1.y + (f1.y - f2.y) * extrap;
        final residual =
            math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
        spatialScore = residual / spatialMatchM;
        spatialPass = spatialScore <= tauS;
        if (speedMps != null && speedMps.isFinite) {
          final predSpeed =
              math.sqrt(math.pow(f1.x - f2.x, 2) + math.pow(f1.y - f2.y, 2)) /
                  dt0;
          velocityScore =
              (speedMps - predSpeed).abs() / velocityScaleMps;
          velocityPass = velocityScore <= tauV;
        }
      } else {
        predictionSkipped = true;
      }
    }
    final instant = (spatialPass && velocityPass) ? 1.0 : 0.0;
    if (_fixes.isEmpty) {
      // First fix: neutral, no prediction exists to match against.
      // After a gap, keep the gap/re-acquiring reason (set above)
      // instead of overwriting it with the generic first-fix note —
      // the verdict must still report the break.
      _confidence = 0.5;
      if (_reacquiring) {
        _reacquiring = false;
      } else {
        _reason = 'First fix — no prediction to match; gate needs '
            '≥ 2 consistent fixes.';
      }
    } else if (predictionSkipped) {
      // Confidence unchanged: the prediction could not be computed
      // (zero time step), so this fix is neither evidence for nor
      // against the track. It still joins the fix history below.
      _reason = 'Prediction skipped (zero time step between fixes) — '
          'confidence unchanged at ${_confidence.toStringAsFixed(3)}.';
    } else {
      _confidence = decay * _confidence + (1 - decay) * instant;
      if (instant == 1.0) {
        _reason = 'Fix matches prediction'
            '${spatialScore != null ? ' (spatial ${spatialScore.toStringAsFixed(2)} ≤ $tauS' : ''}'
            '${velocityScore != null ? ', velocity ${velocityScore.toStringAsFixed(2)} ≤ $tauV' : ''}'
            ') — confidence ${_confidence.toStringAsFixed(3)}.';
      } else {
        _reason = 'Fix breaks prediction'
            '${spatialScore != null ? ' (spatial ${spatialScore.toStringAsFixed(2)} > $tauS' : ''}'
            '${velocityScore != null ? ', velocity ${velocityScore.toStringAsFixed(2)} > $tauV' : ''}'
            ') — confidence decayed to ${_confidence.toStringAsFixed(3)}. '
            'KNOWN LIMIT: abrupt direction change (including tangential '
            'geometry change) decays confidence the same way '
            'misassociation does — the gate cannot tell them apart.';
      }
    }
    _fixes.add(_GateFix(t: t, x: x, y: y));
    if (_fixes.length > 8) _fixes.removeAt(0);
    return ConsistencyGateVerdict(
      passes: passes,
      confidence: _confidence,
      reason: _reason,
    );
  }

  /// Floor for missed-poll decay (NOT a paper number): without it,
  /// a sub-10 s quiet spell at 4 Hz (~36 missed polls) drives
  /// confidence from ~0.6 to ~0.01, and re-appearance then needs ~7
  /// consecutive passing fixes to re-exceed 0.5 — contradicting the
  /// "≥ 2 consistent fixes" re-confirm language. Floored at 0.4, a
  /// re-appearing track re-confirms in exactly 2 passing fixes
  /// (0.4 → 0.46 → 0.514). The floor never RAISES confidence: if a
  /// failed fix already pushed it below 0.4, missed polls leave it
  /// there. The kill still comes from [noteGap] / the gap reset in
  /// [observe].
  static const double missedPollConfidenceFloor = 0.4;

  /// One poll with no fix: confidence decays (BSense decay applied to
  /// absence too), floored at [missedPollConfidenceFloor]. A few
  /// missed polls degrade, they do not kill — the kill comes from
  /// [noteGap] / the gap reset in [observe].
  void noteMissedPoll() {
    if (_confidence > missedPollConfidenceFloor) {
      _confidence = math.max(
        missedPollConfidenceFloor,
        decay * _confidence,
      );
    }
    if (_confidence <= gateThreshold && _reason == null) {
      _reason = 'Confidence decayed below gate on missed polls.';
    }
  }

  /// A long gap with no fixes: reset, and flag it so the verdict
  /// reports gated-out (not neutral) until a new fix re-acquires.
  /// This is the occlusion-gap limit: the gate reports the break, it
  /// does not paper over it.
  void noteGap() {
    _fixes.clear();
    _confidence = 0.0;
    _gapFlag = true;
    _reason = 'Occlusion gap — track continuity broken, gate reset. '
        'KNOWN LIMIT: this gate does not bridge occlusion gaps '
        '(cf. BSense 50–100 m gaps); the track must re-confirm with '
        '≥ 2 consistent fixes.';
  }

  void reset() {
    _fixes.clear();
    _confidence = 0.5;
    _gapFlag = false;
    _reacquiring = false;
    _reason = null;
  }
}

class _GateFix {
  _GateFix({required this.t, required this.x, required this.y});
  final DateTime t;
  final double x;
  final double y;
}

/// One verdict from [DecayedConsistencyGate.observe].
class ConsistencyGateVerdict {
  const ConsistencyGateVerdict({
    required this.passes,
    required this.confidence,
    required this.reason,
  });
  final bool passes;
  final double confidence;
  final String? reason;
}

// ---------------------------------------------------------------------------
// 2. MilaGro gate pattern (NO ML, NO CNN).
// ---------------------------------------------------------------------------

/// One candidate point for the MilaGro-style gate (field meters).
/// Value equality on (x, y): Tracker.gateRtiCells keys a Set on these
/// points, and identity-based membership would silently drop a kept
/// cell whenever the prune step returned an equal-but-not-identical
/// instance. Two points at the same coordinates are the same cell.
class GatePoint {
  const GatePoint({required this.x, required this.y});
  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is GatePoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// One sharp-channel support point: a location the sharp channel says
/// is active (e.g. the midpoint of a disturbed anti-fade link, whose
/// tight ellipse is Shepherd's sharpest spatial evidence — the same
/// shape as the existing anti-fade-link gating).
class SharpSupport {
  const SharpSupport({required this.x, required this.y, this.at});
  final double x;
  final double y;

  /// When the sharp evidence was collected (null = fresh, no expiry).
  final DateTime? at;
}

/// Sharp-channel gate that prunes the broad channel's search space.
///
/// MilaGro's portable pattern (Picazo-Martinez et al.): mmWave
/// beam-training data pre-classifies as a coarse LOS gate, then 5 GHz
/// CSI disambiguates within the gated space. What ports is ONLY the
/// gate shape — sharpest/shortest-range channel prunes, broad channel
/// resolves — with NO CNN, NO classifier, and NO MilaGro accuracy
/// numbers (their 100% fused lab presence / 94% corridor tracking are
/// classification accuracies on trained labels, not Shepherd
/// localization, and are never claimed here).
///
/// Shepherd mapping:
///  - Sharp channel = disturbed anti-fade links (tight λ ellipses;
///    fadeLevel above the tripwire fade gate) and, where the caller
///    prefers it, the shortest links. The caller supplies support
///    points; this class does not decide what "sharp" is, so either
///    definition feeds it without code change.
///  - Broad channel = the RTI image cells / grid candidates (see
///    Tracker.gateRtiCells).
///  - Inter-band skew: MilaGro tolerates 100 ms collection skew with
///    no tight sync. Shepherd polls at ~0.25–1.5 s, so the skew
///    tolerance ports as [skewTolerance] = 2 s (one tracker cycle
///    scale), not 100 ms — a 100 ms window would expire every sharp
///    support before the broad channel ever saw it.
///
/// Fail-open rule (the paper's own lesson: mmWave alone is 100% at LOS
/// but 52% at NLOS, so sharp silence proves nothing): when there is NO
/// live sharp support, ALL broad candidates pass unchanged. The sharp
/// channel prunes only when it speaks; it never vetoes by silence.
class MilagroGate {
  MilagroGate({
    this.radiusM = 10.0,
    this.skewTolerance = const Duration(seconds: 2),
  });

  /// Pruning radius around each sharp support point. 10 m ≈ the
  /// tracker sigma / one RTI cell neighbourhood at Shepherd scale —
  /// a starting estimate, not a paper number (MilaGro's gate is a
  /// LOS/beam sector, not a meter radius).
  final double radiusM;

  /// Paper 100 ms → Shepherd 2 s (see class doc: poll-cadence scale).
  final Duration skewTolerance;

  /// Live sharp supports at [now]: drops supports older than
  /// [skewTolerance] (timestamped ones only; untimestamped = fresh).
  List<SharpSupport> liveSupports(List<SharpSupport> sharp,
      {DateTime? now}) {
    final t = now ?? DateTime.now();
    return [
      for (final s in sharp)
        if (s.at == null || t.difference(s.at!) <= skewTolerance) s,
    ];
  }

  /// Prune [candidates] to those within [radiusM] of a live sharp
  /// support. Empty live sharp set → all candidates returned
  /// unchanged (fail open — sharp silence is not a veto).
  List<GatePoint> prune(List<GatePoint> candidates,
      List<SharpSupport> sharp,
      {DateTime? now}) {
    final live = liveSupports(sharp, now: now);
    if (live.isEmpty) return List<GatePoint>.from(candidates);
    return [
      for (final c in candidates)
        if (live.any((s) =>
            math.sqrt(math.pow(c.x - s.x, 2) + math.pow(c.y - s.y, 2)) <=
            radiusM))
          c,
    ];
  }
}

// ---------------------------------------------------------------------------
// 3. Size-aware detection thresholds (Kim et al. caveat).
// ---------------------------------------------------------------------------

/// Size-aware detection thresholds.
///
/// Kim et al. (lane1 §6.12.1, CONFIRMED measurement): a larger subject
/// moderately increases error, a slimmer subject significantly
/// degrades detection across the distribution — body size directly
/// scales MPC shadowing. The Shepherd implication, adopted here, is
/// that detection thresholds must be size-aware, not one global
/// threshold.
///
/// Plumbing, not a detection-range claim: this class only scales a
/// caller-supplied base threshold by an expected size class. It does
/// NOT claim any new detection range, and it does NOT upgrade the
/// 6-node/15-link ~1–2 m imaging bound.
///
/// Factors are starting estimates to field-calibrate, NOT paper
/// numbers (Kim et al. report a qualitative degradation, no threshold
/// factors): S targets (slim/small UAS) get a LOWER bar because their
/// dips are weaker — otherwise the global threshold is tuned for M/L
/// and S is systematically missed; L targets get a HIGHER bar because
/// their dips are strong and a low bar on them admits clutter.
/// Unknown size → factor 1.0 (the global threshold, unchanged).
///
/// Circularity note: the tracker's size class is itself derived from
/// dip depth, so this threshold must be driven by an EXPECTED size
/// (operator setting / classifier prior / mission profile), never by
/// the size class of the very dip being thresholded. Tracker.update
/// takes [expectedSizeClass] as an explicit caller input for exactly
/// this reason; passing the track's own size class back in would be
/// circular and is documented as a misuse.
class SizeAwareThresholds {
  const SizeAwareThresholds({
    this.smallFactor = 0.7,
    this.mediumFactor = 1.0,
    this.largeFactor = 1.3,
  });

  /// S: lower bar for weaker slim-target dips (starting estimate).
  final double smallFactor;

  /// M: the global threshold, unchanged.
  final double mediumFactor;

  /// L: higher bar for strong large-target dips (starting estimate).
  final double largeFactor;

  /// Scale factor for a size class ('S' / 'M' / 'L', else 1.0).
  double factorFor(String? sizeClass) {
    switch (sizeClass) {
      case 'S':
        return smallFactor;
      case 'M':
        return mediumFactor;
      case 'L':
        return largeFactor;
      default:
        return 1.0;
    }
  }

  /// Effective threshold for an expected size class over [base].
  double thresholdFor(String? sizeClass, double base) =>
      base * factorFor(sizeClass);
}
