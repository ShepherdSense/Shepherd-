import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/tracker.dart';
import 'package:shepherd/services/tracker_gating.dart';

final _t0 = DateTime(2026, 1, 1, 12);

LinkSample _link(String a, String b, double dip, {double? threshold}) =>
    LinkSample(
      timestamp: _t0,
      fromNode: a,
      toNode: b,
      snr: 80,
      dip: dip,
      baseline: 90,
      threshold: threshold ?? double.nan,
    );

NodePosition _n(String id, double x, double y) =>
    NodePosition(nodeId: id, x: x, y: y);

Map<String, NodePosition> _nodes3() => {
      't:a': _n('t:a', 0, 0),
      't:b': _n('t:b', 40, 0),
      't:c': _n('t:c', 20, 35),
    };

final _defended = DefendedPoint(x: 0, y: 0);

void main() {
  // --- 1a. Clutter fingerprint: init / update -------------------------
  group('ClutterFingerprint init/update', () {
    test('cell untrusted below minSamples, trusted at/above', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 5);
      expect(fp.trustedAt(20, 0), isFalse);
      for (var i = 0; i < 4; i++) {
        fp.observe(20, 0, 2.0, now: _t0);
      }
      expect(fp.trustedAt(20, 0), isFalse);
      fp.observe(20, 0, 2.0, now: _t0);
      expect(fp.trustedAt(20, 0), isTrue);
    });

    test('mean tracks observations; distinct cells stay independent', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 3);
      for (final v in [1.0, 2.0, 3.0]) {
        fp.observe(5, 5, v, now: _t0);
      }
      for (final v in [10.0, 11.0, 12.0]) {
        fp.observe(95, 95, v, now: _t0);
      }
      expect(fp.statsAt(5, 5)!.mean, closeTo(2.0, 1e-9));
      expect(fp.statsAt(95, 95)!.mean, closeTo(11.0, 1e-9));
    });

    test('refresh halves effective sample weight, keeps mean as prior', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 5);
      for (var i = 0; i < 20; i++) {
        fp.observe(5, 5, 2.0, now: _t0);
      }
      expect(fp.samplesFor(5, 5), 20);
      fp.refresh(now: _t0);
      expect(fp.samplesFor(5, 5), 10);
      expect(fp.statsAt(5, 5)!.mean, closeTo(2.0, 1e-9));
    });

    test('non-finite observations are ignored', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 1);
      fp.observe(5, 5, double.nan, now: _t0);
      expect(fp.samplesFor(5, 5), 0);
    });

    test('non-finite coordinates are ignored, never throw in cellKey', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 1);
      fp.observe(double.nan, 5, 2.0, now: _t0);
      fp.observe(5, double.infinity, 2.0, now: _t0);
      fp.observe(5, 5, double.infinity, now: _t0);
      expect(fp.samplesFor(5, 5), 0);
      expect(fp.samplesFor(double.nan, 5), 0);
      expect(fp.trustedAt(double.nan, 5), isFalse);
      expect(fp.statsAt(double.nan, 5), isNull);
    });

    test('refresh floors halved count at minSamplesPerCell: a cell at '
        '25 samples stays trusted at the DEFAULT minSamplesPerCell '
        '(20) after refresh', () {
      final fp = ClutterFingerprint();
      for (var i = 0; i < 25; i++) {
        fp.observe(5, 5, 2.0, now: _t0);
      }
      expect(fp.samplesFor(5, 5), 25);
      expect(fp.trustedAt(5, 5), isTrue);
      fp.refresh(now: _t0);
      // Halved 25 -> 12 would drop below the trust bar; floored to 20.
      expect(fp.samplesFor(5, 5), 20);
      expect(fp.trustedAt(5, 5), isTrue);
      expect(fp.statsAt(5, 5)!.mean, closeTo(2.0, 1e-9));
    });

    test('refresh counts tracker polls, not observe calls', () {
      final fp = ClutterFingerprint(
          minSamplesPerCell: 5, refreshFrames: 3);
      for (var i = 0; i < 10; i++) {
        fp.observe(5, 5, 2.0, now: _t0);
      }
      // 10 observes with refreshFrames 3: no refresh yet — observes
      // do not advance the frame count (one poll feeds ~15 pairs, so
      // counting observes would refresh ~15x too often).
      expect(fp.samplesFor(5, 5), 10);
      fp.notePoll(now: _t0);
      fp.notePoll(now: _t0);
      expect(fp.samplesFor(5, 5), 10);
      fp.notePoll(now: _t0); // 3rd poll -> refresh halves 10 -> 5.
      expect(fp.samplesFor(5, 5), 5);
    });

    test('non-0.80 percentileK is rejected, not silently clamped', () {
      expect(() => ClutterFingerprint(percentileK: 0.90),
          throwsArgumentError);
      expect(() => ClutterFingerprint(percentileK: 0.50),
          throwsArgumentError);
      // The documented value still constructs fine.
      expect(ClutterFingerprint().mahalanobisThreshold,
          closeTo(1.2816, 1e-9));
    });
  });

  // --- 1a. Mahalanobis gating: accept / reject -------------------------
  group('Mahalanobis gating', () {
    ClutterFingerprint trained() {
      final fp = ClutterFingerprint(minSamplesPerCell: 10);
      // Quiet clutter cluster: mean 2.0, small spread.
      for (final v in [1.8, 2.0, 2.2, 1.9, 2.1, 2.0, 1.8, 2.2, 2.0, 1.9]) {
        fp.observe(20, 0, v, now: _t0);
      }
      return fp;
    }

    test('clutter-like dip is gated out', () {
      final v = trained().gate(20, 0, 2.05);
      expect(v.targetLike, isFalse);
      expect(v.trusted, isTrue);
      expect(v.mahalanobis!, lessThanOrEqualTo(1.2816));
    });

    test('far dip is kept as target-like', () {
      final v = trained().gate(20, 0, 20.0);
      expect(v.targetLike, isTrue);
      expect(v.mahalanobis!, greaterThan(1.2816));
    });

    test('untrusted cell fails open (kept, never blind)', () {
      final v = ClutterFingerprint().gate(999, 999, 1.0);
      expect(v.targetLike, isTrue);
      expect(v.trusted, isFalse);
      expect(v.mahalanobis, isNull);
    });

    test('non-finite gate inputs fail open, never throw', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 1);
      fp.observe(5, 5, 2.0, now: _t0);
      expect(fp.mahalanobisAt(double.nan, 5, 2.0), isNull);
      expect(fp.mahalanobisAt(5, 5, double.nan), isNull);
      final v1 = fp.gate(double.nan, 5, 2.0);
      expect(v1.targetLike, isTrue);
      expect(v1.trusted, isFalse);
      final v2 = fp.gate(5, 5, double.infinity);
      expect(v2.targetLike, isTrue);
      expect(v2.trusted, isFalse);
    });

    test('flat quantized clutter does not pass everything (sigma floor)', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 5);
      for (var i = 0; i < 5; i++) {
        fp.observe(5, 5, 2.0, now: _t0);
      }
      // 0.1 above a perfectly flat mean must still read as clutter.
      expect(fp.gate(5, 5, 2.1).targetLike, isFalse);
    });
  });

  // --- 1b. Decayed consistency gate ------------------------------------
  group('DecayedConsistencyGate', () {
    DecayedConsistencyGate gate() => DecayedConsistencyGate();

    test('consistent straight-line fixes pass after 2 fixes', () {
      final g = gate();
      var v = g.observe(_t0, 0, 0, null);
      expect(v.passes, isFalse); // single fix never passes
      v = g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      expect(v.passes, isTrue);
      v = g.observe(_t0.add(const Duration(seconds: 2)), 20, 0, 10);
      expect(v.passes, isTrue);
      expect(v.confidence, greaterThan(0.5));
    });

    test('wild jumps decay confidence below the gate', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      g.observe(_t0.add(const Duration(seconds: 2)), 20, 0, 10);
      // One failed match only decays 0.595 -> 0.536 (still passing):
      // the 0.9 decay requires SUSTAINED mismatch, by design.
      final v1 = g.observe(_t0.add(const Duration(seconds: 3)), 20, 40, 10);
      expect(v1.confidence, lessThan(0.595));
      expect(v1.passes, isTrue);
      // A second wild jump pushes it below the gate.
      final v2 = g.observe(_t0.add(const Duration(seconds: 4)), 0, 40, 10);
      expect(v2.passes, isFalse);
      expect(v2.confidence, lessThan(0.5));
    });

    test('tangential-motion case (KNOWN LIMIT): abrupt 90-degree turn '
        'decays confidence — gate cannot tell maneuver from '
        'misassociation, and a target producing no new disturbance '
        'yields no fixes at all', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      // Same speed magnitude, direction flips 90 degrees: velocity
      // magnitude passes, spatial prediction (20, 0) vs (10, 10)
      // fails (residual 14.1 m > 1.7 x 6 m).
      final v = g.observe(_t0.add(const Duration(seconds: 2)), 10, 10, 10);
      expect(v.passes, isFalse);
      expect(v.reason, contains('KNOWN LIMIT'));
    });

    test('occlusion-gap case (KNOWN LIMIT): gap resets, gate does not '
        'bridge it', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      g.observe(_t0.add(const Duration(seconds: 2)), 20, 0, 10);
      expect(g.passes, isTrue);
      g.noteGap();
      expect(g.passes, isFalse);
      expect(g.reason, contains('Occlusion gap'));
      // Re-acquiring: first fix after gap is neutral, not passed.
      final v = g.observe(_t0.add(const Duration(seconds: 30)), 60, 0, 10);
      expect(v.passes, isFalse);
      expect(v.reason, contains('Re-acquiring'));
    });

    test('missed polls decay confidence; auto gap reset on late fix', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      for (var i = 0; i < 8; i++) {
        g.noteMissedPoll();
      }
      expect(g.passes, isFalse);
      final v = g.observe(_t0.add(const Duration(seconds: 30)), 100, 0, 10);
      expect(v.reason, contains('Occlusion gap'));
    });

    test('missing velocity info is skipped, never failed', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, null);
      final v = g.observe(_t0.add(const Duration(seconds: 2)), 20, 0, null);
      expect(v.passes, isTrue);
    });

    test('wild jumps at 0.25 s driver cadence fail the gate (B1)', () {
      // The old dt >= 0.5 s guard meant predictions were never
      // evaluated at the 0.25 s poll cadence, so strict mode could
      // never veto. At 0.25 s spacing the prediction must be tested.
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(milliseconds: 250)), 10, 0, 40);
      final v3 =
          g.observe(_t0.add(const Duration(milliseconds: 500)), 20, 0, 40);
      expect(v3.passes, isTrue); // consistent straight line
      // First wild jump: spatial prediction (30, 0) vs (20, 40) fails.
      final v4 = g.observe(
          _t0.add(const Duration(milliseconds: 750)), 20, 40, 40);
      expect(v4.confidence, lessThan(0.595));
      // Second wild jump pushes confidence below the gate.
      final v5 = g.observe(
          _t0.add(const Duration(milliseconds: 1000)), 0, 40, 40);
      expect(v5.passes, isFalse);
      expect(v5.confidence, lessThan(0.5));
    });

    test('skipped prediction (zero time step) leaves confidence '
        'unchanged — never scored as a pass', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      g.observe(_t0.add(const Duration(seconds: 2)), 20, 0, 10);
      expect(g.confidence, closeTo(0.595, 1e-9));
      // Same timestamp as the previous fix: dt1 == 0, no prediction.
      final v = g.observe(_t0.add(const Duration(seconds: 2)), 30, 0, 10);
      expect(v.confidence, closeTo(0.595, 1e-9));
      expect(v.reason, contains('skipped'));
      expect(v.reason, contains('unchanged'));
    });

    test('9 s quiet spell (36 missed polls) re-confirms in exactly 2 '
        'passing fixes (missed-poll floor)', () {
      final g = gate();
      g.observe(_t0, 0, 0, null);
      g.observe(_t0.add(const Duration(seconds: 1)), 10, 0, 10);
      expect(g.confidence, closeTo(0.55, 1e-9));
      for (var i = 0; i < 36; i++) {
        g.noteMissedPoll();
      }
      // Without the floor this would be ~0.01 (needing ~7 fixes to
      // re-exceed 0.5); floored at 0.4 it needs exactly 2.
      expect(g.confidence, closeTo(0.4, 1e-9));
      expect(g.passes, isFalse);
      // Re-appearance 9 s after the last fix (< 10 s gap reset, so no
      // auto-reset): prediction extrapolates 9 s at the clamped 4x
      // from (10, 0) -> (50, 0); a fix there matches.
      final v1 = g.observe(_t0.add(const Duration(seconds: 10)), 50, 0, 10);
      expect(v1.confidence, closeTo(0.46, 1e-9));
      expect(v1.passes, isFalse);
      // Second re-appearing fix: prediction from (10, 0)@1 s and
      // (50, 0)@10 s extrapolates 1/9 -> (50 + 40/9, 0), speed 40/9.
      final v2 = g.observe(_t0.add(const Duration(seconds: 11)),
          50 + 40 / 9, 0, 40 / 9);
      expect(v2.confidence, closeTo(0.514, 1e-9));
      expect(v2.passes, isTrue);
    });
  });

  // --- 2. MilaGro gate pruning ------------------------------------------
  group('MilagroGate', () {
    test('sharp support prunes far candidates, keeps near ones', () {
      final g = MilagroGate(radiusM: 10.0);
      final cands = [
        const GatePoint(x: 0, y: 0),
        const GatePoint(x: 5, y: 0),
        const GatePoint(x: 50, y: 50),
      ];
      final kept = g.prune(cands, [const SharpSupport(x: 0, y: 0)]);
      expect(kept.length, 2);
      expect(kept, contains(cands[0]));
      expect(kept, contains(cands[1]));
    });

    test('no live sharp support passes everything (fail open, NLOS lesson)',
        () {
      final g = MilagroGate();
      final cands = [
        const GatePoint(x: 0, y: 0),
        const GatePoint(x: 50, y: 50),
      ];
      expect(g.prune(cands, []).length, 2);
      // Stale sharp support (beyond skew tolerance) also fails open.
      final stale = [
        SharpSupport(x: 0, y: 0, at: _t0),
      ];
      expect(
          g.prune(cands, stale, now: _t0.add(const Duration(seconds: 30)))
              .length,
          2);
    });

    test('GatePoint has value equality on (x, y)', () {
      expect(const GatePoint(x: 1, y: 2), const GatePoint(x: 1, y: 2));
      expect(const GatePoint(x: 1, y: 2) == const GatePoint(x: 1, y: 3),
          isFalse);
      const p1 = GatePoint(x: 1, y: 2);
      const p2 = GatePoint(x: 1, y: 2);
      final points = [p1, p2];
      expect(points.toSet().length, 1);
    });

    test('tracker gateRtiCells delegates to the gate', () {
      final t = Tracker();
      final cells = [
        const RtiCell(x: 0, y: 0, v: 0.9),
        const RtiCell(x: 50, y: 50, v: 0.8),
      ];
      final kept = t.gateRtiCells(
          cells, [const SharpSupport(x: 0, y: 0)]);
      expect(kept.length, 1);
      expect(kept.single.x, 0);
      expect(t.gateRtiCells(cells, []).length, 2);
    });
  });

  // --- 3. Size-aware thresholds ------------------------------------------
  group('SizeAwareThresholds', () {
    test('S < M < L, unknown size keeps the global threshold', () {
      const th = SizeAwareThresholds();
      expect(th.thresholdFor('S', 6.0), lessThan(6.0));
      expect(th.thresholdFor('M', 6.0), 6.0);
      expect(th.thresholdFor('L', 6.0), greaterThan(6.0));
      expect(th.thresholdFor(null, 6.0), 6.0);
      expect(th.thresholdFor('?', 6.0), 6.0);
    });

    test('tracker plumbing: expected-S detects a dip below the global '
        'threshold; expected-L does not', () {
      const th = SizeAwareThresholds();
      final samplesS = [
        _link('t:a', 't:b', 5.0),
        _link('t:b', 't:c', 1.0),
        _link('t:c', 't:a', 1.0),
      ];
      final trackS = Tracker().update(
        now: _t0,
        samples: samplesS,
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
        sizeThresholds: th,
        expectedSizeClass: 'S', // 6.0 x 0.7 = 4.2 < 5.0 dip
      );
      expect(trackS, isNotNull);
      final trackL = Tracker().update(
        now: _t0,
        samples: samplesS,
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
        sizeThresholds: th,
        expectedSizeClass: 'L', // 6.0 x 1.3 = 7.8 > 5.0 dip
      );
      expect(trackL, isNull);
      // No size plumbing = global threshold, unchanged behavior.
      final trackPlain = Tracker().update(
        now: _t0,
        samples: samplesS,
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
      );
      expect(trackPlain, isNull);
    });
  });

  // --- Tracker wiring: fingerprint + strict consistency gate ------------
  group('Tracker gating wiring', () {
    test('fingerprint gates a clutter-like disturbed link, keeps a '
        'far dip', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 10);
      // Link a-b midpoint is (20, 0). Train its cell as noisy clutter
      // centred on 5.0 with spread ~1.
      for (final v in [4.0, 5.0, 6.0, 4.5, 5.5, 5.0, 4.0, 6.0, 5.0, 4.5]) {
        fp.observe(20, 0, v, now: _t0);
      }
      final tracker = Tracker(clutterFingerprint: fp);
      // Per-link threshold 4.0: dip 5.2 IS disturbed, but sits inside
      // the trained clutter fingerprint at its midpoint cell, so the
      // fingerprint demotes it -> no track. This is a true demotion
      // case, not a below-threshold dip (the old version of this test
      // used threshold 6.0, under which 5.2 was never disturbed at
      // all and the assertion proved the threshold, not the gate).
      final gated = tracker.update(
        now: _t0,
        samples: [
          _link('t:a', 't:b', 5.2, threshold: 4.0),
          _link('t:b', 't:c', 1.0, threshold: 4.0),
          _link('t:c', 't:a', 1.0, threshold: 4.0),
        ],
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
      );
      expect(gated, isNull);
      // A far dip (20) in the same trained cell is kept -> track.
      final kept = tracker.update(
        now: _t0,
        samples: [
          _link('t:a', 't:b', 20.0, threshold: 6.0),
          _link('t:b', 't:c', 1.0, threshold: 6.0),
          _link('t:c', 't:a', 1.0, threshold: 6.0),
        ],
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
      );
      expect(kept, isNotNull);
    });

    test('fingerprint demotes a disturbed dip that matches trained '
        'clutter (per-link threshold below the dip)', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 10);
      for (final v in [4.0, 5.0, 6.0, 4.5, 5.5, 5.0, 4.0, 6.0, 5.0, 4.5]) {
        fp.observe(20, 0, v, now: _t0);
      }
      final tracker = Tracker(clutterFingerprint: fp);
      // Per-link threshold 4.0: dip 5.2 IS disturbed, but matches the
      // trained clutter fingerprint at its midpoint cell -> demoted.
      final gated = tracker.update(
        now: _t0,
        samples: [
          _link('t:a', 't:b', 5.2, threshold: 4.0),
          _link('t:b', 't:c', 1.0, threshold: 4.0),
          _link('t:c', 't:a', 1.0, threshold: 4.0),
        ],
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
      );
      expect(gated, isNull);
      // Same setup, far dip 20: kept -> track.
      final kept = tracker.update(
        now: _t0,
        samples: [
          _link('t:a', 't:b', 20.0, threshold: 4.0),
          _link('t:b', 't:c', 1.0, threshold: 4.0),
          _link('t:c', 't:a', 1.0, threshold: 4.0),
        ],
        nodes: _nodes3(),
        dipThreshold: 6.0,
        defended: _defended,
      );
      expect(kept, isNotNull);
    });

    test('strict consistency gate suppresses a failing estimate, '
        'non-strict reports it', () {
      // Same disturbed link twice (consistent), then a different link
      // disturbed: the grid estimate jumps across the field, the gate
      // prediction fails, confidence falls below the gate.
      List<LinkSample> abDisturbed() => [
            _link('t:a', 't:b', 20.0, threshold: 6.0),
            _link('t:b', 't:c', 1.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ];
      List<LinkSample> bcDisturbed() => [
            _link('t:a', 't:b', 1.0, threshold: 6.0),
            _link('t:b', 't:c', 20.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ];
      // NOTE on strict semantics: a single fix starts at confidence
      // 0.5, which never passes the gate, so strict mode suppresses
      // the FIRST update too and reports the second (consistent) one.
      // The harness therefore only asserts non-null on the loose run.
      TrackEstimate? run(Tracker tr, {required bool assertFirstTwo}) {
        TrackEstimate? last;
        last = tr.update(
            now: _t0,
            samples: abDisturbed(),
            nodes: _nodes3(),
            dipThreshold: 6.0,
            defended: _defended);
        if (assertFirstTwo) expect(last, isNotNull);
        last = tr.update(
            now: _t0.add(const Duration(seconds: 2)),
            samples: abDisturbed(),
            nodes: _nodes3(),
            dipThreshold: 6.0,
            defended: _defended);
        if (assertFirstTwo) expect(last, isNotNull);
        return tr.update(
            now: _t0.add(const Duration(seconds: 4)),
            samples: bcDisturbed(),
            nodes: _nodes3(),
            dipThreshold: 6.0,
            defended: _defended);
      }

      final loose = Tracker(consistencyGate: DecayedConsistencyGate());
      final looseEst = run(loose, assertFirstTwo: true);
      expect(looseEst, isNotNull); // non-strict reports despite failure
      expect(loose.lastConsistencyGate, isNotNull);
      expect(loose.lastConsistencyGate!.passes, isFalse);
      final strict = Tracker(
          consistencyGate: DecayedConsistencyGate(),
          consistencyGateStrict: true);
      expect(run(strict, assertFirstTwo: false),
          isNull); // strict suppresses the failing fix
      expect(strict.lastConsistencyGate!.passes, isFalse);
    });

    test('strict veto leaves no tracker state: veto followed by >10 s '
        'idle resets (B2)', () {
      List<LinkSample> abDisturbed() => [
            _link('t:a', 't:b', 20.0, threshold: 6.0),
            _link('t:b', 't:c', 1.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ];
      List<LinkSample> bcDisturbed() => [
            _link('t:a', 't:b', 1.0, threshold: 6.0),
            _link('t:b', 't:c', 20.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ];
      List<LinkSample> quiet() => [
            _link('t:a', 't:b', 1.0, threshold: 6.0),
            _link('t:b', 't:c', 1.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ];
      final strict = Tracker(
          consistencyGate: DecayedConsistencyGate(),
          consistencyGateStrict: true);
      // First fix suppressed in strict mode (confidence 0.5, never
      // strictly above); second consistent fix is reported.
      expect(
          strict.update(
              now: _t0,
              samples: abDisturbed(),
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNull);
      expect(
          strict.update(
              now: _t0.add(const Duration(seconds: 2)),
              samples: abDisturbed(),
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNotNull);
      // Jumping estimate: gate fails, strict vetoes.
      expect(
          strict.update(
              now: _t0.add(const Duration(seconds: 4)),
              samples: bcDisturbed(),
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNull);
      expect(strict.lastConsistencyGate!.passes, isFalse);
      // Idle poll 11 s after the last REPORTED detect (+2 s): the
      // vetoed +4 s fix must not have refreshed _lastDetect, or this
      // poll (9 s after +4 s) would not reset. Fixed behaviour:
      // idle reset fires and clears the gate verdict.
      expect(
          strict.update(
              now: _t0.add(const Duration(seconds: 13)),
              samples: quiet(),
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNull);
      expect(strict.lastConsistencyGate, isNull);
    });

    test('geometry-starved poll counts as a missed poll and does not '
        'refresh lastDetect', () {
      List<LinkSample> abDisturbed() => [
            _link('t:a', 't:b', 20.0, threshold: 6.0),
          ];
      final tr = Tracker(consistencyGate: DecayedConsistencyGate());
      expect(
          tr.update(
              now: _t0,
              samples: [
                _link('t:a', 't:b', 20.0, threshold: 6.0),
                _link('t:b', 't:c', 1.0, threshold: 6.0),
                _link('t:c', 't:a', 1.0, threshold: 6.0),
              ],
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNotNull);
      // Second consistent fix: gate confidence 0.55.
      tr.update(
          now: _t0.add(const Duration(seconds: 2)),
          samples: [
            _link('t:a', 't:b', 20.0, threshold: 6.0),
            _link('t:b', 't:c', 1.0, threshold: 6.0),
            _link('t:c', 't:a', 1.0, threshold: 6.0),
          ],
          nodes: _nodes3(),
          dipThreshold: 6.0,
          defended: _defended);
      expect(tr.consistencyGate!.confidence, closeTo(0.55, 1e-9));
      // Only 2 positioned nodes: geometry gate returns null, and the
      // missed-poll call decays gate confidence (symmetry with the
      // empty-disturbed path).
      final twoNodes = {
        't:a': _n('t:a', 0, 0),
        't:b': _n('t:b', 40, 0),
      };
      expect(
          tr.update(
              now: _t0.add(const Duration(seconds: 4)),
              samples: abDisturbed(),
              nodes: twoNodes,
              dipThreshold: 6.0,
              defended: _defended),
          isNull);
      expect(tr.consistencyGate!.confidence, closeTo(0.495, 1e-9));
      // And _lastDetect was NOT refreshed to +4 s: an idle poll at
      // +13 s (11 s after the last real detect at +2 s) resets.
      expect(
          tr.update(
              now: _t0.add(const Duration(seconds: 13)),
              samples: [
                _link('t:a', 't:b', 1.0, threshold: 6.0),
                _link('t:b', 't:c', 1.0, threshold: 6.0),
                _link('t:c', 't:a', 1.0, threshold: 6.0),
              ],
              nodes: _nodes3(),
              dipThreshold: 6.0,
              defended: _defended),
          isNull);
      expect(tr.lastConsistencyGate, isNull);
    });

    test('disturbed-but-demoted dips never feed the fingerprint (S3)', () {
      final fp = ClutterFingerprint(minSamplesPerCell: 10);
      // Trained cell mean 4.95 at the a-b midpoint (20, 0).
      for (final v in [4.0, 5.0, 6.0, 4.5, 5.5, 5.0, 4.0, 6.0, 5.0, 4.5]) {
        fp.observe(20, 0, v, now: _t0);
      }
      expect(fp.statsAt(20, 0)!.mean, closeTo(4.95, 1e-9));
      final tracker = Tracker(clutterFingerprint: fp);
      // Dip 5.6 is disturbed (threshold 4.0) but inside the clutter
      // fingerprint (|z| ~ 0.9), so it is demoted on every poll. If
      // demoted dips fed the fingerprint, 20 repeats would drag the
      // mean from 4.95 toward 5.6 (to ~5.38); genuinely-quiet-only
      // feeding leaves it exactly where training put it.
      for (var i = 0; i < 20; i++) {
        final est = tracker.update(
          now: _t0,
          samples: [
            _link('t:a', 't:b', 5.6, threshold: 4.0),
            _link('t:b', 't:c', 1.0, threshold: 4.0),
            _link('t:c', 't:a', 1.0, threshold: 4.0),
          ],
          nodes: _nodes3(),
          dipThreshold: 6.0,
          defended: _defended,
        );
        expect(est, isNull);
      }
      expect(fp.samplesFor(20, 0), 10);
      expect(fp.statsAt(20, 0)!.mean, closeTo(4.95, 1e-9));
    });
  });
}
