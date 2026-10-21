/// Tests for the Remote ID receive orchestration (Skydio P2,
/// lib/services/remote_id_service.dart): the BLE advertisement tap
/// filters to the FFFA service, and the Wi-Fi survey path ingests
/// `ridBeacon` rows. Both paths are passive; the service must also
/// stay silent while disabled.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/remote_id_service.dart';

import 'remote_id_test.dart' as vec;

void main() {
  // The service judges contact freshness on wall-clock time, so the
  // injected timestamps must be wall-clock too.
  final t0 = DateTime.now();

  group('RemoteIdService BLE tap', () {
    test('decodes FFFA service data into a contact', () {
      final svc = RemoteIdService();
      svc.setEnabled(true, wifiCapable: false);
      svc.onBleAdvertisement(
          'AA:BB',
          {
            '0000fffa-0000-1000-8000-00805f9b34fb':
                Uint8List.fromList([0x03, ...vec.basicIdBytes]),
            '00001800-0000-1000-8000-00805f9b34fb':
                Uint8List.fromList([1, 2, 3]),
          },
          at: t0);
      expect(svc.contacts, hasLength(1));
      expect(svc.contacts.single.serial, '1581F5FHJ229R00N3K7P');
      expect(svc.contacts.single.sourceKind, 'BLE');
      svc.dispose();
    });

    test('disabled service ignores advertisements entirely', () {
      final svc = RemoteIdService();
      svc.onBleAdvertisement(
          'AA:BB',
          {
            'fffa': Uint8List.fromList(vec.basicIdBytes),
          },
          at: t0);
      expect(svc.contacts, isEmpty);
      svc.dispose();
    });
  });

  group('RemoteIdService Wi-Fi survey path', () {
    test('ingests ridBeacon rows, ignores plain rows', () async {
      final svc = RemoteIdService(
          wifiSource: () async => [
                {
                  'bssid': 'aa:bb:cc:dd:ee:ff',
                  'ridBeacon': [0x05, ...vec.basicIdBytes],
                },
                {'bssid': '11:22:33:44:55:66', 'ssid': 'coffee-shop'},
              ]);
      svc.setEnabled(true, wifiCapable: false);
      // setEnabled with wifiCapable=false does not poll; call directly.
      final n = await svc.pollWifiOnce(at: t0);
      expect(n, 1);
      expect(svc.contacts.single.sourceKind, 'WIFI');
      expect(svc.contacts.single.serial, '1581F5FHJ229R00N3K7P');
      svc.dispose();
    });

    test('survey failure is a soft no-op', () async {
      final svc = RemoteIdService(wifiSource: () async => null);
      svc.setEnabled(true, wifiCapable: false);
      expect(await svc.pollWifiOnce(at: t0), 0);
      expect(svc.contacts, isEmpty);
      svc.dispose();
    });
  });
}
