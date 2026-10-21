import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/wifi_rtt.dart';
import 'package:wifi_ftm/wifi_ftm.dart';

/// Regression tests for the field report of 2026-10-21: the RTT card
/// showed a raw PlatformException(NO_MATCHING_AP, ...). Root cause:
/// the wifi_ftm plugin resolves startRanging targets against the scan
/// cached by its own scanAccessPoints call (exact BSSID strings), and
/// the app never scanned — the cache was empty on every RANGE tap.
/// The fix scans first and intersects the requested registry BSSIDs
/// with the fresh scan via selectRttTargets; failures map through
/// rttErrorText instead of leaking the exception string.
APScanResult ap(
  String bssid, {
  int level = -60,
  bool mc = false,
  bool az = false,
}) =>
    APScanResult(
      ssid: 'NET',
      bssid: bssid,
      level: level,
      frequency: 5180,
      timestamp: 0,
      is80211mcResponder: mc,
      is80211azResponder: az,
      capabilities: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selectRttTargets', () {
    test('returns the scan verbatim BSSID for a case-differing request',
        () {
      // The app registry lowercases BSSIDs; the plugin keys its cache
      // by Android's exact string. The scan's string must win.
      final scan = [ap('AA:BB:CC:DD:EE:01')];
      expect(selectRttTargets(['aa:bb:cc:dd:ee:01'], scan),
          ['AA:BB:CC:DD:EE:01']);
    });

    test('drops requested BSSIDs absent from the fresh scan (stale)',
        () {
      final scan = [ap('aa:bb:cc:dd:ee:01')];
      expect(
        selectRttTargets(
            ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:99'], scan),
        ['aa:bb:cc:dd:ee:01'],
      );
    });

    test('no overlap yields no targets', () {
      final scan = [ap('aa:bb:cc:dd:ee:01')];
      expect(selectRttTargets(['11:22:33:44:55:66'], scan), isEmpty);
      expect(selectRttTargets(const [], scan), isEmpty);
    });

    test('dedupes repeated requests and scan entries', () {
      final scan = [ap('aa:bb:cc:dd:ee:01'), ap('AA:BB:CC:DD:EE:01')];
      expect(
        selectRttTargets(
            ['aa:bb:cc:dd:ee:01', 'AA:BB:CC:DD:EE:01'], scan),
        hasLength(1),
      );
    });

    test('responders first, then strongest signal, capped', () {
      final scan = [
        ap('aa:00:00:00:00:01', level: -40), // strong, no FTM
        ap('aa:00:00:00:00:02', level: -80, mc: true), // weak responder
        ap('aa:00:00:00:00:03', level: -50, az: true), // responder
        ap('aa:00:00:00:00:04', level: -30), // strongest, no FTM
      ];
      final all = [
        'aa:00:00:00:00:01',
        'aa:00:00:00:00:02',
        'aa:00:00:00:00:03',
        'aa:00:00:00:00:04',
      ];
      expect(
        selectRttTargets(all, scan),
        [
          'aa:00:00:00:00:03', // az responder, stronger of the two
          'aa:00:00:00:00:02', // mc responder
          'aa:00:00:00:00:04', // non-responders by signal strength
          'aa:00:00:00:00:01',
        ],
      );
      expect(selectRttTargets(all, scan, maxTargets: 2),
          ['aa:00:00:00:00:03', 'aa:00:00:00:00:02']);
    });
  });

  group('rttErrorText', () {
    test('NO_MATCHING_AP becomes operator copy, not the raw exception',
        () {
      final e = PlatformException(
        code: 'NO_MATCHING_AP',
        message:
            'None of the provided BSSIDs were found in the last scan',
      );
      final text = rttErrorText(e);
      expect(text, contains('latest Wi-Fi scan'));
      expect(text, isNot(contains('PlatformException')));
    });

    test('permission and unsupported codes map to plain language', () {
      expect(rttErrorText(PlatformException(code: 'PERMISSION_DENIED')),
          contains('permission'));
      expect(rttErrorText(PlatformException(code: 'UNSUPPORTED')),
          contains('not supported'));
    });

    test('unknown platform codes stay short and readable', () {
      final text =
          rttErrorText(PlatformException(code: 'RANGING_FAILURE'));
      expect(text, 'Ranging failed (RANGING_FAILURE).');
    });

    test('non-platform errors fall back to generic copy, never raw text',
        () {
      // A MissingPluginException's toString() is a long raw dump; the
      // UI contract is that no exception string reaches the operator.
      final mp = rttErrorText(MissingPluginException('no impl'));
      expect(mp, isNot(contains('MissingPluginException')));
      expect(mp, isNot(contains('no impl')));
      expect(rttErrorText(StateError('boom')),
          isNot(contains('boom')));
    });
  });

  group('WifiRttService scan-before-range (mock wifi_ftm channel)', () {
    // Emulates the plugin's native side faithfully: the scan call
    // populates a cache keyed by the scan's exact BSSID strings, and
    // startRanging throws NO_MATCHING_AP for any BSSID not in that
    // cache. If the scanAccessPoints call in rangeBssids is ever
    // removed, the first test fails with the field bug's error —
    // that is the regression lock for 2026-10-21.
    const channel = MethodChannel('wifi_ftm');
    final calls = <String>[];
    var scanReply = <Object?>[];
    Set<String> nativeCache = {};

    Map<String, Object?> scanAp(String bssid, {bool mc = false}) => {
          'ssid': 'NET',
          'bssid': bssid,
          'level': -55,
          'frequency': 5180,
          'timestamp': 0,
          'is80211mcResponder': mc,
          'is80211azResponder': false,
          'capabilities': '[ESS]',
        };

    setUp(() {
      calls.clear();
      scanReply = [];
      nativeCache = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'scanAccessPoints':
            nativeCache = {
              for (final m in scanReply)
                (m as Map)['bssid'] as String,
            };
            return scanReply;
          case 'startRanging':
            final bssids =
                (call.arguments as Map)['bssids'] as List<Object?>;
            for (final b in bssids) {
              if (!nativeCache.contains(b)) {
                throw PlatformException(
                  code: 'NO_MATCHING_AP',
                  message: 'None of the provided BSSIDs were found '
                      'in the last scan',
                );
              }
            }
            return [
              {
                'macAddress': bssids.first,
                'status': 0,
                'distanceMm': 2500,
                'distanceStdDevMm': 120,
                'rssi': -55,
                'numAttemptedMeasurements': 8,
                'numSuccessfulMeasurements': 8,
                'timestamp': 0,
                'is80211azResult': false,
              },
            ];
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('scans first, ranges the scan verbatim BSSID, stores reading',
        () async {
      scanReply = [scanAp('AA:BB:CC:DD:EE:01', mc: true)];
      final svc = WifiRttService()..supported = true;
      await svc.rangeBssids(['aa:bb:cc:dd:ee:01']);
      expect(calls, ['scanAccessPoints', 'startRanging']);
      expect(svc.error, isNull);
      expect(svc.readings['aa:bb:cc:dd:ee:01']?.meters, 2.5);
    });

    test('empty scan short-circuits with survey copy, never ranges',
        () async {
      scanReply = [];
      final svc = WifiRttService()..supported = true;
      await svc.rangeBssids(['aa:bb:cc:dd:ee:01']);
      expect(calls, ['scanAccessPoints']);
      expect(svc.error, contains('No Wi-Fi scan available yet'));
    });

    test('scan without any listed AP short-circuits, never ranges',
        () async {
      scanReply = [scanAp('AA:BB:CC:DD:EE:99')];
      final svc = WifiRttService()..supported = true;
      await svc.rangeBssids(['aa:bb:cc:dd:ee:01']);
      expect(calls, ['scanAccessPoints']);
      expect(svc.error, contains('None of the listed APs'));
    });
  });
}
