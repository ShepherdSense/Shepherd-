import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/zmeta_adapter.dart';

final _t0 = DateTime.utc(2026, 10, 16, 22, 30, 0);

Map<String, dynamic> _obs() => zmetaObservation(
      platformId: 'shepherd-mesh-1',
      sensorId: 'silvus:node90550->node90551',
      ts: _t0,
      linkKey: 'silvus:node90550 → silvus:node90551',
      driverId: 'silvus',
      dipDepthDb: 14.2,
      direction: 'dip',
      durationSecs: 3.5,
      sizeEstimate: 'M',
      freqHz: 2440000000,
      bwHz: 10000000,
    );

void main() {
  group('primitives', () {
    test('uuid7 matches ZMeta event_id pattern', () {
      final id = zmetaUuid7();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-'
                r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue,
        reason: 'bad uuid7: $id',
      );
      expect(zmetaUuid7() == zmetaUuid7(), isFalse);
    });

    test('utcZ ends in Z, never an offset', () {
      expect(zmetaUtcZ(_t0), '2026-10-16T22:30:00Z');
      expect(zmetaUtcZ(DateTime.utc(2026, 1, 2, 3, 4, 5)),
          '2026-01-02T03:04:05Z');
    });
  });

  group('observation', () {
    test('envelope shape', () {
      final e = _obs();
      expect(e['zmeta_version'], '1.0');
      final ev = e['event'] as Map;
      expect(ev['event_type'], 'OBSERVATION_EVENT');
      expect(ev['event_subtype'], 'RF');
      expect(ev['ts'], '2026-10-16T22:30:00Z');
      expect(e['profile'], 'H');
      final src = e['source'] as Map;
      expect(src['platform_id'], 'shepherd-mesh-1');
      expect(src['node_role'], 'EDGE');
    });

    test('no confidence on OBSERVATION (contract 7.1)', () {
      final e = _obs();
      expect(e.containsKey('confidence'), isFalse);
      final payload = e['payload'] as Map;
      expect((payload['features'] as Map).containsKey('confidence'), isFalse);
    });

    test('no lineage on original observation', () {
      expect(_obs().containsKey('lineage'), isFalse);
    });

    test('disturbance depth stays in Shepherd-named features', () {
      final features = (_obs()['payload'] as Map)['features'] as Map;
      expect(features['shepherd_dip_depth_db'], 14.2);
      expect(features['center_freq_hz'], 2440000000);
      expect(features['bandwidth_hz'], 10000000);
    });

    test('bandwidth sentinel when unknown', () {
      final e = zmetaObservation(
        platformId: 'p',
        sensorId: 's',
        ts: _t0,
        linkKey: 'k',
        driverId: 'esp32',
        dipDepthDb: 8.0,
        direction: 'rise',
        durationSecs: 1.0,
        sizeEstimate: 'S',
        freqHz: 2442000000,
      );
      final features = (e['payload'] as Map)['features'] as Map;
      expect(features['bandwidth_hz'], 0.0);
      expect(features['center_freq_hz'], 2442000000);
      expect(features['shepherd_disturbance'], 'rise');
    });

    test('power_dbm is the documented sentinel, flagged in quality', () {
      final e = _obs();
      final features = (e['payload'] as Map)['features'] as Map;
      final quality = (e['payload'] as Map)['quality'] as Map;
      expect(features['power_dbm'], 0.0);
      expect(quality['shepherd_power_sentinel'], isTrue);
      expect(quality['calibration_state'], 'UNCALIBRATED');
    });

    test('timing_quality is schema-complete', () {
      final tq = (_obs()['payload'] as Map)['timing_quality'] as Map;
      expect(tq['time_source'], 'UNKNOWN');
      expect(tq['sync_state'], 'UNSYNCED');
      expect(tq['est_error_ms'], 60000);
      expect(tq['last_sync_ts'], '2026-10-16T22:30:00Z');
    });

    test('SDR extras ride in named features', () {
      final e = zmetaObservation(
        platformId: 'p',
        sensorId: 's',
        ts: _t0,
        linkKey: 'sdr:pluto → sdr:band-2g4',
        driverId: 'sdr',
        dipDepthDb: 9.5,
        direction: 'dip',
        durationSecs: 2.0,
        sizeEstimate: 'M',
        freqHz: 2437000000,
        bwHz: 20000000,
        sigHint: 'fhss-2g4',
        energyDbfs: -70.2,
      );
      final features = (e['payload'] as Map)['features'] as Map;
      expect(features['shepherd_sig_hint'], 'fhss-2g4');
      expect(features['shepherd_energy_dbfs'], -70.2);
    });

    test('degraded timing stays visible without PPS', () {
      final tq = (_obs()['payload'] as Map)['timing_quality'] as Map;
      expect(tq['time_source'], 'UNKNOWN');
      expect(tq['sync_state'], 'UNSYNCED');
    });
  });

  group('inference', () {
    test('envelope confidence required, lineage genuine', () {
      final obsId = (_obs()['event'] as Map)['event_id'] as String;
      final e = zmetaInference(
        platformId: 'shepherd-mesh-1',
        observationId: obsId,
        ts: _t0,
        label: 'PASSING',
        confidence: 0.82,
      );
      final ev = e['event'] as Map;
      expect(ev['event_type'], 'INFERENCE_EVENT');
      expect(ev['event_subtype'], 'CLASSIFICATION');
      expect(e['confidence'], 0.82);
      expect((e['lineage'] as Map)['based_on'], [obsId]);
      final payload = e['payload'] as Map;
      expect(payload['inference_type'], 'CLASSIFICATION');
      expect((payload['claim'] as Map)['label'], 'PASSING');
      expect((payload['model'] as Map)['name'], 'shepherd-disturbance-clf');
    });

    test('confidence clamps to 0..1', () {
      final e = zmetaInference(
        platformId: 'p',
        observationId: 'x',
        ts: _t0,
        label: 'FAULT',
        confidence: 99.0,
      );
      expect(e['confidence'], 1.0);
    });
  });

  group('sample export for the ZMeta validator', () {
    test('write sample JSONL', () {
      final obs = _obs();
      final obsId = (obs['event'] as Map)['event_id'] as String;
      final inf = zmetaInference(
        platformId: 'shepherd-mesh-1',
        observationId: obsId,
        ts: _t0.add(const Duration(seconds: 2)),
        label: 'PASSING',
        confidence: 0.82,
      );
      final sdrObs = zmetaObservation(
        platformId: 'shepherd-mesh-1',
        sensorId: 'sdr:pluto->band-2g4',
        ts: _t0.add(const Duration(seconds: 5)),
        linkKey: 'sdr:pluto → sdr:band-2g4',
        driverId: 'sdr',
        dipDepthDb: 11.0,
        direction: 'dip',
        durationSecs: 4.0,
        sizeEstimate: 'L',
        freqHz: 2437000000,
        bwHz: 20000000,
        sigHint: 'fhss-2g4',
        energyDbfs: -68.5,
      );
      final out = File('/tmp/zmeta_shepherd_sample.jsonl');
      out.writeAsStringSync('${[obs, inf, sdrObs].map(jsonEncode).join('\n')}\n');
      expect(out.existsSync(), isTrue);
    });
  });
}
