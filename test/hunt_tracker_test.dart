import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/hunt_tracker.dart';

final _t0 = DateTime(2026, 1, 1, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

class _FakeStepSource implements StepSource {
  final _controller = StreamController<DateTime>.broadcast();

  @override
  Stream<DateTime> get steps => _controller.stream;

  void step([DateTime? at]) => _controller.add(at ?? _t0);

  @override
  Future<void> dispose() async => _controller.close();
}

void main() {
  group('HuntHeatGrid accumulation', () {
    test('samples accumulate weak-to-strong weights in one cell', () {
      final grid = HuntHeatGrid();
      expect(grid.addSample(HuntSample(xEast: 1, yNorth: 1, rssiDbm: -100, at: _at(0))), isTrue);
      expect(grid.addSample(HuntSample(xEast: 1, yNorth: 1, rssiDbm: -40, at: _at(1))), isTrue);
      expect(grid.cellCount, 1);
      // -100 maps to 0.0, -40 maps to 1.0.
      expect(grid.loudest!.weight, closeTo(1.0, 1e-9));
      expect(grid.loudest!.bestRssi, -40);
      expect(grid.loudest!.sampleCount, 2);
    });

    test('mid-range RSSI maps to a mid weight', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -70, at: _t0));
      expect(grid.loudest!.weight, closeTo(0.5, 1e-9));
    });

    test('samples in different cells stay separate', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -60, at: _t0));
      grid.addSample(HuntSample(xEast: 10, yNorth: 10, rssiDbm: -60, at: _t0));
      expect(grid.cellCount, 2);
    });
  });

  group('HuntHeatGrid decay', () {
    test('one half-life halves the weight', () {
      final grid = HuntHeatGrid(halfLife: const Duration(seconds: 60));
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _t0));
      expect(grid.loudest!.weight, closeTo(1.0, 1e-9));
      grid.decay(now: _at(60));
      expect(grid.loudest!.weight, closeTo(0.5, 1e-9));
    });

    test('stale cells prune below the threshold', () {
      final grid = HuntHeatGrid(halfLife: const Duration(seconds: 60));
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _t0));
      grid.decay(now: _at(60 * 8)); // 1.0 -> ~0.004 < 0.01
      expect(grid.isEmpty, isTrue);
      expect(grid.loudest, isNull);
    });

    test('decay before the latest sample is a no-op', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _at(60)));
      grid.decay(now: _t0);
      expect(grid.loudest!.weight, closeTo(1.0, 1e-9));
    });
  });

  group('loudest-cell selection', () {
    test('highest accumulated weight wins', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -60, at: _t0));
      for (var i = 0; i < 3; i++) {
        grid.addSample(HuntSample(xEast: 10, yNorth: 0, rssiDbm: -60, at: _t0));
      }
      expect(grid.loudest!.centerX, closeTo(11.0, 1e-9));
    });

    test('equal-weight selection is deterministic', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -70, at: _t0));
      grid.addSample(HuntSample(xEast: 10, yNorth: 0, rssiDbm: -70, at: _t0));
      // Equal weight and equal best RSSI: either cell is acceptable,
      // but selection must be stable across reads.
      final first = grid.loudest;
      expect(grid.loudest, same(first));
      expect(first, isNotNull);
    });
  });

  group('empty / invalid behavior', () {
    test('empty grid has no loudest cell', () {
      final grid = HuntHeatGrid();
      expect(grid.isEmpty, isTrue);
      expect(grid.loudest, isNull);
      expect(grid.cellsSorted, isEmpty);
    });

    test('invalid samples are rejected and counted, never thrown', () {
      final grid = HuntHeatGrid();
      expect(grid.addSample(HuntSample(xEast: double.nan, yNorth: 0, rssiDbm: -60, at: _t0)), isFalse);
      expect(grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -200, at: _t0)), isFalse);
      expect(grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: 5, at: _t0)), isFalse);
      expect(grid.addSample(HuntSample(xEast: 1000, yNorth: 0, rssiDbm: -60, at: _t0)), isFalse);
      expect(grid.rejectedCount, 4);
      expect(grid.isEmpty, isTrue);
    });
  });

  group('out-of-order samples', () {
    test('earlier sample still accumulates but never rewinds the clock', () {
      final grid = HuntHeatGrid();
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -60, at: _at(60)));
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -60, at: _t0));
      expect(grid.loudest!.sampleCount, 2);
      expect(grid.latestSampleTime, _at(60));
    });
  });

  group('StepDetector', () {
    test('rise through threshold counts one step per footfall', () {
      final detector = StepDetector();
      expect(detector.onMagnitude(9.8, _at(0)), isFalse);
      expect(detector.onMagnitude(13.0, _at(1)), isTrue);
      expect(detector.onMagnitude(13.5, _at(2)), isFalse); // still above
      expect(detector.onMagnitude(9.8, _at(3)), isFalse);
      expect(detector.onMagnitude(12.0, _at(4)), isTrue);
      expect(detector.stepCount, 2);
    });

    test('refractory period blocks double counting', () {
      final detector = StepDetector();
      detector.onMagnitude(9.8, _at(0));
      expect(detector.onMagnitude(13.0, _at(0)), isTrue);
      detector.onMagnitude(9.8, _at(0));
      // 100 ms later: inside the 250 ms refractory window.
      expect(detector.onMagnitude(13.0, _t0.add(const Duration(milliseconds: 100))), isFalse);
      detector.onMagnitude(9.8, _t0.add(const Duration(milliseconds: 200)));
      expect(detector.onMagnitude(13.0, _t0.add(const Duration(milliseconds: 400))), isTrue);
      expect(detector.stepCount, 2);
    });

    test('non-finite magnitudes are ignored', () {
      final detector = StepDetector();
      expect(detector.onMagnitude(double.nan, _t0), isFalse);
      expect(detector.stepCount, 0);
    });
  });

  group('HuntWalker step integration between fixes', () {
    test('steps accumulate distance until the next fix resets', () {
      final walker = HuntWalker(stepLengthMeters: 0.75);
      walker.onGpsFix(0, 0);
      walker.onStep();
      walker.onStep();
      walker.onStep();
      walker.onStep();
      expect(walker.stepsSinceFix, 4);
      expect(walker.distanceSinceFix, closeTo(3.0, 1e-9));
      walker.onGpsFix(10, 5);
      expect(walker.stepsSinceFix, 0);
      expect(walker.distanceSinceFix, 0.0);
      expect(walker.lastFix, (xEast: 10.0, yNorth: 5.0));
    });

    test('no fix yet means distance still counts but no position is claimed', () {
      final walker = HuntWalker();
      walker.onStep();
      expect(walker.hasFix, isFalse);
      expect(walker.lastFix, isNull);
      expect(walker.distanceSinceFix, greaterThan(0));
    });
  });

  group('HuntTracker feedback', () {
    test('warmer samples beep, new loudest vibrates, rejected samples silent', () async {
      final beeps = <HuntFeedback>[];
      final vibrates = <HuntFeedback>[];
      final all = <HuntFeedback>[];
      final tracker = HuntTracker(
        onBeep: beeps.add,
        onVibrate: vibrates.add,
        onFeedback: all.add,
      );
      // First sample: new loudest cell -> vibrate, no beep (delta 0).
      expect(tracker.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -80, at: _t0)), isTrue);
      expect(vibrates, hasLength(1));
      expect(beeps, isEmpty);
      // +10 dB: warmer -> beep; same cell strengthened -> vibrate again.
      tracker.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -70, at: _at(1)));
      expect(beeps, hasLength(1));
      expect(beeps.first.gettingWarmer, isTrue);
      expect(vibrates, hasLength(2));
      // Colder sample: no beep.
      tracker.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -85, at: _at(2)));
      expect(beeps, hasLength(1));
      expect(all.last.gettingColder, isTrue);
      // Rejected sample: no feedback at all.
      expect(tracker.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -200, at: _at(3))), isFalse);
      expect(all, hasLength(3));
      await tracker.dispose();
    });

    test('step source feeds the walker', () async {
      final steps = _FakeStepSource();
      final tracker = HuntTracker(stepSource: steps);
      tracker.onGpsFix(0, 0);
      steps.step();
      steps.step();
      await Future<void>.delayed(Duration.zero);
      expect(tracker.walker.stepsSinceFix, 2);
      await tracker.dispose();
      await steps.dispose();
    });

    test('empty tracker has no loudest cell and no feedback', () async {
      final tracker = HuntTracker();
      expect(tracker.grid.isEmpty, isTrue);
      expect(tracker.grid.loudest, isNull);
      expect(tracker.acceptedSamples, 0);
      await tracker.dispose();
    });
  });
}
