/// Tests for the universal sensor ingestion layer:
/// wire protocol, observation model, drivers, camera paths.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/sensor_observation.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/camera_driver.dart';
import 'package:shepherd/services/generic_sensor_driver.dart';
import 'package:shepherd/services/node_udp_hub.dart';
import 'package:shepherd/services/sensor_protocol.dart';

TrackEstimate _track({double x = 50, double y = 0}) => TrackEstimate(
      timestamp: DateTime.now(),
      x: x,
      y: y,
      sizeClass: 'M',
      typeGuess: 'test',
      typeConfidence: 0.3,
      linksUsed: 2,
      relation: 'UNKNOWN',
    );

void main() {
  group('UART parser', () {
    test('RANGE with and without angle', () {
      final a = SensorProtocol.parseLine('RANGE lidar1 12.4 45');
      expect(a.observation?.type, SensorObsType.range);
      expect(a.observation?.distanceM, 12.4);
      expect(a.observation?.angleDeg, 45);
      final b = SensorProtocol.parseLine('RANGE tof1 3.2');
      expect(b.observation?.angleDeg, isNull);
    });

    test('BEARING with default and explicit confidence', () {
      final a = SensorProtocol.parseLine('BEARING micarray 137 0.8');
      expect(a.observation?.bearingDeg, 137);
      expect(a.observation?.confidence, 0.8);
      final b = SensorProtocol.parseLine('BEARING mic2 400');
      expect(b.observation?.bearingDeg, 40); // wrapped
      expect(b.observation?.confidence, 0.5);
    });

    test('SPECTRUM bins', () {
      final r =
          SensorProtocol.parseLine('SPECTRUM mic1 120:0.2,240:0.9,480:0.15');
      expect(r.observation?.freqHz, [120.0, 240.0, 480.0]);
      expect(r.observation?.magnitudes, [0.2, 0.9, 0.15]);
      expect(r.observation?.spectralPeak?.hz, 240.0);
    });

    test('BINARY forms', () {
      expect(SensorProtocol.parseLine('BINARY pir1 1').observation?.triggered,
          isTrue);
      expect(SensorProtocol.parseLine('BINARY pir1 0').observation?.triggered,
          isFalse);
      expect(
          SensorProtocol.parseLine('BINARY pir1 true').observation?.triggered,
          isTrue);
    });

    test('ENERGY and legacy SENSOR form', () {
      final a = SensorProtocol.parseLine('ENERGY rf1 -67');
      expect(a.observation?.type, SensorObsType.energy);
      expect(a.observation?.levelDb, -67);
      final b = SensorProtocol.parseLine('SENSOR node1 -71.5');
      expect(b.observation?.type, SensorObsType.energy);
      expect(b.observation?.sensorId, 'node1');
      expect(b.observation?.levelDb, -71.5);
    });

    test('MOTION with zone and label', () {
      final r =
          SensorProtocol.parseLine('MOTION cam1 zone=3 label=Driveway');
      expect(r.observation?.type, SensorObsType.motion);
      expect(r.observation?.zone, '3');
      expect(r.observation?.zoneLabel, 'Driveway');
      final bare = SensorProtocol.parseLine('MOTION cam1');
      expect(bare.observation?.zone, isNull);
    });

    test('malformed lines never throw, always null observation', () {
      const bad = [
        '',
        '   ',
        '# comment',
        'RANGE',
        'RANGE lidar1',
        'RANGE lidar1 abc',
        'RANGE lidar1 -5', // negative distance
        'RANGE lidar1 NaN',
        'RANGE lidar1 Infinity',
        'BEARING mic1',
        'BEARING mic1 xyz',
        'SPECTRUM mic1',
        'SPECTRUM mic1 120', // no colon
        'SPECTRUM mic1 0:0.5', // non-positive freq
        'BINARY pir1',
        'BINARY pir1 maybe',
        'ENERGY rf1',
        'FROBNICATE x 1 2',
        'SENSOR onlyname',
      ];
      for (final line in bad) {
        final r = SensorProtocol.parseLine(line);
        expect(r.observation, isNull, reason: 'line: "$line"');
      }
    });

    test('toLine round-trips through parseLine', () {
      final obs = [
        SensorObservation(
            type: SensorObsType.range,
            sensorId: 'l1',
            timestamp: DateTime(2026),
            distanceM: 12.4,
            angleDeg: 45),
        SensorObservation(
            type: SensorObsType.bearing,
            sensorId: 'm1',
            timestamp: DateTime(2026),
            bearingDeg: 137,
            confidence: 0.8),
        SensorObservation(
            type: SensorObsType.binary,
            sensorId: 'p1',
            timestamp: DateTime(2026),
            triggered: true),
        SensorObservation(
            type: SensorObsType.energy,
            sensorId: 'r1',
            timestamp: DateTime(2026),
            levelDb: -67),
        SensorObservation(
            type: SensorObsType.motion,
            sensorId: 'c1',
            timestamp: DateTime(2026),
            zone: '3'),
      ];
      for (final o in obs) {
        final back =
            SensorProtocol.parseLine(SensorProtocol.toLine(o)).observation;
        expect(back?.type, o.type);
        expect(back?.sensorId, o.sensorId);
      }
      // SPECTRUM round-trip separately (const lists need care).
      final s = SensorObservation(
        type: SensorObsType.spectrum,
        sensorId: 's1',
        timestamp: DateTime(2026),
        freqHz: const [120.0, 240.0],
        magnitudes: const [0.2, 0.9],
      );
      final sb = SensorProtocol.parseLine(SensorProtocol.toLine(s)).observation;
      expect(sb?.freqHz, [120.0, 240.0]);
    });
  });

  group('UDP JSON', () {
    test('toUdpJson round-trips through parseUdpJson', () {
      final o = SensorObservation(
        type: SensorObsType.range,
        sensorId: 'lidar1',
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
        sensorLat: 35.1,
        sensorLon: -78.9,
        distanceM: 12.4,
        angleDeg: 45,
      );
      final back = SensorProtocol.parseUdpJson(
          SensorProtocol.toUdpJson(o));
      expect(back.observation?.type, SensorObsType.range);
      expect(back.observation?.distanceM, 12.4);
      expect(back.observation?.sensorLat, 35.1);
      // Timestamp preserved (unix seconds).
      expect(
          back.observation!.timestamp.millisecondsSinceEpoch ~/ 1000,
          o.timestamp.millisecondsSinceEpoch ~/ 1000);
    });

    test('wrong type / garbage → null, never throws', () {
      expect(
          SensorProtocol.parseUdpJson(
              {'type': 'beacon', 'node': 'x'}).observation,
          isNull);
      expect(
          SensorProtocol.parseUdpJson(
              {'type': 'sensor_obs', 'obs': 'RANGE'}).observation,
          isNull); // missing sensor
      expect(
          SensorProtocol.parseUdpJson(
              {'type': 'sensor_obs', 'obs': 'NOPE', 'sensor': 's'})
              .observation,
          isNull);
      expect(
          SensorProtocol.parseUdpJson(
              {'type': 'sensor_obs', 'obs': 'RANGE', 'sensor': 's'}).observation,
          isNull); // missing dist_m
      // Zero lat/lon rejected (never plot at null island).
      final z = SensorProtocol.parseUdpJson({
        'type': 'sensor_obs',
        'obs': 'BINARY',
        'sensor': 'p',
        'triggered': true,
        'lat': 0,
        'lon': 0,
      });
      expect(z.observation?.sensorLat, isNull);
    });
  });

  group('ZMeta payload mapping', () {
    test('modalities map honestly; others stay local', () {
      // BEARING/SPECTRUM have no honest ZMeta modality: the 1.1.0
      // ACOUSTIC arm requires center_freq_hz plus a level (spl_db, or
      // pressure_pa + pressure_statistic). A bearing is a direction with
      // no level; spectrum bins are uncalibrated magnitudes. Both stay
      // local — fabricating a level would be exactly the lie the schema
      // guards against.
      final bearing = SensorObservation(
          type: SensorObsType.bearing,
          sensorId: 'a',
          timestamp: DateTime.now(),
          bearingDeg: 137,
          confidence: 0.8);
      expect(bearing.toZMetaPayload(), isNull);

      final spec = SensorObservation(
          type: SensorObsType.spectrum,
          sensorId: 'a',
          timestamp: DateTime.now(),
          freqHz: const [240.0],
          magnitudes: const [0.9]);
      expect(spec.toZMetaPayload(), isNull);

      final mot = SensorObservation(
          type: SensorObsType.motion,
          sensorId: 'c',
          timestamp: DateTime.now(),
          zone: '3');
      expect(mot.toZMetaPayload()!['modality'], 'EO');

      for (final t in [
        SensorObsType.range,
        SensorObsType.binary,
        SensorObsType.energy
      ]) {
        final o = SensorObservation(
            type: t, sensorId: 's', timestamp: DateTime.now());
        expect(o.toZMetaPayload(), isNull,
            reason: '$t must stay local (no honest modality)');
      }
    });

    test('banned ZMeta feature keys never appear', () {
      const banned = [
        'track_id',
        'entity_class',
        'classification',
        'class_name',
        'label',
        'confidence'
      ];
      for (final o in [
        SensorObservation(
            type: SensorObsType.bearing,
            sensorId: 'a',
            timestamp: DateTime.now(),
            bearingDeg: 10,
            confidence: 0.9),
        SensorObservation(
            type: SensorObsType.motion,
            sensorId: 'c',
            timestamp: DateTime.now(),
            zone: '1',
            zoneLabel: 'Gate'),
        SensorObservation(
            type: SensorObsType.spectrum,
            sensorId: 'a',
            timestamp: DateTime.now(),
            freqHz: const [100.0],
            magnitudes: const [0.5]),
      ]) {
        final p = o.toZMetaPayload();
        if (p == null) return; // stays local — nothing to export, nothing banned
        final f = p['features'] as Map;
        for (final k in banned) {
          expect(f.containsKey(k), isFalse, reason: 'banned key $k');
        }
      }
    });
  });

  group('upgrade-only invariant', () {
    test('Corroboration rejects negative boost', () {
      expect(() => Corroboration(boost: -0.1),
          throwsA(isA<AssertionError>()));
    });

    test('no observation type can produce a negative boost', () {
      final track = _track();
      final obs = [
        SensorObservation(
            type: SensorObsType.range,
            sensorId: 'l',
            timestamp: DateTime(2026),
            distanceM: 50),
        SensorObservation(
            type: SensorObsType.bearing,
            sensorId: 'm',
            timestamp: DateTime(2026),
            bearingDeg: 90,
            confidence: 0.9),
        SensorObservation(
            type: SensorObsType.spectrum,
            sensorId: 'm',
            timestamp: DateTime(2026),
            freqHz: const [240.0],
            magnitudes: const [0.9]),
        SensorObservation(
            type: SensorObsType.binary,
            sensorId: 'p',
            timestamp: DateTime(2026),
            triggered: true),
        SensorObservation(
            type: SensorObsType.binary,
            sensorId: 'p',
            timestamp: DateTime(2026),
            triggered: false),
        SensorObservation(
            type: SensorObsType.energy,
            sensorId: 'r',
            timestamp: DateTime(2026),
            levelDb: -40), // hot reading: still no boost, no veto
        SensorObservation(
            type: SensorObsType.motion,
            sensorId: 'c',
            timestamp: DateTime(2026),
            zone: '3'),
        // Degenerate inputs: all must yield "no opinion", never crash.
        SensorObservation(
            type: SensorObsType.range,
            sensorId: 'l',
            timestamp: DateTime(2026)),
        SensorObservation(
            type: SensorObsType.bearing,
            sensorId: 'm',
            timestamp: DateTime(2026)),
      ];
      for (final o in obs) {
        final c = o.corroborationFor(track, sensorX: 0, sensorY: 0);
        expect(c.boost, greaterThanOrEqualTo(0),
            reason: '${o.type} must be upgrade-only');
      }
    });

    test('RANGE corroborates on geometry, silent otherwise', () {
      final o = SensorObservation(
          type: SensorObsType.range,
          sensorId: 'l',
          timestamp: DateTime(2026),
          distanceM: 50);
      final hit = o.corroborationFor(_track(x: 50, y: 0),
          sensorX: 0, sensorY: 0);
      expect(hit.boost, greaterThan(0));
      final miss = o.corroborationFor(_track(x: 500, y: 0),
          sensorX: 0, sensorY: 0);
      expect(miss.boost, 0);
    });

    test('BEARING corroborates on alignment', () {
      final o = SensorObservation(
          type: SensorObsType.bearing,
          sensorId: 'm',
          timestamp: DateTime(2026),
          bearingDeg: 90, // east
          confidence: 1.0);
      final hit = o.corroborationFor(_track(x: 50, y: 0),
          sensorX: 0, sensorY: 0);
      expect(hit.boost, greaterThan(0));
      final miss = o.corroborationFor(_track(x: -50, y: 0),
          sensorX: 0, sensorY: 0);
      expect(miss.boost, 0);
    });

    test('MOTION corroborates near the camera only', () {
      final o = SensorObservation(
          type: SensorObsType.motion,
          sensorId: 'c',
          timestamp: DateTime(2026),
          zone: '3');
      final near = o.corroborationFor(_track(x: 50, y: 0),
          sensorX: 0, sensorY: 0);
      expect(near.boost, greaterThan(0));
      final far = o.corroborationFor(_track(x: 5000, y: 0),
          sensorX: 0, sensorY: 0);
      expect(far.boost, 0);
    });
  });

  group('GenericSensorDriver', () {
    test('ingests datagrams, bounds store, exposes queries', () async {
      final d = GenericSensorDriver();
      for (var i = 0; i < 600; i++) {
        d.datagramForTest(
            '{"type":"sensor_obs","obs":"BINARY","sensor":"pir${i % 10}","triggered":true}');
      }
      // Store bounded at 500.
      expect(d.observationsSince(DateTime(2000)).length,
          lessThanOrEqualTo(500));
      expect(d.latestPerSensor().length, 10);
      expect(d.ingestedCount, 600);
      d.dispose();
    });

    test('distinct-sensor cap bounds ID-spam growth', () async {
      final d = GenericSensorDriver();
      for (var i = 0; i < 300; i++) {
        d.datagramForTest(
            '{"type":"sensor_obs","obs":"BINARY","sensor":"spam$i","triggered":true}');
      }
      expect(d.latestPerSensor().length,
          lessThanOrEqualTo(GenericSensorDriver.maxSensors));
      d.dispose();
    });

    test('malformed datagrams counted, never crash', () async {
      final d = GenericSensorDriver();
      d.datagramForTest('not json'); // not ours: ignored silently
      d.datagramForTest('{"type":"sensor_obs","obs":"RANGE"}'); // no sensor
      d.datagramForTest(
          '{"type":"sensor_obs","obs":"RANGE","sensor":"s"}'); // no dist_m
      d.datagramForTest('{"type":"beacon","node":"x"}'); // not ours: ignored
      expect(d.malformedCount, 2);
      expect(d.ingestedCount, 0);
      d.dispose();
    });

    test('ENERGY and BINARY emit virtual tripwire links', () async {
      final d = GenericSensorDriver();
      d.datagramForTest(
          '{"type":"sensor_obs","obs":"ENERGY","sensor":"rf1","level_db":-67}');
      d.datagramForTest(
          '{"type":"sensor_obs","obs":"BINARY","sensor":"pir1","triggered":true}');
      final links = await d.poll();
      final keys = {for (final l in links) '${l.fromNode}→${l.toNode}'};
      expect(keys.contains('sensor:rf1→sensor:rf1:energy'), isTrue);
      expect(keys.contains('sensor:pir1→sensor:pir1:binary'), isTrue);
      final bin =
          links.firstWhere((l) => l.toNode == 'sensor:pir1:binary');
      expect(bin.snr, -20.0); // trigger reads as a dip
      d.dispose();
    });
  });

  group('NodeUdpHub', () {
    test('refcounted listener registration', () async {
      void a(String _) {}
      void b(String _) {}
      await NodeUdpHub.ensureListening(a);
      await NodeUdpHub.ensureListening(b);
      expect(NodeUdpHub.listenerCountForTest, 2);
      NodeUdpHub.release(a);
      expect(NodeUdpHub.listenerCountForTest, 1);
      NodeUdpHub.release(b);
      expect(NodeUdpHub.listenerCountForTest, 0);
    });
  });

  group('CameraDriver', () {
    test('webhook payloads → MOTION observations', () {
      final d = CameraDriver();
      final ok = d.webhookToObsForTest(
          '{"camera":"front-porch","zone":"3","label":"Driveway"}', {});
      expect(ok?.type, SensorObsType.motion);
      expect(ok?.sensorId, 'cam:front-porch');
      expect(ok?.zone, '3');
      // Frigate shape.
      final frig = d.webhookToObsForTest(
          '{"after":{"camera":"drive","label":"person"}}', {});
      expect(frig?.sensorId, 'cam:drive');
      // Query-param form.
      final q = d.webhookToObsForTest(
          '', {'camera': 'gate', 'zone': '1'});
      expect(q?.zone, '1');
      // Garbage → null, no throw.
      expect(d.webhookToObsForTest('not json at all', {}), isNull);
      d.dispose();
    });

    test('ONVIF subscription address extraction', () {
      const xml = '''
<soap:Envelope><soap:Body>
<tev:CreatePullPointSubscriptionResponse>
<tev:SubscriptionReference>
<wsa:Address>http://192.168.1.64/onvif/pullpoint</wsa:Address>
</tev:SubscriptionReference>
</tev:CreatePullPointSubscriptionResponse>
</soap:Body></soap:Envelope>''';
      expect(OnvifMotionClient.extractSubscription(xml),
          'http://192.168.1.64/onvif/pullpoint');
      expect(OnvifMotionClient.extractSubscription('<nope/>'), isNull);
    });

    test('ONVIF motion hits: State=true only', () {
      const xml = '''
<wsnt:NotificationMessage>
<wsnt:Topic Dialect="x">tns1:RuleEngine/MotionDetector</wsnt:Topic>
<wsnt:Message><tt:Message><tt:Source>
<tt:SimpleItem Name="Source" Value="VideoSource_1"/>
</tt:Source><tt:Data>
<tt:SimpleItem Name="State" Value="true"/>
</tt:Data></tt:Message></wsnt:Message>
</wsnt:NotificationMessage>
<wsnt:NotificationMessage>
<wsnt:Topic Dialect="x">tns1:RuleEngine/MotionDetector</wsnt:Topic>
<wsnt:Message><tt:Message><tt:Data>
<tt:SimpleItem Name="State" Value="false"/>
</tt:Data></tt:Message></wsnt:Message>
</wsnt:NotificationMessage>
<wsnt:NotificationMessage>
<wsnt:Topic Dialect="x">tns1:Device/Trigger/DigitalInput</wsnt:Topic>
<wsnt:Message><tt:Message><tt:Data>
<tt:SimpleItem Name="State" Value="true"/>
</tt:Data></tt:Message></wsnt:Message>
</wsnt:NotificationMessage>''';
      final hits = OnvifMotionClient.extractMotionHits(xml);
      // Only the State=true motion topic counts (not motion-ended,
      // not the unrelated digital-input topic).
      expect(hits.length, 1);
      expect(hits.first, 'VideoSource_1');
    });

    test('CameraSettings round-trip + port clamp', () {
      final s = CameraSettings.fromJson({
        'enabled': true,
        'webhookPort': 99999,
        'onvifAddress': '192.168.1.64',
      });
      expect(s.enabled, isTrue);
      expect(s.webhookPort, 65535);
      final back = CameraSettings.fromJson(s.toJson());
      expect(back.onvifAddress, '192.168.1.64');
    });
  });
}
