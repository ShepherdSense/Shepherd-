/// Hunt heat-map mode (Shepherd v0.26.0, Fieldwatch-borrow item 3).
///
/// Concept adapted from Fieldwatch (MIT): walk around a selected
/// emitter, accumulate its RSSI samples into a spatial heat grid
/// (weak-to-strong), and use motion-sensor steps between GPS fixes
/// to keep the walk going when fixes are sparse.
///
/// HONEST LIMITS, stated here and in every UI string this service
/// produces:
///  - Hunt gives PROXIMITY, never a position fix. The `loudest`
///    cell is "the grid cell where the strongest samples were
///    heard", not "the emitter is here". Nothing in this file
///    outputs a lat/lon, an emitter position, or a bearing.
///  - Step distance uses a configurable step-length estimate
///    (default 0.75 m). It is an assumption, NOT a measurement, and
///    field accuracy is UNVERIFIED until hardware runs it.
///  - Phone-OS scan quotas and randomized MACs may hide quiet or
///    randomized radios; an empty grid means "nothing heard", never
///    "nothing present".
///  - Receive-only. Nothing here transmits anything.
///
/// STRUCTURE: everything except [SensorsPlusStepSource] is pure
/// Dart logic with no platform dependency, so the heat grid, the
/// step detector, and the walker are fully unit-testable. Only the
/// adapter at the bottom touches `sensors_plus`, and it degrades
/// to silence (no steps, no crash) if the sensor stream errors or
/// is unavailable. The adapter itself cannot be exercised without
/// hardware; that gap is reported, never faked.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// One RSSI observation of the hunted emitter, in hunt-local meters
/// relative to the hunt start point (east / north). Coordinates come
/// from the caller's GPS fix or step-dead-reckoned walk; this file
/// never converts them to lat/lon.
class HuntSample {
  const HuntSample({
    required this.xEast,
    required this.yNorth,
    required this.rssiDbm,
    required this.at,
  });

  final double xEast;
  final double yNorth;

  /// Received signal strength in dBm. Plausible phone-receive range
  /// is -120..0; anything outside is rejected by the grid.
  final double rssiDbm;
  final DateTime at;
}

/// One accumulated cell of the heat grid.
class HeatCell {
  HeatCell({
    required this.col,
    required this.row,
    required this.centerX,
    required this.centerY,
  });

  final int col;
  final int row;
  final double centerX;
  final double centerY;

  /// Accumulated strength weight (decays with [HuntHeatGrid.decay]).
  double weight = 0.0;

  /// Strongest (least negative) RSSI ever accumulated into this cell.
  double bestRssi = double.negativeInfinity;
  int sampleCount = 0;
  DateTime? lastSeen;

  /// Timestamp through which this cell's weight has already been
  /// decayed (see [HuntHeatGrid.decay]). Tracked per cell so that
  /// repeated decay() calls apply only the incremental interval —
  /// a stale cell fades on its own clock while a cell that keeps
  /// receiving samples is decayed only up to its latest sample.
  DateTime? decayedThrough;
}

/// Spatial heat grid for one hunted emitter.
///
/// Samples accumulate weak-to-strong: each sample adds a normalized
/// strength weight in 0..1, mapped linearly from [rssiFloorDbm]
/// (weight 0) to [rssiCeilingDbm] (weight 1). Stale cells fade via
/// [decay] (half-life) and are pruned below [pruneBelow].
class HuntHeatGrid {
  HuntHeatGrid({
    this.cellSizeMeters = 2.0,
    this.halfExtentMeters = 50.0,
    this.rssiFloorDbm = -100.0,
    this.rssiCeilingDbm = -40.0,
    this.halfLife = const Duration(seconds: 60),
    this.pruneBelow = 0.01,
  })  : assert(cellSizeMeters > 0),
        assert(halfExtentMeters > 0),
        assert(rssiCeilingDbm > rssiFloorDbm);

  final double cellSizeMeters;
  final double halfExtentMeters;
  final double rssiFloorDbm;
  final double rssiCeilingDbm;
  final Duration halfLife;
  final double pruneBelow;

  final Map<String, HeatCell> _cells = {};

  /// Samples rejected for invalid values or out-of-grid position.
  /// Rejection is counted, never silently swallowed.
  int rejectedCount = 0;

  /// Latest sample timestamp seen. Out-of-order samples still
  /// accumulate, but never move this clock backwards.
  DateTime? latestSampleTime;

