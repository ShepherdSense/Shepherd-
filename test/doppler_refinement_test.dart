import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/radio_driver.dart';

final _now = DateTime(2026, 1, 1, 12);

// Geometry: radio south (0,−100), eNB east (100,0), track at origin
// moving north at 10 m/s (heading 0°). Predicted bistatic radial
// velocity = −(v·(û_tx+û_rx))/2 = +5.0 m/s (receding from the radio).
TrackEstimate _trackNorth({double speed = 10.0}) => TrackEstimate(
      timestamp: _now,
      x: 0,
      y: 0,
      speedMps: speed,
      headingDeg: 0.0,
      sizeClass: 'M',
      typeGuess: 'test',
      typeConfidence: 0.3,
      linksUsed: 3,
      relation: 'TRANSITING',
    );

DopplerRef _ref({
  double radialMs = 5.0,
  double snrDb = 15.0,
  bool refLocked = true,
  DateTime? at,
}) =>
    DopplerRef(
      radio: 'rtlsdr0',
      centerMhz: 1865.0,
      dopplerHz: -31.0,
      radialMs: radialMs,
      snrDb: snrDb,
      refLocked: refLocked,
      t: at ?? _now.subtract(const Duration(seconds: 5)),
    );

DopplerVerdict _correlate(TrackEstimate t, List<DopplerRef> refs) =>
    DopplerCorrelator.correlate(
      track: t,
      refs: refs,
      now: _now,
      radioX: 0,
      radioY: -100,
      enbX: 100,
      enbY: 0,
    );

void main() {
  group('DopplerRef parsing', () {
    test('parses the spec schema', () {
      final r = DopplerRef.tryParse({
        'v': 1,
        'kind': 'doppler_ref',
        'radio': 'rtlsdr0',
        'center_mhz': 1865.0,
        'doppler_hz': -14.2,
        'radial_ms': -1.14,
        'snr_db': 11.3,
        'ref_locked': true,
        't': 1729123456.789,
      })!;
      expect(r.radio, 'rtlsdr0');
      expect(r.centerMhz, 1865.0);
      expect(r.dopplerHz, -14.2);
      expect(r.radialMs, -1.14); // negative = approaching
      expect(r.snrDb, 11.3);
      expect(r.refLocked, isTrue);
    });

    test('malformed datagrams return null, never throw', () {
      expect(DopplerRef.tryParse({'v': 1, 'kind': 'nope'}), isNull);
      expect(
          DopplerRef.tryParse({
            'v': 1,
            'kind': 'doppler_ref',
            'radio': 'r',
            'center_mhz': 1865.0,
            'doppler_hz': double.nan,
            'radial_ms': 1.0,
            'snr_db': 10.0,
            'ref_locked': true,
            't': 1729123456.0,
          }),
          isNull);
    });
  });

  group('DopplerCorrelator', () {
    test('matching stream qualifies (≥2 agreements)', () {
      final v = _correlate(_trackNorth(), [
        _ref(radialMs: 5.1),
        _ref(radialMs: 4.8),
        _ref(radialMs: 9.9), // outside the gate: not an agreement
      ]);
      expect(v.agreements, 2);
      expect(v.qualified, isTrue);
      expect(v.score, closeTo(1 - math.exp(-1.0), 1e-9));
    });

    test('single agreement below the SNR bar does not qualify', () {
      final v = _correlate(_trackNorth(), [_ref(snrDb: 8.0)]);
      expect(v.agreements, 1);
      expect(v.qualified, isFalse);
    });

    test('single high-SNR (>12 dB) agreement qualifies', () {
      final v = _correlate(_trackNorth(), [_ref(snrDb: 13.0)]);
      expect(v.agreements, 1);
      expect(v.qualified, isTrue);
    });

    test('ref_locked=false refs are excluded (no reference, no claim)',
        () {
      final v = _correlate(_trackNorth(), [
        _ref(refLocked: false),
        _ref(refLocked: false),
      ]);
      expect(v.agreements, 0);
      expect(v.qualified, isFalse);
    });

    test('stale refs (past 120 s) do not count', () {
      final v = _correlate(_trackNorth(), [
        _ref(at: _now.subtract(const Duration(seconds: 121))),
        _ref(at: _now.subtract(const Duration(seconds: 122))),
      ]);
      expect(v.agreements, 0);
      expect(v.qualified, isFalse);
    });

    test('no velocity estimate ⇒ abstains (silence, not disagreement)',
        () {
      final t = TrackEstimate(
        timestamp: _now,
        x: 0,
        y: 0,
        sizeClass: 'M',
        typeGuess: 'test',
        typeConfidence: 0.3,
        linksUsed: 3,
        relation: 'HOLDING',
      );
      final v = _correlate(t, [_ref(), _ref()]);
      expect(v.qualified, isFalse);
      expect(v.agreements, 0);
    });

    test('disagreement contributes exactly 0; C_RF untouched', () {
      // Opposite-sign Doppler vs the track's predicted +5 m/s.
      final v = _correlate(_trackNorth(), [
        _ref(radialMs: -5.0),
        _ref(radialMs: -4.9),
      ]);
      expect(v.agreements, 0);
      expect(v.qualified, isFalse);
      // The merger sees no contribution: disagreement never deletes
      // or downgrades the tripwire track.
      final m = mergeTrackConfidence(
        baseConfidence: 0.54,
        contributions: const [],
        trackConsistent: true,
      );
      expect(m.displayed, 0.54);
      expect(m.upgrade, 0.0);
    });
  });

  group('merger properties with Doppler evidence', () {
    test('qualified Doppler upgrades; never subtractive (fuzzed)', () {
      final rng = math.Random(7);
      for (var i = 0; i < 200; i++) {
        final m = mergeTrackConfidence(
          baseConfidence: 0.2 + rng.nextDouble() * 0.6,
          contributions: [
            GatedCorroboration(
              sensorId: 'doppler:127.0.0.1:49161',
              boost: kDopplerBoost,
              gateWeight: rng.nextDouble(),
            ),
          ],
          trackConsistent: true,
        );
        expect(m.displayed, greaterThanOrEqualTo(m.base));
      }
    });

    test('Doppler boost class is the 0.10 velocity-consistency band', () {
      expect(kDopplerBoost, 0.10);
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'doppler:1',
              boost: kDopplerBoost,
              gateWeight: 1.0),
        ],
        trackConsistent: true,
      );
      // Small totals stay ~linear through the saturating curve.
      expect(m.upgrade, greaterThan(0.05));
      expect(m.upgrade, lessThanOrEqualTo(0.10 + 1e-9));
    });

    test('INCONSISTENT suspends the Doppler upgrade', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'doppler:1',
              boost: kDopplerBoost,
              gateWeight: 1.0),
        ],
        trackConsistent: false,
      );
      expect(m.upgrade, 0.0);
      expect(m.displayed, m.base);
    });
  });

  group('SdrDriver Doppler storage', () {
    test('doppler_ref datagrams land in the 120 s window', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
      d.datagramForTest(jsonEncode({
        'v': 1,
        'kind': 'doppler_ref',
        'radio': 'rtlsdr0',
        'center_mhz': 1865.0,
        'doppler_hz': -14.2,
        'radial_ms': -1.14,
        'snr_db': 11.3,
        'ref_locked': true,
        't': t,
      }));
      expect(d.recentDopplerRefs, hasLength(1));
      expect(d.recentDopplerRefs.single.radialMs, -1.14);
      d.dispose();
    });

    test('station config defaults to unconfigured (correlator abstains)',
        () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      expect(d.stationX, isNull);
      expect(d.enbX, isNull);
      d.dispose();
    });
  });
}
