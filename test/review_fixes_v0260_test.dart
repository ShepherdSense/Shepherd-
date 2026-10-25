/// Regression tests for the v0.26.0 reviewer fix-pass (fixes 1-17
/// in the fix-pass brief, service/widget level where the codebase
/// supports it). UI-text-only fixes (Hunt manual-position wording,
/// settings subtitle, dashboard banner rendering from the tier)
/// are verified by inspection + analyze, not by unit tests that
/// would duplicate string literals; the one exception is the
/// folded-RID badge, which is exercised at the marker-building
/// level via [airframeLayer].
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shepherd/screens/airframe_overlay.dart';
import 'package:shepherd/screens/wifi_vision.dart';
import 'package:shepherd/services/airframe_identity.dart';
import 'package:shepherd/services/device_signatures.dart';
import 'package:shepherd/services/hunt_tracker.dart';
import 'package:shepherd/services/offline_map_source.dart';
import 'package:shepherd/services/phone_tier.dart';
import 'package:shepherd/services/remote_id.dart';
import 'package:shepherd/services/remote_id_service.dart';
import 'package:shepherd/services/wifi_sense.dart';
import 'package:shepherd/state/app_state.dart';

import 'remote_id_test.dart' as vec;

final _t0 = DateTime(2026, 1, 1, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  group('fix 1: phone tier with a configured but non-polling mesh driver',
      () {
    test('tier inactive with a saved mesh driver configured, not polling',
        () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(meshDriverConfigured: true),
      );
      expect(tier.active, isFalse);
      expect(tier.modeLabel, isNot('PHONE-ONLY'));
    });

    test('tier active when nothing is configured or attached', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
      );
      expect(tier.active, isTrue);
    });
  });

  group('fix 2: signature library has a live consumer', () {
    testWidgets('Wi-Fi rows show a hypothesis label when the switch is on',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      state.wifiVisionEnabled = true;
      state.settings.deviceSignaturesEnabled = true;
      state.wifi.readings.add(WifiApReading(
        ssid: 'my-drone-net',
        bssid: '00:1a:2b:aa:bb:cc',
        rssiDbm: -60,
        isConnected: false,
      ));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WifiVisionScreen(state: state)),
        ),
      );
      await tester.pump();
      // The AP card sits below the viewport fold in the test
      // harness; scroll it into view before asserting.
      await tester.scrollUntilVisible(
          find.textContaining('my-drone'), 200);
      await tester.pump();
      expect(find.textContaining('HYPOTHESIS'), findsWidgets);
    });

    testWidgets('Wi-Fi rows show no hypothesis label when switch is off',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      state.wifiVisionEnabled = true;
      state.settings.deviceSignaturesEnabled = false;
      state.wifi.readings.add(WifiApReading(
        ssid: 'my-drone-net',
        bssid: '00:1a:2b:aa:bb:cc',
        rssiDbm: -60,
        isConnected: false,
      ));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WifiVisionScreen(state: state)),
        ),
      );
      await tester.pump();
      // Scroll the AP row into view so the negative assertion is
      // meaningful (the row is below the fold otherwise).
      await tester.scrollUntilVisible(
          find.textContaining('my-drone'), 200);
      await tester.pump();
      expect(find.textContaining('HYPOTHESIS'), findsNothing);
    });
  });

  group('fix 5: per-cell hunt decay', () {
    test('repeated decays match a single decay to the same time', () {
      final repeated = HuntHeatGrid(halfLife: const Duration(seconds: 60));
      repeated.addSample(
          HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _t0));
      repeated.decay(now: _at(30));
      repeated.decay(now: _at(60));
      repeated.decay(now: _at(120));
      final single = HuntHeatGrid(halfLife: const Duration(seconds: 60));
      single.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _t0));
      single.decay(now: _at(120));
      expect(repeated.loudest!.weight,
          closeTo(single.loudest!.weight, 1e-9));
      expect(repeated.loudest!.weight, closeTo(0.25, 1e-9));
    });

    test('stale cell fades while another cell keeps receiving samples',
        () {
      final grid = HuntHeatGrid(halfLife: const Duration(seconds: 60));
      grid.addSample(HuntSample(xEast: 0, yNorth: 0, rssiDbm: -40, at: _t0));
      grid.addSample(
          HuntSample(xEast: 10, yNorth: 0, rssiDbm: -40, at: _t0));
      // Cell B keeps sampling at 9 minutes; cell A goes silent.
      grid.addSample(
          HuntSample(xEast: 10, yNorth: 0, rssiDbm: -40, at: _at(540)));
      grid.decay(now: _at(600));
      // A: 10 half-lives -> ~0.001, pruned. B: fresh sample at 9 min
      // decayed only 1 minute -> ~0.5 plus its decayed old weight.
      final centers = grid.cellsSorted.map((c) => c.centerX).toList();
      expect(centers, isNot(contains(closeTo(1.0, 1e-9))));
      expect(grid.cellCount, 1);
      expect(grid.loudest!.centerX, closeTo(11.0, 1e-9));
      expect(grid.loudest!.weight, greaterThan(0.4));
    });
  });

  group('fix 6: cooperative badge on folded serial-bearing RID records',
      () {
    testWidgets('serial-bearing RID record renders COOPERATIVE (RID)',
        (tester) async {
      final classifier = AirframeClassifier();
      classifier.observeRid(RidEvidence(
        serial: '9999ZZZZZZZZZZZZZZZZ',
        time: _t0,
        lat: 35.3,
        lon: -78.7,
      ));
      final records = classifier.records;
      expect(records, hasLength(1));
      expect(records.single.hasRid, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: airframeLayer(
                records: records,
                ridContacts: const [],
                project: (lat, lon) => const Offset(100, 100),
              ),
            ),
          ),
        ),
      );
      expect(find.text('COOPERATIVE (RID)'), findsOneWidget);
    });

    testWidgets('telemetry-driven record gets no RID badge', (tester) async {
      // Registry merges the CoT platform and the RID broadcast into
      // ONE record (same serial via the VIPER-1 entry); without it
      // the RID evidence would form a second, RID-only record.
      final classifier = AirframeClassifier(
        registry: const FriendlyRegistry([
          FriendlyEntry(serial: '1581F5FHJ229R00N3K7P', callsign: 'VIPER-1'),
        ]),
      );
      classifier.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-1',
        callsign: 'VIPER-1',
        cotType: 'a-f-A',
        lat: 35.1,
        lon: -78.9,
        time: _t0,
      ));
      classifier.observeRid(RidEvidence(
        serial: '1581F5FHJ229R00N3K7P',
        time: _t0,
        lat: 35.2,
        lon: -78.8,
      ));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: airframeLayer(
                records: classifier.records,
                ridContacts: const [],
                project: (lat, lon) => const Offset(100, 100),
              ),
            ),
          ),
        ),
      );
      expect(find.text('COOPERATIVE (RID)'), findsNothing);
    });
  });

  group('fix 7: observeRid never overwrites telemetry-driven records', () {
    test('telemetry position, operator position, and class are untouched',
        () {
      final c = AirframeClassifier(
        registry: const FriendlyRegistry([
          FriendlyEntry(serial: '1581F5FHJ229R00N3K7P', callsign: 'VIPER-1'),
        ]),
      );
      c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-1',
        callsign: 'VIPER-1',
        cotType: 'a-f-A',
        lat: 35.1,
        lon: -78.9,
        time: _t0,
      ));
      // The record is already telemetry-driven, so this RID
      // evidence must not set (or move) any position on it.
      final r = c.observeRid(RidEvidence(
        serial: '1581F5FHJ229R00N3K7P',
        time: _t0.add(const Duration(minutes: 2)),
        lat: 35.9,
        lon: -79.9,
        altM: 500,
        operatorLat: 36.0,
        operatorLon: -80.0,
        operatorLocationType: 1,
        courseDeg: 90,
        speedMps: 20,
      ))!;
      expect(r.lat, 35.1);
      expect(r.lon, -78.9);
      expect(r.operatorLat, isNull);
      expect(r.operatorLon, isNull);
      expect(r.klass, AirframeClass.b);
    });

    test('RID-only record still receives operator position', () {
      final c = AirframeClassifier();
      final r = c.observeRid(RidEvidence(
        serial: '9999ZZZZZZZZZZZZZZZZ',
        time: _t0,
        lat: 35.3,
        lon: -78.7,
        operatorLat: 35.4,
        operatorLon: -78.6,
        operatorLocationType: 1,
      ))!;
      expect(r.operatorLat, 35.4);
      expect(r.operatorLon, -78.6);
      expect(r.operatorLocationType, 1);
    });
  });

  group('fix 8: phone-tier source availability', () {
    test('switched-off sources leave availableSources', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
        sourceAvailable: {
          PhoneScanSource.remoteId: false,
          PhoneScanSource.signatureLibrary: false,
        },
      );
      expect(tier.active, isTrue);
      expect(tier.availableSources,
          isNot(contains(PhoneScanSource.remoteId)));
      expect(tier.availableSources,
          isNot(contains(PhoneScanSource.signatureLibrary)));
      expect(tier.unavailableReason, contains('Remote ID'));
      expect(tier.unavailableReason, contains('Signature library'));
    });
  });

  group('fix 9: tile cache', () {
    test('tile requests carry an identifying User-Agent', () async {
      String? seenUa;
      final client = MockClient((request) async {
        seenUa = request.headers['User-Agent'];
        return http.Response.bytes(<int>[1, 2, 3], 200);
      });
      final temp = Directory.systemTemp.createTempSync('shepherd_ua_');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final cache = TileCache(client: client, cacheDir: temp);
      await cache.fetch(kOsmStandard, const TileCoord(5, 1, 1));
      expect(seenUa, isNotNull);
      expect(seenUa, contains('Shepherd'));
    });

    test('corrupt manifest reset deletes orphaned tile files', () async {
      final temp = Directory.systemTemp.createTempSync('shepherd_orph_');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final dir = Directory('${temp.path}/offline_tiles')
        ..createSync(recursive: true);
      File('${dir.path}/_manifest.json').writeAsStringSync('not json {{{');
      File('${dir.path}/osm_standard_5_1_1.bin')
          .writeAsBytesSync(<int>[1, 2, 3]);
      File('${dir.path}/osm_standard_5_1_2.bin')
          .writeAsBytesSync(<int>[4, 5, 6]);
      final cache = TileCache(
        client: MockClient((_) async => throw http.ClientException('off')),
        cacheDir: temp,
      );
      await cache.ensureInitialized();
      expect(cache.cachedTiles, 0);
      final remaining = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bin'))
          .toList();
      expect(remaining, isEmpty);
    });

    test('tileDestRect preserves aspect and centers', () {
      // 256x256 tile in a wide 400x200 placement: fitted height
      // 200, width 200, centered horizontally.
      final dest = tileDestRect(
        const Rect.fromLTWH(0, 0, 400, 200),
        const Size(256, 256),
      );
      expect(dest.width, closeTo(200.0, 1e-9));
      expect(dest.height, closeTo(200.0, 1e-9));
      expect(dest.left, closeTo(100.0, 1e-9));
      expect(dest.top, closeTo(0.0, 1e-9));
    });
  });

  group('fix 10: step-source disposal ownership', () {
    test('HuntTracker.dispose does not dispose the step source', () async {
      final source = _RecordingStepSource();
      final tracker = HuntTracker(stepSource: source);
      await tracker.dispose();
      expect(source.disposed, isFalse);
      // The caller still owns disposal, and it works after the
      // tracker is gone.
      await source.dispose();
      expect(source.disposed, isTrue);
    });
  });

  group('fix 12: signature honesty', () {
    test('user JSON confidence clamps to 0.99, never 1.0', () {
      const json = '''
{"signatures": [
  {"id": "conf-1", "class": "drone", "label": "Conf",
   "ssidPattern": "drone", "confidence": 1.0}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(json);
      expect(c.userSignatures.single.confidence, 0.99);
    });

    test('overriding rid-ble-fffa surfaces a warning', () {
      const json = '''
{"signatures": [
  {"id": "rid-ble-fffa", "class": "camera",
   "label": "My reclassified beacon", "bleServiceUuid": "fffa",
   "confidence": 0.9}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(json);
      expect(
        c.userLoadWarnings.any((w) => w.contains('rid-ble-fffa')),
        isTrue,
      );
      expect(c.merged.firstWhere((s) => s.id == 'rid-ble-fffa').deviceClass,
          DeviceClass.camera);
    });
  });

  group('fix 13: tile-math edges', () {
    test('latLonToTile clamps negative and huge zooms', () {
      final neg = latLonToTile(0, 0, -3);
      expect(neg.z, 0);
      expect(neg.isValid, isTrue);
      final huge = latLonToTile(0, 0, 100);
      expect(huge.z, 22);
      expect(huge.isValid, isTrue);
    });

    test('tilesForBounds handles antimeridian-crossing boxes', () {
      final tiles = tilesForBounds(10, -10, 170, -170, 2);
      expect(tiles, isNotEmpty);
      // Both sides of the antimeridian appear: x=3 (170..180) and
      // x=0 (-180..-170) at zoom 2.
      final xs = tiles.map((t) => t.x).toSet();
      expect(xs, contains(3));
      expect(xs, contains(0));
      expect(tiles.toSet().length, tiles.length); // no duplicates
      for (final t in tiles) {
        expect(t.isValid, isTrue);
      }
      // Inverted north/south is still empty.
      expect(tilesForBounds(-10, 10, -10, 10, 1), isEmpty);
    });
  });

  group('fix 16: onUpdate hardening', () {
    test('throwing BLE onUpdate hook does not break ingestion', () {
      final svc = RemoteIdService();
      svc.setEnabled(true, wifiCapable: false);
      svc.onUpdate = () => throw StateError('hook exploded');
      // Wall-clock timestamp: contacts prune on a 90 s horizon,
      // so a fixed 2026 timestamp would read back as stale.
      final now = DateTime.now();
      expect(
        () => svc.onBleAdvertisement(
          'AA:BB',
          {
            'fffa': Uint8List.fromList([0x03, ...vec.basicIdBytes]),
          },
          at: now,
        ),
        returnsNormally,
      );
      expect(svc.contacts, hasLength(1));
      svc.dispose();
    });

    test('throwing Wi-Fi onUpdate hook does not break the poll', () async {
      final svc = RemoteIdService(
          wifiSource: () async => [
                {
                  'bssid': 'aa:bb:cc:dd:ee:ff',
                  'ridBeacon': [0x05, ...vec.basicIdBytes],
                },
              ]);
      svc.setEnabled(true, wifiCapable: false);
      svc.onUpdate = () => throw StateError('hook exploded');
      expect(await svc.pollWifiOnce(at: DateTime.now()), 1);
      expect(svc.contacts, hasLength(1));
      svc.dispose();
    });
  });

  group('fix 17: malformed-frame leniencies', () {
    test('direction byte 180-255 with EW clear decodes to null', () {
      final b = List<int>.from(vec.locationBytes)
        ..[1] = 0x20 // status 2, EW clear, SpeedMult clear
        ..[2] = 200;
      expect((decodeRidMessage(b)! as RidLocation).directionDeg, isNull);
      final ok = List<int>.from(vec.locationBytes)
        ..[1] = 0x20
        ..[2] = 90;
      expect((decodeRidMessage(ok)! as RidLocation).directionDeg, 90.0);
      final ew = List<int>.from(vec.locationBytes)
        ..[1] = 0x22 // EW set
        ..[2] = 10;
      expect((decodeRidMessage(ew)! as RidLocation).directionDeg, 190.0);
    });

    test('decodeRidMessagePack rejects trailing garbage when called directly',
        () {
      final pack = <int>[0xF2, 25, 2, ...vec.basicIdBytes, ...vec.locationBytes];
      expect(decodeRidMessagePack(pack), hasLength(2));
      expect(decodeRidMessagePack([...pack, 0x00]), isEmpty);
      expect(decodeRidMessagePack([...pack, 1, 2, 3]), isEmpty);
    });
  });
}

class _RecordingStepSource implements StepSource {
  final _controller = StreamController<DateTime>.broadcast();
  bool disposed = false;

  @override
  Stream<DateTime> get steps => _controller.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}