  bool get isEmpty => _cells.isEmpty;
  int get cellCount => _cells.length;

  /// Cells strongest-first (weight, then best RSSI, then recency).
  List<HeatCell> get cellsSorted {
    final cells = _cells.values.toList()
      ..sort((a, b) {
        final w = b.weight.compareTo(a.weight);
        if (w != 0) return w;
        final r = b.bestRssi.compareTo(a.bestRssi);
        if (r != 0) return r;
        final aT = a.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bT = b.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bT.compareTo(aT);
      });
    return cells;
  }

  /// Loudest cell by accumulated weight, or null when no sample has
  /// been accepted. PROXIMITY ONLY — never a position fix.
  HeatCell? get loudest => isEmpty ? null : cellsSorted.first;

  String _key(int col, int row) => '$col,$row';

  /// Accumulates one sample. Returns false (and counts a rejection)
  /// for non-finite values, RSSI outside -120..0 dBm, or a position
  /// outside the grid extent. Never throws on caller input.
  bool addSample(HuntSample sample) {
    if (!sample.xEast.isFinite ||
        !sample.yNorth.isFinite ||
        !sample.rssiDbm.isFinite ||
        sample.rssiDbm < -120 ||
        sample.rssiDbm > 0 ||
        sample.xEast.abs() > halfExtentMeters ||
        sample.yNorth.abs() > halfExtentMeters) {
      rejectedCount++;
      return false;
    }
    final col = (sample.xEast / cellSizeMeters).floor();
    final row = (sample.yNorth / cellSizeMeters).floor();
    final isNew = !_cells.containsKey(_key(col, row));
    final cell = _cells.putIfAbsent(
      _key(col, row),
      () => HeatCell(
        col: col,
        row: row,
        centerX: (col + 0.5) * cellSizeMeters,
        centerY: (row + 0.5) * cellSizeMeters,
      ),
    );
    if (!isNew) {
      // Decay the cell's existing weight up to this sample's time
      // first, so a fresh sample is never decayed for time that
      // passed before it arrived (and so the per-cell clock below
      // stays exact across interleaved samples and decays).
      _decayCellTo(cell, sample.at);
    }
    final strength = ((sample.rssiDbm - rssiFloorDbm) /
            (rssiCeilingDbm - rssiFloorDbm))
        .clamp(0.0, 1.0);
    cell.weight += strength;
    if (sample.rssiDbm > cell.bestRssi) cell.bestRssi = sample.rssiDbm;
    cell.sampleCount++;
    cell.lastSeen = sample.at;
    // A new cell starts its decay clock at its first sample; an
    // existing cell's clock advances to this sample (its old weight
    // was just decayed up to here above). An out-of-order sample
    // never rewinds the clock.
    if (cell.decayedThrough == null ||
        sample.at.isAfter(cell.decayedThrough!)) {
      cell.decayedThrough = sample.at;
    }
    if (latestSampleTime == null || sample.at.isAfter(latestSampleTime!)) {
      latestSampleTime = sample.at;
    }
    return true;
  }

  /// Decays one cell's weight from its [HeatCell.decayedThrough]
  /// clock to [to] (no-op when [to] is not after that clock).
  /// Shared by [decay] and by [addSample], so the two paths can
  /// never double-apply the same interval.
  void _decayCellTo(HeatCell cell, DateTime to) {
    final base = cell.decayedThrough ?? cell.lastSeen;
    if (base == null) return;
    final elapsed = to.difference(base);
    if (elapsed.isNegative || elapsed.inMilliseconds == 0) return;
    final factor =
        math.pow(0.5, elapsed.inMilliseconds / halfLife.inMilliseconds)
            .toDouble();
    cell.weight *= factor;
    cell.decayedThrough = to;
  }

  /// Ages every cell PER CELL from that cell's own decay clock
  /// ([HeatCell.decayedThrough], falling back to its last sample)
  /// to [now], and prunes cells below [pruneBelow]. Repeated calls
  /// at increasing times therefore apply only the incremental
  /// interval each time — identical to a single decay to the same
  /// time — and a cell that stops receiving samples keeps fading
  /// while sampling continues elsewhere. Callers drive this on a
  /// timer or per sample; without it, weights simply do not decay
  /// (fail-safe: stale cells linger, they never become a
  /// confident wrong answer).
  void decay({required DateTime now}) {
    if (_cells.isEmpty) return;
    final dead = <String>[];
    for (final entry in _cells.entries) {
      _decayCellTo(entry.value, now);
      if (entry.value.weight < pruneBelow) dead.add(entry.key);
    }
    for (final key in dead) {
      _cells.remove(key);
    }
  }

