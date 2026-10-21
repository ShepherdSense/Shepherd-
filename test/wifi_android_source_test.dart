import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepherd/services/wifi_sense.dart';

/// AndroidWifiSource over a mocked `shepherd/wifi_sense` channel —
/// the same contract MainActivity.kt implements.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shepherd/wifi_sense');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  group('pollFast', () {
    test('parses the connected AP', () async {
      mock((call) async {
        expect(call.method, 'connected');
        return {'ssid': 'HOME-NET', 'bssid': 'AA:BB:CC:DD:EE:01', 'rssi': -57};
      });
      final out = await AndroidWifiSource(channel: channel).pollFast();
      expect(out, hasLength(1));
      expect(out.single.ssid, 'HOME-NET');
      expect(out.single.bssid, 'aa:bb:cc:dd:ee:01');
      expect(out.single.rssiDbm, -57.0);
      expect(out.single.isConnected, isTrue);
      // The connected map carries no capabilities: security is
      // UNKNOWN (''), never mislabeled Open.
      expect(out.single.auth, '');
      expect(out.single.cipher, '');
    });

    test('redacted <unknown ssid> becomes (unknown)', () {
      final r = AndroidWifiSource.readingFromMap(
          {'ssid': '<unknown ssid>', 'bssid': 'aa:bb:cc:dd:ee:01', 'rssi': -60},
          connected: true)!;
      expect(r.ssid, '(unknown)');
    });

    test('not associated -> empty', () async {
      mock((call) async => null);
      final out = await AndroidWifiSource(channel: channel).pollFast();
      expect(out, isEmpty);
    });
  });

  group('pollSurvey', () {
    test('parses APs, flags the connected one, labels hidden SSIDs',
        () async {
      mock((call) async {
        expect(call.method, 'survey');
        return [
          {
            'ssid': 'HOME-NET',
            'bssid': 'aa:bb:cc:dd:ee:01',
            'rssi': -57,
            'capabilities': '[WPA2-PSK-CCMP][ESS]',
            'connected': true,
          },
          {
            'ssid': '',
            'bssid': 'aa:bb:cc:dd:ee:02',
            'rssi': -80,
            'capabilities': '[WPA3-SAE-CCMP][ESS]',
            'connected': false,
          },
          {
            'ssid': 'Cafe',
            'bssid': 'aa:bb:cc:dd:ee:03',
            'rssi': -71,
            'capabilities': '[ESS]',
            'connected': false,
          },
        ];
      });
      final out = await AndroidWifiSource(channel: channel).pollSurvey();
      expect(out, hasLength(3));
      expect(out[0].isConnected, isTrue);
      expect(out[0].auth, 'WPA2-Personal');
      expect(out[0].cipher, 'CCMP');
      expect(out[1].ssid, '(hidden)');
      expect(out[1].auth, 'WPA3-Personal');
      expect(out[2].auth, 'Open');
      expect(out[2].cipher, '');
    });

    test('skips malformed entries instead of failing the batch',
        () async {
      mock((call) async => [
            {'ssid': 'NoRssi', 'bssid': 'aa:bb:cc:dd:ee:09'},
            {'ssid': 'NoBssid', 'rssi': -50},
            {
              'ssid': 'Good',
              'bssid': 'aa:bb:cc:dd:ee:0a',
              'rssi': -60,
              'capabilities': '[WEP][ESS]',
              'connected': false,
            },
          ]);
      final out = await AndroidWifiSource(channel: channel).pollSurvey();
      expect(out, hasLength(1));
      expect(out.single.ssid, 'Good');
      expect(out.single.auth, 'WEP');
      expect(out.single.cipher, 'WEP');
    });
  });

  group('permission handling', () {
    test('NO_PERMISSION throws an actionable StateError and prompts once',
        () async {
      var prompts = 0;
      mock((call) async {
        if (call.method == 'requestPermission') {
          prompts++;
          return true;
        }
        throw PlatformException(
            code: 'NO_PERMISSION', message: 'needs Location permission');
      });
      final src = AndroidWifiSource(channel: channel);
      await expectLater(src.pollFast(), throwsStateError);
      await expectLater(src.pollSurvey(), throwsStateError);
      expect(prompts, 1, reason: 'no re-prompt on every poll');
    });

    test('NO_FINE_LOCATION throws its own actionable StateError',
        () async {
      mock((call) async {
        if (call.method == 'requestPermission') return true;
        throw PlatformException(
            code: 'NO_FINE_LOCATION', message: 'connection info redacted');
      });
      final src = AndroidWifiSource(channel: channel);
      await expectLater(
          src.pollFast(),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('full Location'))));
    });

    test('other PlatformExceptions degrade to empty, never throw',
        () async {
      mock((call) async =>
          throw PlatformException(code: 'RADIO_OFF', message: 'boom'));
      final src = AndroidWifiSource(channel: channel);
      expect(await src.pollFast(), isEmpty);
      expect(await src.pollSurvey(), isEmpty);
    });

    test('missing plugin degrades to empty', () async {
      mock((call) async => throw MissingPluginException());
      final src = AndroidWifiSource(channel: channel);
      expect(await src.pollFast(), isEmpty);
      expect(await src.pollSurvey(), isEmpty);
    });
  });

  group('stale scan cache', () {
    test('a throttled re-read of the same cache is dropped', () async {
      List<Map<String, Object>> batch(int tsMs) => [
            {
              'ssid': 'HOME-NET',
              'bssid': 'aa:bb:cc:dd:ee:01',
              'rssi': -57,
              'capabilities': '[WPA2-PSK-CCMP][ESS]',
              'connected': false,
              'tsMs': tsMs,
            }
          ];
      var current = batch(5000);
      mock((call) async => current);
      final src = AndroidWifiSource(channel: channel);
      expect(await src.pollSurvey(), hasLength(1));
      // Scan throttled: identical cache again -> no new data.
      expect(await src.pollSurvey(), isEmpty);
      // A genuinely newer scan comes through.
      current = batch(9000);
      expect(await src.pollSurvey(), hasLength(1));
    });
  });

  group('service integration', () {
    test(
        'Android-shaped survey lands the connected AP exactly once and '
        'the threat detector learns its real auth label', () {
      SharedPreferences.setMockInitialValues({});
      final svc = WifiVisionService();
      WifiApReading fromMap(Map<String, dynamic> m) =>
          AndroidWifiSource.readingFromMap(m,
              connected: m['connected'] == true)!;
      void survey() => svc.ingest([
            fromMap({
              'ssid': 'HOME-NET',
              'bssid': 'AA:BB:CC:DD:EE:01',
              'rssi': -57,
              'capabilities': '[WPA2-PSK-CCMP][ESS]',
              'connected': true,
              'tsMs': 1000,
            }),
            fromMap({
              'ssid': 'Neighbor',
              'bssid': 'aa:bb:cc:dd:ee:02',
              'rssi': -80,
              'capabilities': '[ESS]',
              'connected': false,
              'tsMs': 1000,
            }),
          ], survey: true);
      survey();
      expect(svc.readings, hasLength(2));
      // Survey batches never feed the connected AP's 1 Hz history (the
      // fast poll owns it), so a survey alone leaves it empty.
      expect(svc.connectedHistory, isEmpty);
      // Auto-trust needs a dwell: one survey is not enough...
      expect(svc.threats.trustedAuth['HOME-NET'], isNull);
      survey();
      survey();
      // ...three surveys associated to the same BSSID learn the real label.
      expect(svc.threats.trustedAuth['HOME-NET'], 'wpa2-personal/ccmp');
    });
  });

  group('authCipherFromCapabilities', () {
    test('enterprise and transition modes stay consistent', () {
      expect(
          AndroidWifiSource.authCipherFromCapabilities(
              '[WPA2-EAP-CCMP][ESS]'),
          ('WPA2-Enterprise', 'CCMP'));
      // WPA2/WPA3 transition: one label, picked deterministically.
      expect(
          AndroidWifiSource.authCipherFromCapabilities(
              '[WPA2-PSK-CCMP][WPA3-SAE-CCMP][ESS]'),
          ('WPA3-Personal', 'CCMP'));
      expect(
          AndroidWifiSource.authCipherFromCapabilities('[WPA-PSK-TKIP][ESS]'),
          ('WPA-Personal', 'TKIP'));
      expect(AndroidWifiSource.authCipherFromCapabilities(''), ('Open', ''));
    });
  });

  group('review fixes', () {
    WifiApReading ap(String bssid, double rssi,
            {bool connected = false, String ssid = 'HOME-NET'}) =>
        WifiApReading(
            ssid: ssid,
            bssid: bssid,
            rssiDbm: rssi,
            isConnected: connected,
            auth: 'WPA2-Personal',
            cipher: 'CCMP');

    test('empty survey batches never count as disconnects', () {
      SharedPreferences.setMockInitialValues({});
      final svc = WifiVisionService();
      svc.ingest([ap('aa:00:00:00:00:01', -50, connected: true)]);
      for (var i = 0; i < 10; i++) {
        svc.ingest(const [], survey: true); // throttled survey
        svc.ingest([ap('aa:00:00:00:00:01', -50, connected: true)]);
      }
      expect(svc.threats.bursts, isEmpty);
    });

    test('changing sensitivity closes open crossings', () {
      SharedPreferences.setMockInitialValues({});
      final svc = WifiVisionService();
      for (var i = 0; i < 12; i++) {
        svc.ingest([ap('aa:00:00:00:00:01', -50, connected: true)]);
      }
      for (var i = 0; i < 3; i++) {
        svc.ingest([ap('aa:00:00:00:00:01', -75, connected: true)]);
      }
      expect(svc.wifiDetected, isTrue);
      svc.dipThresholdDb = 9.0;
      expect(svc.wifiDetected, isFalse);
      expect(svc.disturbedBssids, isEmpty);
    });

    test('fast poll keeps the auth label a survey learned', () {
      SharedPreferences.setMockInitialValues({});
      final svc = WifiVisionService();
      svc.ingest([ap('aa:00:00:00:00:01', -50, connected: true)],
          survey: true);
      svc.ingest([
        WifiApReading(
            ssid: '(unknown)',
            bssid: 'aa:00:00:00:00:01',
            rssiDbm: -51,
            isConnected: true)
      ]);
      final r = svc.readings.single;
      expect(r.auth, 'WPA2-Personal');
      expect(r.ssid, 'HOME-NET');
    });
  });
}
