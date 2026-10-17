/// Tests for the gated confidence merger + track consistency monitor
/// (research finding #2: AV-FDTI entropy-gated asymmetric fusion,
/// lane3 P5; NEES consistency, lane3 P8).
///
/// The load-bearing invariants, each tied to the literature finding it
/// guards:
///
///  1. NEVER SUBTRACTIVE — the merger has no code path that lowers
///     confidence (P5: corroborating sensors never reduce the core).
///  2. STALE SENSOR → ZERO WEIGHT — a sensor with no recent data
///     contributes exactly nothing (P5's h → 0 gate).
///  3. SATURATION — N weak triggers can't manufacture certainty
///     (upgrade capped at +0.35, sublinear stacking).
///  4. GATED-vs-UNGATED ABLATION — the regression test for P5's
///     ASDNet result: a degraded modality moves confidence under a
///     naive sum, but not under the gated merger.
///  5. CONSISTENCY MONITOR — fires on injected fix jumps, stays quiet
///     on clean tracks; upgrades are suspended while inconsistent
///     (P8: RMSE alone can't catch misassociation).
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/sensor_observation.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/track_consistency.dart';

GatedCorroboration _g(String id, double boost, double w) =>
    GatedCorroboration(sensorId: id, boost: boost, gateWeight: w);