  void clear() {
    _cells.clear();
    latestSampleTime = null;
  }
}

/// Abstraction over whatever produces steps on the device. The real
/// implementation is [SensorsPlusStepSource]; tests and platforms
/// without motion sensors inject a fake or a null source (no steps
/// is a valid, silent state — the grid still accumulates GPS-fix
/// samples).
abstract class StepSource {
  /// One event per detected step, stamped when detected.
  Stream<DateTime> get steps;

  /// Releases the underlying sensor subscription, if any.
  Future<void> dispose();
}

/// Pure step detector over accelerometer magnitude (m/s^2, gravity
/// included, so rest reads ~9.8).
///
/// A step is counted when magnitude rises through [threshold] after
/// having been below it, and at least [minStepInterval] has passed
/// since the previous step (refractory period against double
/// counting one footfall). No heading is estimated here: steps give
/// distance walked, not a position.
class StepDetector {
  StepDetector({
    this.threshold = 11.5,
    this.minStepInterval = const Duration(milliseconds: 250),
  });

  final double threshold;
  final Duration minStepInterval;

  bool _wasAbove = false;
  DateTime? _lastStepAt;
  int stepCount = 0;

  /// Feeds one magnitude sample. Returns true exactly when a step
  /// is counted.
  bool onMagnitude(double magnitude, DateTime at) {
    if (!magnitude.isFinite) return false;
    final above = magnitude >= threshold;
    var counted = false;
    if (above && !_wasAbove) {
      if (_lastStepAt == null ||
          at.difference(_lastStepAt!) >= minStepInterval) {
        stepCount++;
        _lastStepAt = at;
        counted = true;
      }
    }
    _wasAbove = above;
    return counted;
  }

  void reset() {
    _wasAbove = false;
    _lastStepAt = null;
    stepCount = 0;
  }
}

/// Motion-sensor step source backed by `sensors_plus`.
///
/// Subscribes to the device accelerometer, feeds magnitudes through
/// a [StepDetector], and emits one event per detected step. Any
/// stream error ends the subscription silently and records
/// [lastError] — a missing sensor degrades to "no steps", never to
/// invented steps. UNVERIFIED on hardware: no device in the build
/// sandbox has motion sensors, so this adapter ships untested on a
/// real phone; the detector it feeds is fully unit-tested.
class SensorsPlusStepSource implements StepSource {
  SensorsPlusStepSource({StepDetector? detector})
      : _detector = detector ?? StepDetector();

  final StepDetector _detector;
  final StreamController<DateTime> _controller =
      StreamController<DateTime>.broadcast();
  StreamSubscription<AccelerometerEvent>? _subscription;

  /// Last stream error, if the sensor stream failed. Null = no error.
  String? lastError;

  @override
  Stream<DateTime> get steps => _controller.stream;

  /// Starts the accelerometer subscription. Safe to call twice
  /// (second call is a no-op).
  void start() {
    if (_subscription != null) return;
    // Review fix: on platforms without motion sensors (e.g. the
    // Windows runner) creating the stream can throw synchronously;
    // that must degrade to "no steps" + lastError, never crash the
    // Hunt session start.
    try {
      _subscription = accelerometerEventStream().listen(
        (event) {
          final magnitude = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          );
          if (_detector.onMagnitude(magnitude, event.timestamp) &&
              !_controller.isClosed) {
            _controller.add(event.timestamp);
          }
        },
        onError: (Object error) {
          lastError = error.toString();
          _subscription = null;
        },
        cancelOnError: true,
      );
    } catch (e) {
      lastError = e.toString();
      _subscription = null;
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}

/// Walks between GPS fixes: steps accumulate distance since the
/// last fix; a new fix resets the count. Distance is steps times
/// [stepLengthMeters] — an ESTIMATE, not a measurement.
class HuntWalker {
  HuntWalker({this.stepLengthMeters = 0.75})
      : assert(stepLengthMeters > 0);

  /// Assumed step length in meters. Field accuracy UNVERIFIED.
  final double stepLengthMeters;

  double? _fixX;
  double? _fixY;
  int _stepsSinceFix = 0;

