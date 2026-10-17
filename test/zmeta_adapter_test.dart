import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/sensor_observation.dart';
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
      expect(e['zmeta_version'], '1.1.0');
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

  group('sensor geo (ZMeta 21.8 declared-2D)', () {
    Map<String, dynamic> obsGeo() => zmetaObservation(
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
          sensorGeo: const ZmetaSensorGeo(
            lat: 35.1391,
            lon: -79.0063,
            altM: 87.5,
            source: 'node-midpoint',
            accuracyM: 4.0,
            ageSec: 12,
          ),
        );

    test('2-D canonical geo, no alt_m', () {
      final e = obsGeo();
      final payload = e['payload'] as Map;
      final geo = payload['geo'] as Map;
      expect(geo['lat'], 35.1391);
      expect(geo['lon'], -79.0063);
      expect(geo['dimensionality'], '2D');
      expect(geo.containsKey('alt_m'), isFalse,
          reason: '2-D geo must prohibit alt_m (21.8)');
    });

    test('device altitude rides in features, flagged in quality', () {
      final e = obsGeo();
      final payload = e['payload'] as Map;
      final features = payload['features'] as Map;
      expect(features['shepherd_sensor_alt_m'], 87.5);
      final quality = payload['quality'] as Map;
      expect(quality['geo_status'], 'VERTICAL_UNAVAILABLE');
      expect(quality['shepherd_geo_source'], 'node-midpoint');
      expect(quality['shepherd_geo_accuracy_m'], 4.0);
      expect(quality['shepherd_geo_age_s'], 12);
      final note = quality['shepherd_geo_note'] as String;
      expect(note.contains('not target'), isTrue);
    });

    test('null geo omits geo, keeps UNAVAILABLE', () {
      final e = _obs(); // no sensorGeo
      final payload = e['payload'] as Map;
      expect(payload.containsKey('geo'), isFalse);
      expect((payload['quality'] as Map)['geo_status'], 'UNAVAILABLE');
      expect(
          (payload['features'] as Map).containsKey('shepherd_sensor_alt_m'),
          isFalse);
    });
  });

  group('platform heartbeat (SYSTEM_EVENT / PLATFORM_STATUS)', () {
    Map<String, dynamic> hb() => zmetaPlatformStatus(
          platformId: 'shepherd-mesh-1',
          ts: _t0,
          state: 'NOMINAL',
          nodeCount: 4,
          detectionCount: 17,
          heartbeatIntervalSec: 60,
          sensorGeo: const ZmetaSensorGeo(
            lat: 35.1391,
            lon: -79.0063,
            source: 'phone-gps',
            ageSec: 30,
          ),
        );

    test('envelope + subtype match', () {
      final e = hb();
      expect(e['zmeta_version'], '1.1.0');
      final ev = e['event'] as Map;
      expect(ev['event_type'], 'SYSTEM_EVENT');
      expect(ev['event_subtype'], 'PLATFORM_STATUS');
      final src = e['source'] as Map;
      expect(src['node_role'], 'EDGE');
      expect(src['producer'], 'rf-sensor-shepherd');
      final payload = e['payload'] as Map;
      expect(payload['system_type'], 'PLATFORM_STATUS');
      expect(payload['state'], 'NOMINAL');
    });

    test('metrics carry platform position honestly', () {
      final e = hb();
      final metrics = (e['payload'] as Map)['metrics'] as Map;
      expect(metrics['shepherd_node_count'], 4);
      expect(metrics['shepherd_detection_count'], 17);
      expect(metrics['shepherd_heartbeat_interval_s'], 60);
      final pos = metrics['position'] as Map;
      expect(pos['lat'], 35.1391);
      expect(pos['dimensionality'], '2D');
      expect(pos.containsKey('alt_m'), isFalse);
      expect((metrics['position_note'] as String).contains('not a target'),
          isTrue);
    });

    test('heartbeat without position is state-only', () {
      final e = zmetaPlatformStatus(
        platformId: 'shepherd-mesh-1',
        ts: _t0,
        state: 'NOMINAL',
        nodeCount: 2,
        detectionCount: 0,
        heartbeatIntervalSec: 60,
      );
      final metrics = (e['payload'] as Map)['metrics'] as Map;
      expect(metrics.containsKey('position'), isFalse);
    });
  });

  group('sensor observations', () {
    test('bearing/spectrum stay local — no honest ACOUSTIC fit (level required)', () {
      final bearing = SensorObservation(
        type: SensorObsType.bearing,
        sensorId: 'micarray-1',
        timestamp: _t0,
        bearingDeg: 137.0,
        confidence: 0.8,
      );
      expect(
          zmetaSensorObservation(
              platformId: 'shepherd-mesh-1', obs: bearing),
          isNull);
      final spectrum = SensorObservation(
        type: SensorObsType.spectrum,
        sensorId: 'mic-1',
        timestamp: _t0,
        freqHz: const [120.0, 240.0],
        magnitudes: const [0.2, 0.9],
      );
      expect(
          zmetaSensorObservation(
              platformId: 'shepherd-mesh-1', obs: spectrum),
          isNull);
    });

    test('RANGE has no honest modality — stays local (null)', () {
      final obs = SensorObservation(
        type: SensorObsType.range,
        sensorId: 'lidar-1',
        timestamp: _t0,
        distanceM: 12.4,
      );
      expect(
          zmetaSensorObservation(
              platformId: 'shepherd-mesh-1', obs: obs),
          isNull);
    });

    test('camera motion wraps to OBSERVATION_EVENT/EO', () {
      final obs = SensorObservation(
        type: SensorObsType.motion,
        sensorId: 'cam-1',
        timestamp: _t0,
        zone: '3',
      );
      final e = zmetaSensorObservation(
          platformId: 'shepherd-mesh-1', obs: obs)!;
      expect((e['payload'] as Map)['modality'], 'EO');
      expect((e['event'] as Map)['event_subtype'], 'EO');
    });
  });
}