void main() {
  group('never subtractive (upgrade-only is structural)', () {
    test('random fuzz: displayed >= base over 2000 draws', () {
      final rng = Random(20261017);
      for (var i = 0; i < 2000; i++) {
        final base = rng.nextDouble(); // 0..1, incl. out-of-range guards
        final n = rng.nextInt(12);
        final contribs = [
          for (var j = 0; j < n; j++)
            _g('s$j',
                (rng.nextDouble() * 0.6) - 0.1, // some NEGATIVE: defensive path
                rng.nextDouble() * 1.2 - 0.1), // some out of [0,1]
        ];
        final m = mergeTrackConfidence(
          baseConfidence: base * 1.5 - 0.25, // force out-of-range bases too
          contributions: contribs,
          trackConsistent: rng.nextBool(),
        );
        expect(m.displayed, greaterThanOrEqualTo(m.base),
            reason: 'draw $i: merger subtracted confidence');
        expect(m.upgrade, greaterThanOrEqualTo(0));
        expect(m.displayed, lessThanOrEqualTo(kMaxDisplayConfidence));
      }
    });

    test('inconsistent track: upgrades suspended, never subtracted', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.5,
        contributions: [_g('pir1', 0.10, 1.0), _g('cam1', 0.15, 1.0)],
        trackConsistent: false,
      );
      expect(m.upgrade, 0);
      expect(m.displayed, m.base);
      expect(m.trackConsistent, isFalse);
      expect(m.applied, isEmpty);
    });

    test('empty contributions: displayed == base', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.42,
        contributions: const [],
        trackConsistent: true,
      );
      expect(m.displayed, 0.42);
      expect(m.upgrade, 0);
    });
  });

  group('reliability gate (AV-FDTI entropy gate)', () {
    test('stale observation → weight exactly 0', () {
      final horizon = stalenessHorizonFor(SensorObsType.range); // 10 s
      expect(
        reliabilityGate(
          alignmentQuality: 1.0,
          age: horizon + const Duration(seconds: 1),
          stalenessHorizon: horizon,
          sourceHealthy: true,
        ),
        0,
      );
      // At the horizon itself: freshness = 0 → 0.
      expect(
        reliabilityGate(
          alignmentQuality: 1.0,
          age: horizon,
          stalenessHorizon: horizon,
          sourceHealthy: true,
        ),
        0,
      );
    });

    test('unhealthy source → weight 0 even when fresh and aligned', () {
      expect(
        reliabilityGate(
          alignmentQuality: 1.0,
          age: const Duration(seconds: 1),
          stalenessHorizon: stalenessHorizonFor(SensorObsType.motion),
          sourceHealthy: false,
        ),
        0,
      );
    });

    test('zero alignment → weight 0', () {
      expect(
        reliabilityGate(
          alignmentQuality: 0.0,
          age: const Duration(seconds: 1),
          stalenessHorizon: stalenessHorizonFor(SensorObsType.binary),
          sourceHealthy: true,
        ),
        0,
      );
    });

    test('fresh + healthy + aligned → (0, 1]', () {
      final w = reliabilityGate(
        alignmentQuality: 0.8,
        age: const Duration(seconds: 2),
        stalenessHorizon: stalenessHorizonFor(SensorObsType.range),
        sourceHealthy: true,
      );
      expect(w, greaterThan(0));
      expect(w, lessThanOrEqualTo(1));
      // freshness = 1 - 2/10 = 0.8; weight = 0.8 * 0.8 = 0.64
      expect(w, closeTo(0.64, 1e-9));
    });

    test('per-type horizons reflect sensor cadence', () {
      expect(stalenessHorizonFor(SensorObsType.range),
          const Duration(seconds: 10));
      expect(stalenessHorizonFor(SensorObsType.binary),
          const Duration(minutes: 2));
      expect(stalenessHorizonFor(SensorObsType.motion),
          const Duration(seconds: 30));
    });
  });

  group('saturation (weak triggers cannot manufacture certainty)', () {
    test('20 weak PIR triggers cap at +0.35', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.5,
        contributions: [
          for (var i = 0; i < 20; i++) _g('pir$i', 0.10, 1.0),
        ],
        trackConsistent: true,
      );
      expect(m.upgrade, lessThanOrEqualTo(kMaxTotalUpgrade));
      expect(m.upgrade, greaterThan(0.3)); // asymptote is approached…
      expect(m.upgrade, lessThan(0.35)); // …but never reached
    });

    test('stacking is sublinear: 2nd corroboration adds less than 1st', () {
      MergedConfidence run(int n) => mergeTrackConfidence(
            baseConfidence: 0.4,
            contributions: [for (var i = 0; i < n; i++) _g('s$i', 0.2, 1.0)],
            trackConsistent: true,
          );
      final u1 = run(1).upgrade;
      final u2 = run(2).upgrade - u1;
      final u3 = run(3).upgrade - run(2).upgrade;
      expect(u2, lessThan(u1));
      expect(u3, lessThan(u2));
    });

    test('displayed confidence never reaches 1.0 (never identity)', () {
      final m = mergeTrackConfidence(
        baseConfidence: 1.0,
        contributions: [for (var i = 0; i < 50; i++) _g('s$i', 0.25, 1.0)],
        trackConsistent: true,
      );
      expect(m.displayed, lessThan(1.0));
      expect(m.displayed, lessThanOrEqualTo(kMaxDisplayConfidence));
    });
  });

  group('gated-vs-ungated ablation (P5 ASDNet regression test)', () {
    // Mirrors the AV-FDTI result: a degraded modality (here: a camera
    // whose motion report is stale — no recent data, h → 0) must not
    // move the fused confidence under gating, but DOES under a naive
    // ungated sum. If this test ever fails, the gate has been weakened
    // and fusion can degrade below the RF-only baseline — the exact
    // failure P5 demonstrated.
    test('degraded modality: naive sum moves, gated merge does not', () {
      const base = 0.54; // C_RF from 3 disturbed links
      const staleBoost = 0.15; // camera motion, but 5 min old (horizon 30 s)

      // NAIVE (ASDNet analogue): ungated sum of evidence.
      final naive = (base + staleBoost).clamp(0.0, 1.0);
      expect(naive, greaterThan(base),
          reason: 'naive fusion must move on the degraded modality');

      // GATED: the stale observation gets w = 0 from the reliability gate.
      final w = reliabilityGate(
        alignmentQuality: 1.0,
        age: const Duration(minutes: 5),
        stalenessHorizon: stalenessHorizonFor(SensorObsType.motion),
        sourceHealthy: true,
      );
      expect(w, 0, reason: 'stale sensor must gate to exactly 0');
      final m = mergeTrackConfidence(
        baseConfidence: base,
        contributions: [_g('cam1', staleBoost, w)],
        trackConsistent: true,
      );
      expect(m.displayed, base,
          reason: 'gated fusion must ignore the degraded modality');
      expect(m.applied, isEmpty);
    });

    test('healthy modality still upgrades under gating (no over-gating)', () {
      const base = 0.54;
      final w = reliabilityGate(
        alignmentQuality: 1.0,
        age: const Duration(seconds: 5),
        stalenessHorizon: stalenessHorizonFor(SensorObsType.motion),
        sourceHealthy: true,
      );
      expect(w, greaterThan(0));
      final m = mergeTrackConfidence(
        baseConfidence: base,
        contributions: [_g('cam1', 0.15, w)],
        trackConsistent: true,
      );
      expect(m.displayed, greaterThan(base));
    });
  });

  group('rfCoreConfidence (heuristic C_RF)', () {
    test('zero links → 0; monotonic; capped at 0.80', () {
      expect(rfCoreConfidence(linksUsed: 0), 0);
      final c1 = rfCoreConfidence(linksUsed: 1);
      final c3 = rfCoreConfidence(linksUsed: 3);
      final c6 = rfCoreConfidence(linksUsed: 6);
      final c60 = rfCoreConfidence(linksUsed: 60);
      expect(c1, greaterThan(0));
      expect(c3, greaterThan(c1));
      expect(c6, greaterThan(c3));
      expect(c60, lessThanOrEqualTo(0.80));
      expect(c60, greaterThan(0.79)); // asymptote approached
      // Documented shape: 1→~0.25, 3→~0.54, 6→~0.72.
      expect(c1, closeTo(0.25, 0.01));
      expect(c3, closeTo(0.54, 0.01));
      expect(c6, closeTo(0.72, 0.01));
    });
  });

  group('Corroboration quality channel', () {
    test('none carries quality 0', () {
      expect(Corroboration.none.quality, 0);
      expect(Corroboration.none.boost, 0);
    });

    test('quality is asserted to 0..1', () {
      expect(() => Corroboration(boost: 0.1, quality: 1.5),
          throwsA(isA<AssertionError>()));
      expect(() => Corroboration(boost: 0.1, quality: -0.1),
          throwsA(isA<AssertionError>()));
    });
  });

  group('TrackConsistencyMonitor (honest NEES analogue)', () {
    DateTime t0 = DateTime(2026, 10, 17, 6, 0, 0);

    /// Clean constant-velocity track: 2 m/s east, 1 s fixes, small noise.
    List<(DateTime, double, double)> cleanTrack(int n, {double noise = 0.3}) {
      final rng = Random(7);
      return [
        for (var i = 0; i < n; i++)
          (
            t0.add(Duration(milliseconds: i * 1000)),
            i * 2.0 + rng.nextDouble() * noise,
            rng.nextDouble() * noise,
          ),
      ];
    }

    test('stays quiet on a clean constant-velocity track', () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(20)) {
        mon.observe(t, x, y);
      }
      expect(mon.consistent, isTrue);
      expect(mon.snapshot.reason, isNull);
    });

    test('fires on injected fix jumps (teleporting fixes)', () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(6)) {
        mon.observe(t, x, y);
      }
      expect(mon.consistent, isTrue);
      // Inject three teleport jumps that alternate sides — a
      // misassociation signature no constant-velocity model predicts.
      const jumps = [(60.0, 0.0), (-60.0, 0.0), (60.0, 0.0)];
      for (var k = 0; k < jumps.length; k++) {
        final t = t0.add(Duration(milliseconds: (7 + k) * 1000));
        mon.observe(t, jumps[k].$1, jumps[k].$2);
      }
      expect(mon.consistent, isFalse);
      expect(mon.snapshot.reason, isNotNull);
      expect(mon.snapshot.normalizedInnovation, greaterThan(3.0));
    });

    test('a single jump does not flap the flag (hysteresis)', () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(6)) {
        mon.observe(t, x, y);
      }
      mon.observe(t0.add(const Duration(seconds: 7)), 60.0, 0.0);
      expect(mon.consistent, isTrue,
          reason: 'one jump (e.g. maneuver onset) must not flag');
    });

    test('recovers after sustained clean fixes', () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(6)) {
        mon.observe(t, x, y);
      }
      const jumps = [(60.0, 0.0), (-60.0, 0.0), (60.0, 0.0)];
      for (var k = 0; k < jumps.length; k++) {
        mon.observe(t0.add(Duration(milliseconds: (7 + k) * 1000)),
            jumps[k].$1, jumps[k].$2);
      }
      expect(mon.consistent, isFalse);
      // Resume a clean track from the jumped position.
      final t1 = t0.add(const Duration(seconds: 10));
      for (var i = 0; i < 8; i++) {
        mon.observe(t1.add(Duration(milliseconds: i * 1000)),
            150.0 + i * 2.0, 0.0);
      }
      expect(mon.consistent, isTrue);
      expect(mon.snapshot.reason, isNull);
    });

    test('long gap resets instead of flagging (stale velocity state)', () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(4)) {
        mon.observe(t, x, y);
      }
      mon.noteGap(t0.add(const Duration(seconds: 30)));
      // A fresh fix far away after a gap is a new track, not a jump.
      mon.observe(t0.add(const Duration(seconds: 31)), 500.0, 500.0);
      expect(mon.consistent, isTrue);
    });

    test('merger suspends upgrades while inconsistent (P8 failure mode)',
        () {
      final mon = TrackConsistencyMonitor();
      for (final (t, x, y) in cleanTrack(6)) {
        mon.observe(t, x, y);
      }
      const jumps = [(60.0, 0.0), (-60.0, 0.0), (60.0, 0.0)];
      for (var k = 0; k < jumps.length; k++) {
        mon.observe(t0.add(Duration(milliseconds: (7 + k) * 1000)),
            jumps[k].$1, jumps[k].$2);
      }
      expect(mon.consistent, isFalse);
      // The app wires mon.consistent into mergeTrackConfidence: while
      // false, even a fresh aligned corroboration adds nothing — a
      // misassociated track must not be upgraded.
      final m = mergeTrackConfidence(
        baseConfidence: 0.5,
        contributions: [_g('cam1', 0.15, 0.9)],
        trackConsistent: mon.consistent,
      );
      expect(m.upgrade, 0);
      expect(m.displayed, m.base);
    });
  });
}