  int get stepsSinceFix => _stepsSinceFix;

  /// Estimated meters walked since the last GPS fix.
  double get distanceSinceFix => _stepsSinceFix * stepLengthMeters;

  bool get hasFix => _fixX != null;

  void onGpsFix(double xEast, double yNorth) {
    _fixX = xEast;
    _fixY = yNorth;
    _stepsSinceFix = 0;
  }

  void onStep() {
    _stepsSinceFix++;
  }

  /// Last fix position, if any.
  ({double xEast, double yNorth})? get lastFix =>
      _fixX == null ? null : (xEast: _fixX!, yNorth: _fixY!);
}

/// Proximity feedback for one accepted sample, delivered to the UI
/// through pure callbacks (no audio plugin in this build — the UI
/// wires beep/vibrate itself).
class HuntFeedback {
  const HuntFeedback({
    required this.rssiDbm,
    required this.deltaDb,
    required this.isNewLoudest,
  });

  final double rssiDbm;

  /// Change vs the previous accepted sample, in dB.
  final double deltaDb;
  bool get gettingWarmer => deltaDb >= 3.0;
  bool get gettingColder => deltaDb <= -3.0;

  /// True when this sample created or strengthened the loudest cell.
  final bool isNewLoudest;
}

/// One hunt session: heat grid + walker + feedback callbacks.
///
/// The session never outputs a position fix: [loudest] is a grid
/// cell in hunt-local meters, labeled proximity only.
///
/// DISPOSAL OWNERSHIP (v0.26.0 fix-pass): the CALLER owns the
/// step source. [HuntTracker.dispose] cancels only the tracker's
/// own subscription to the step stream; it deliberately does NOT
/// dispose the [StepSource] itself, so a caller that shares or
/// reuses the source (AppState keeps it beside the session in
/// `_huntStepSource` and closes it in `endHuntSession`) cannot
/// have it closed out from under it. Whoever created the source
/// must dispose it, exactly once, after disposing the tracker.
class HuntTracker {
  HuntTracker({
    HuntHeatGrid? grid,
    HuntWalker? walker,
    StepSource? stepSource,
    this.onBeep,
    this.onVibrate,
    this.onFeedback,
  })  : grid = grid ?? HuntHeatGrid(),
        walker = walker ?? HuntWalker() {
    _stepSubscription = stepSource?.steps.listen((_) => this.walker.onStep());
  }

  final HuntHeatGrid grid;
  final HuntWalker walker;

  /// Called when the signal is getting warmer (improvement of 3+ dB
  /// vs the previous accepted sample). The UI wires a beep here.
  final void Function(HuntFeedback feedback)? onBeep;

  /// Called when a sample creates or strengthens the loudest cell.
  /// The UI wires a vibration here.
  final void Function(HuntFeedback feedback)? onVibrate;

  /// Called for every accepted sample, regardless of direction.
  final void Function(HuntFeedback feedback)? onFeedback;

  StreamSubscription<DateTime>? _stepSubscription;
  double? _previousRssi;
  int acceptedSamples = 0;

  /// Feeds one RSSI sample into the grid. Rejected samples produce
  /// no feedback. Returns whether the sample was accepted.
  bool addSample(HuntSample sample) {
    final before = grid.loudest;
    final beforeWeight = before?.weight ?? 0.0;
    if (!grid.addSample(sample)) return false;
    acceptedSamples++;
    final delta = _previousRssi == null ? 0.0 : sample.rssiDbm - _previousRssi!;
    _previousRssi = sample.rssiDbm;
    final after = grid.loudest;
    final feedback = HuntFeedback(
      rssiDbm: sample.rssiDbm,
      deltaDb: delta,
      isNewLoudest: after != null &&
          (before == null ||
              !identical(after, before) ||
              after.weight > beforeWeight),
    );
    onFeedback?.call(feedback);
    if (feedback.gettingWarmer) onBeep?.call(feedback);
    if (feedback.isNewLoudest) onVibrate?.call(feedback);
    return true;
  }

  void onGpsFix(double xEast, double yNorth) => walker.onGpsFix(xEast, yNorth);

  /// Cancels the tracker's step subscription ONLY. The step source
  /// itself is the caller's to dispose (see the class docs) — this
  /// method never closes it.
  Future<void> dispose() async {
    await _stepSubscription?.cancel();
    _stepSubscription = null;
  }
}
