/// Fix-to-fix consistency monitor — the honest NEES analogue for the
/// covariance-free grid-search tracker.
///
/// The app tracker (lib/services/tracker.dart) keeps no state covariance,
/// so a textbook NEES (eᵀP⁻¹e on filter innovations, lane3 P8) is
/// impossible. What we CAN check is the tracker's own fix sequence:
/// predict each new fix from the track's recent constant-velocity motion,
/// normalize the residual by the tracker's expected fix-error scale, and
/// flag *sustained* large normalized innovations. Sustained
/// mis-prediction = the tracker is misassociating (blending two movers,
/// jumping between lobes) or the motion model is wrong — exactly the
/// failure a NEES monitor catches in a Kalman setting, and exactly what
/// P8 says RMSE alone cannot see (their overconfident variant had
/// similar RMSE but diverging NEES).
///
/// Expected fix-error scale: the tracker solves on a coarse grid (default
/// 2.5 m step) refined by a fine pass (0.6 m). Per-axis quantization
/// noise is step/√12 ≈ 0.72 m on the coarse grid; model + sampling noise
/// on top. [expectedFixErrorM] = 1.0 m is the honest round number for
/// that scale — a residual far above it, repeatedly, is not noise.
///
/// Two consumers:
///  1. Operator-visible flag: [TrackConsistency.consistent] = false with
///     a [TrackConsistency.reason] for the tracking screen / evidence
///     view ("track inconsistent — fix jumps exceed the motion model").
///  2. Merger gate: the confidence merger suspends ALL corroboration
///     upgrades while the track is inconsistent — upgrading a
///     misassociated track is the failure mode P8 warns about.
///
/// Hysteresis: 3 consecutive large innovations to flag, 5 consecutive
/// small ones to clear — a single jump (real maneuver onset) must not
/// flap the flag.
library;

import 'dart:math' as math;

/// One position fix fed to the monitor.
class ConsistencyFix {
  const ConsistencyFix({
    required this.t,
    required this.x,
    required this.y,
  });

  final DateTime t;
  final double x;
  final double y;
}

/// Snapshot of the monitor's verdict.
class TrackConsistency {
  const TrackConsistency({
    required this.consistent,
    required this.normalizedInnovation,
    required this.consecutiveLarge,
    this.reason,
  });

  /// False once the track has mis-predicted repeatedly.
  final bool consistent;

  /// Latest |innovation| / expected fix error (dimensionless, ≈ σ units).
  final double normalizedInnovation;

  /// How many large innovations in a row led here.
  final int consecutiveLarge;

  /// Operator-readable when inconsistent; null when consistent.
  final String? reason;
}

class TrackConsistencyMonitor {
  TrackConsistencyMonitor({
    this.expectedFixErrorM = 1.0,
    this.largeThreshold = 3.0,
    this.smallThreshold = 1.5,
    this.inconsistentAfter = 3,
    this.recoverAfter = 5,
    this.gapReset = const Duration(seconds: 10),
  });

  /// Per-axis expected fix error, meters (see file docstring).
  final double expectedFixErrorM;

  /// Normalized innovation above this = "large" (3σ).
  final double largeThreshold;

  /// Below this = "small" (consistent with the motion model).
  final double smallThreshold;

  /// Consecutive large innovations before flagging.
  final int inconsistentAfter;

  /// Consecutive small innovations before clearing the flag.
  final int recoverAfter;

  /// Fixes older than this apart reset the monitor — matches the
  /// tracker's own idle reset (10 s): a stale velocity state is not
  /// evidence of inconsistency.
  final Duration gapReset;

  final List<ConsistencyFix> _fixes = [];
  bool _consistent = true;
  double _lastNorm = 0.0;
  int _large = 0;
  int _small = 0;
  String? _reason;

  TrackConsistency get snapshot => TrackConsistency(
        consistent: _consistent,
        normalizedInnovation: _lastNorm,
        consecutiveLarge: _large,
        reason: _reason,
      );

  bool get consistent => _consistent;

  /// Feed one track fix. Predicts it from the two previous fixes
  /// (constant-velocity extrapolation), compares, normalizes.
  void observe(DateTime t, double x, double y) {
    final f = ConsistencyFix(t: t, x: x, y: y);
    final prev = _fixes;
    if (prev.length >= 2) {
      final f1 = prev[prev.length - 1];
      final f2 = prev[prev.length - 2];
      final dt1 = f.t.difference(f1.t).inMicroseconds / 1e6;
      final dt0 = f1.t.difference(f2.t).inMicroseconds / 1e6;
      if (dt1 >= 0.5 && dt0 >= 0.5) {
        // Constant-velocity prediction from the last two fixes.
        final extrap = (dt1 / dt0).clamp(0.0, 4.0);
        final px = f1.x + (f1.x - f2.x) * extrap;
        final py = f1.y + (f1.y - f2.y) * extrap;
        final innov = math.sqrt(
            (x - px) * (x - px) + (y - py) * (y - py));
        // Uncertainty grows with extrapolation distance (random-walk
        // intuition); never below the fix-error floor.
        final sigma = expectedFixErrorM * math.sqrt(1.0 + extrap);
        _lastNorm = innov / sigma;
        _update(_lastNorm);
      }
      // Fixes closer than 0.5 s apart are quantization-dominated —
      // skip the prediction, keep the fix.
    }
    _fixes.add(f);
    if (_fixes.length > 8) _fixes.removeAt(0);
  }

  /// Call when the tracker produced no fix: a long gap invalidates the
  /// velocity state, so the monitor resets instead of flagging.
  void noteGap(DateTime now) {
    if (_fixes.isEmpty) return;
    if (now.difference(_fixes.last.t) > gapReset) reset();
  }

  void _update(double norm) {
    if (norm > largeThreshold) {
      _large++;
      _small = 0;
      if (_large >= inconsistentAfter && _consistent) {
        _consistent = false;
        _reason = 'Track inconsistent: ${norm.toStringAsFixed(1)}σ fix '
            'jumps ×$_large — tracker may be misassociating or the '
            'motion model is wrong. Corroboration upgrades suspended.';
      } else if (!_consistent) {
        _reason = 'Track inconsistent: ${norm.toStringAsFixed(1)}σ fix '
            'jumps ×$_large — tracker may be misassociating or the '
            'motion model is wrong. Corroboration upgrades suspended.';
      }
    } else if (norm < smallThreshold) {
      _small++;
      _large = 0;
      if (_small >= recoverAfter && !_consistent) {
        _consistent = true;
        _reason = null;
        _small = 0;
      }
    } else {
      // Ambiguous band: fade the counters, don't flap the flag.
      _large = math.max(0, _large - 1);
      _small = math.max(0, _small - 1);
    }
  }

  void reset() {
    _fixes.clear();
    _consistent = true;
    _lastNorm = 0.0;
    _large = 0;
    _small = 0;
    _reason = null;
  }
}
