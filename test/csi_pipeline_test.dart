import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/generic_sensor_driver.dart';
import 'package:shepherd/services/sensor_protocol.dart';

final _now = DateTime(2026, 1, 1, 12);

CsiObservation _csi({
  String sensor = 'csi_ap_1',
  double devHz = 12.4,
  double? pathLossDb = 50.0,
  double? windMs = 1.8,
  bool windGated = false,
  DateTime? at,
}) =>
    CsiObservation(
      sensorId: sensor,
      timestamp: at ?? _now,
      devHz: devHz,
      pairsActive: 19,
      pathLossDb: pathLossDb,
      link: 'ap:buffalo',
      windMs: windMs,
      windGated: windGated,
    );

WindObservation _wind({double windMs = 1.8}) => WindObservation(
      sensorId: 'anem_1',
      timestamp: _now,
      windMs: windMs,
      gustMs: 2.4,
    );

void main() {
  group('CSI boost banding', () {
    test('dev_hz bands map to weak/moderate/strong', () {
      expect(csiBoostFor(2.9), 0.0); // below the noise floor: no claim
      expect(csiBoostFor(3.0), kCsiBoostWeak);
      expect(csiBoostFor(5.0), 0.05);
      expect(csiBoostFor(10.0), kCsiBoostModerate);
      expect(csiBoostFor(20.0), 0.10);
      expect(csiBoostFor(30.0), kCsiBoostStrong);
      expect(csiBoostFor(45.0), 0.15);
      expect(csiBoostFor(double.nan), 0.0);
    });

    test('CsiObservation.band follows the paper operating points', () {
      expect(_csi(devHz: 1.0).band, CsiBand.noise);
      expect(_csi(devHz: 5.0).band, CsiBand.smallMover);
      expect(_csi(devHz: 12.4).band, CsiBand.personAnimal);
      expect(_csi(devHz: 35.0).band, CsiBand.vehicleClass);
    });
  });

  group('merger properties with CSI evidence', () {
    test('CSI evidence is never subtractive (fuzzed)', () {
      final rng = math.Random(42);
      for (var i = 0; i < 200; i++) {
        final contribs = <GatedCorroboration>[
          for (var k = 0; k < 1 + rng.nextInt(4); k++)
            GatedCorroboration(
              sensorId: 'csi:$k',
              boost: [0.05, 0.10, 0.15][rng.nextInt(3)],
              gateWeight: rng.nextDouble(),
            ),
        ];
        final m = mergeTrackConfidence(
          baseConfidence: 0.2 + rng.nextDouble() * 0.6,
          contributions: contribs,
          trackConsistent: true,
        );
        expect(m.displayed, greaterThanOrEqualTo(m.base));
        expect(m.upgrade, greaterThanOrEqualTo(0.0));
      }
    });

    test('+0.35 total cap holds with CSI + Doppler + ELRS combined', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'csi:1', boost: 0.15, gateWeight: 1.0),
          GatedCorroboration(
              sensorId: 'doppler:1', boost: 0.10, gateWeight: 1.0),
          GatedCorroboration(
              sensorId: 'elrs:1', boost: 0.15, gateWeight: 1.0),
          GatedCorroboration(
              sensorId: 'pir:1', boost: 0.10, gateWeight: 1.0),
          GatedCorroboration(
              sensorId: 'pir:2', boost: 0.10, gateWeight: 1.0),
        ],
        trackConsistent: true,
      );
      expect(m.upgrade, lessThanOrEqualTo(0.35 + 1e-9));
      expect(m.displayed, lessThanOrEqualTo(kMaxDisplayConfidence));
    });

    test('inconsistent track suspends ALL upgrades', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'csi:1', boost: 0.15, gateWeight: 1.0),
        ],
        trackConsistent: false,
      );
      expect(m.upgrade, 0.0);
      expect(m.displayed, m.base);
      expect(m.applied, isEmpty);
      expect(m.trackConsistent, isFalse);
    });

    test('zero gate weight contributes exactly 0 (AV-FDTI case)', () {
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          // wind-gated CSI: the wire weight is exactly 0.
          GatedCorroboration(
              sensorId: 'csi:1', boost: 0.15, gateWeight: 0.0),
        ],
        trackConsistent: true,
      );
      expect(m.upgrade, 0.0);
      expect(m.applied, isEmpty);
    });
  });

  group('CSI link health gates', () {
    test('healthy link: all gates pass', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi());
      final h = d.csiHealthFor('csi_ap_1', _now);
      expect(h.enabled, isTrue);
    });

    test('path loss > 55 dB disables CSI stats (conservative default)',
        () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi(pathLossDb: 63.0));
      final h = d.csiHealthFor('csi_ap_1', _now);
      expect(h.enabled, isFalse);
      expect(h.reason, contains('63.0'));
    });

    test('unknown path loss fails safe to disabled', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi(pathLossDb: null));
      expect(d.csiHealthFor('csi_ap_1', _now).enabled, isFalse);
    });

    test('10 dB cross-link imbalance gate disables the weak link', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi(sensor: 'strong', pathLossDb: 40.0));
      d.ingestCsiForTest(_csi(sensor: 'weak', pathLossDb: 52.0));
      // Spread 12 dB > 10 dB: the weak link is untrustworthy…
      expect(d.csiHealthFor('weak', _now).enabled, isFalse);
      expect(d.csiHealthFor('weak', _now).reason, contains('imbalance'));
      // …the strong link is unaffected.
      expect(d.csiHealthFor('strong', _now).enabled, isTrue);
    });

    test('no wind source ⇒ CSI motion features OFF (fail-safe)', () {
      final d = GenericSensorDriver();
      // No WIND observation ingested anywhere.
      d.ingestCsiForTest(_csi(windMs: null, windGated: false));
      final h = d.csiHealthFor('csi_ap_1', _now);
      expect(h.enabled, isFalse);
      expect(h.reason, contains('no wind source'));
    });

    test('wind ≥ 3.5 m/s gates the motion claim', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind(windMs: 4.2));
      d.ingestCsiForTest(_csi(windMs: 4.2, windGated: true));
      final h = d.csiHealthFor('csi_ap_1', _now);
      expect(h.enabled, isFalse);
      expect(h.reason, contains('wind gated'));
    });

    test('stale CSI carries no weight', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi(
          at: _now.subtract(const Duration(seconds: 31))));
      expect(
          d.csiHealthFor('csi_ap_1', _now).enabled, isFalse);
      expect(d.liveCsiObservations(_now), isEmpty);
    });

    test('gate flips emit health events', () {
      final d = GenericSensorDriver();
      d.ingestWindForTest(_wind());
      d.ingestCsiForTest(_csi(pathLossDb: 50.0));
      expect(d.csiGateEvents, isEmpty); // first sighting: no flip
      d.ingestCsiForTest(_csi(pathLossDb: 63.0));
      expect(d.csiGateEvents, hasLength(1));
      expect(d.csiGateEvents.single, contains('LINK GATED'));
      expect(d.csiGateEvents.single, contains('63.0'));
      d.ingestCsiForTest(_csi(pathLossDb: 50.0));
      expect(d.csiGateEvents, hasLength(2));
      expect(d.csiGateEvents.last, contains('LINK UNGATED'));
    });

    test('gating never removes the RSSI tripwire (regression guard)',
        () async {
      final d = GenericSensorDriver();
      final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap_1',
        'dev_hz': 35.0,
        'path_loss_db': 70.0, // deeply gated…
        't': t,
      }));
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'ENERGY',
        'sensor': 'rf1',
        'level_db': -67.0,
        't': t,
      }));
      final links = await d.poll();
      // …but the ENERGY virtual tripwire link still exists: gating
      // only ever quiets CSI stats, never detection.
      expect(links.map((l) => l.toNode),
          contains('sensor:rf1:energy'));
      expect(
          links.where((l) => l.fromNode.contains('csi')), isEmpty);
      d.dispose();
    });
  });

  group('parser contract', () {
    test('CSI UDP JSON parses per the spec schema', () {
      final r = SensorProtocol.parseCsiUdpJson({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap_buffalo',
        'dev_hz': 12.4,
        'pairs_active': 19,
        'path_loss_db': 54.0,
        'link': 'ap:buffalo',
        'wind_ms': 1.8,
        'wind_gated': false,
        'lat': 35.10,
        'lon': -78.90,
        't': 1760000000.0,
      });
      final o = r.observation!;
      expect(o.devHz, 12.4);
      expect(o.pairsActive, 19);
      expect(o.pathLossDb, 54.0);
      expect(o.link, 'ap:buffalo');
      expect(o.windMs, 1.8);
      expect(o.windGated, isFalse);
      expect(r.warning, isNull);
    });

    test('wind_gated defaults true (fail-safe) when absent', () {
      final r = SensorProtocol.parseCsiUdpJson({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap_1',
        'dev_hz': 12.4,
      });
      expect(r.observation!.windGated, isTrue);
    });

    test('malformed CSI is skipped, never thrown', () {
      for (final bad in [
        {'type': 'sensor_obs', 'obs': 'CSI', 'sensor': 'x'}, // no dev_hz
        {
          'type': 'sensor_obs',
          'obs': 'CSI',
          'sensor': 'x',
          'dev_hz': -1.0
        },
        {
          'type': 'sensor_obs',
          'obs': 'CSI',
          'sensor': 'x',
          'dev_hz': 'lots'
        },
      ]) {
        final r = SensorProtocol.parseCsiUdpJson(bad);
        expect(r.observation, isNull);
      }
    });

    test('WIND UDP JSON + UART line parse', () {
      final r = SensorProtocol.parseWindUdpJson({
        'type': 'sensor_obs',
        'obs': 'WIND',
        'sensor': 'anem_1',
        'wind_ms': 4.2,
        'gust_ms': 6.1,
        't': 1760000000.0,
      });
      expect(r.observation!.windMs, 4.2);
      expect(r.observation!.gustMs, 6.1);
      expect(r.observation!.exceedsGate, isTrue);

      final l = SensorProtocol.parseWindLine('WIND anem1 4.2 6.1');
      expect(l.observation!.windMs, 4.2);
      expect(l.observation!.gustMs, 6.1);

      final l2 = SensorProtocol.parseWindLine('WIND anem1 1.5');
      expect(l2.observation!.windMs, 1.5);
      expect(l2.observation!.gustMs, isNull);

      final bad = SensorProtocol.parseWindLine('WIND anem1');
      expect(bad.observation, isNull);
    });

    test('unknown verbs are skipped, not counted malformed', () {
      final d = GenericSensorDriver();
      final malformedBefore = d.malformedCount;
      final ingestedBefore = d.ingestedCount;
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'FUTURE_VERB',
        'sensor': 'x',
        't': 1760000000.0,
      }));
      expect(d.malformedCount, malformedBefore);
      expect(d.ingestedCount, ingestedBefore);
      expect(SensorProtocol.isKnownVerb('FUTURE_VERB'), isFalse);
      expect(SensorProtocol.isKnownVerb('CSI'), isTrue);
      expect(SensorProtocol.isKnownVerb('WIND'), isTrue);
      d.dispose();
    });

    test('staleness horizons: CSI 30 s, WIND 5 min', () {
      expect(CsiObservation.stalenessHorizon,
          const Duration(seconds: 30));
      expect(
          WindObservation.stalenessHorizon, const Duration(minutes: 5));
      final staleWind = WindObservation(
        sensorId: 'a',
        timestamp: _now.subtract(const Duration(minutes: 6)),
        windMs: 1.0,
      );
      expect(staleWind.isStale, isTrue);
    });
  });
}
