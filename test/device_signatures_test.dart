/// Tests for the Wi-Fi/BLE signature library (Shepherd v0.26.0,
/// Fieldwatch-borrow item 2, lib/services/device_signatures.dart).
///
/// Honesty notes for these tests:
///  - No built-in vendor OUI/company entry is asserted, because the
///    service deliberately ships none (a manufacturer id is not a
///    device class). OUI and company-ID matching are proven through
///    USER-ADDED entries, where the user asserts the mapping.
///  - BSSIDs in OUI tests use globally-administered first octets
///    (e.g. 0x00): a locally-administered (randomized) MAC carries
///    no manufacturer OUI and must not match — proven separately.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/device_signatures.dart';

void main() {
  const catalog = DeviceSignatureCatalog();

  group('built-in BLE matching', () {
    test('match on BLE Remote ID service UUID (short form)', () {
      final matches = catalog.matchBle(serviceUuids: const ['fffa']);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.deviceClass, DeviceClass.drone);
      expect(m.isConfident, isTrue);
      expect(m.sourceLabel, 'PUBLIC ASSIGNMENT');
      expect(m.hypothesisLabel, contains('HYPOTHESIS'));
      expect(m.hypothesisLabel, contains('not identity'));
      expect(m.evidence.single, contains('fffa'));
    });

    test('match on BLE Remote ID service UUID (expanded 128-bit form)', () {
      final matches = catalog.matchBle(serviceUuids: const [
        '0000fffa-0000-1000-8000-00805f9b34fb',
      ]);
      expect(matches, hasLength(1));
      expect(matches.single.deviceClass, DeviceClass.drone);
    });

    test('unrelated BLE service UUID matches nothing', () {
      expect(catalog.matchBle(serviceUuids: const ['180d']), isEmpty);
      expect(
          catalog.confidentMatches(
              const DeviceObservation(bleServiceUuids: ['180d'])),
          isEmpty);
    });
  });

  group('built-in Wi-Fi SSID matching', () {
    test('match on SSID pattern, weak by design (not confident)', () {
      final matches = catalog.matchWifi(ssid: 'MyDrone-42');
      expect(matches, hasLength(1));
      expect(matches.single.deviceClass, DeviceClass.drone);
      // Keyword-only evidence stays below the confident threshold.
      expect(matches.single.isConfident, isFalse);
      expect(
          catalog.confidentMatches(const DeviceObservation(ssid: 'MyDrone-42')),
          isEmpty);
      expect(matches.single.hypothesisLabel, contains('HYPOTHESIS'));
      expect(matches.single.sourceLabel, 'UNVERIFIED/COMMUNITY');
    });

    test('ranking: bodycam outranks generic camera on a bodycam SSID', () {
      final matches = catalog.matchWifi(ssid: 'officer-bodycam-1');
      expect(matches, isNotEmpty);
      expect(matches.first.deviceClass, DeviceClass.bodyCam);
    });

    test('unknown device returns no match at all', () {
      final matches =
          catalog.matchWifi(bssid: '00:11:22:33:44:55', ssid: 'coffee-shop');
      expect(matches, isEmpty);
      expect(
          catalog.confidentMatches(const DeviceObservation(
              wifiBssid: '00:11:22:33:44:55', ssid: 'coffee-shop')),
          isEmpty);
    });
  });

  group('user-added signatures', () {
    const userJson = '''
{"signatures": [
  {"id": "user-oui-drone", "class": "drone",
   "label": "User drone hotspot", "wifiOui": "00:1A:2B",
   "confidence": 0.7},
  {"id": "user-company", "class": "tracker",
   "label": "User tracker beacon", "bleCompanyId": 4660,
   "confidence": 0.65}
]}
''';

    test('match on Wi-Fi OUI from user JSON, labeled USER-ADDED', () {
      final c = DeviceSignatureCatalog.fromUserJsonText(userJson);
      expect(c.hasUserLoadWarnings, isFalse);
      final matches = c.matchWifi(bssid: '00:1a:2b:aa:bb:cc');
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.deviceClass, DeviceClass.drone);
      expect(m.isConfident, isTrue);
      expect(m.isUserAdded, isTrue);
      expect(m.sourceLabel, 'USER-ADDED');
      expect(m.hypothesisLabel, contains('USER-ADDED'));
      expect(m.evidence.single, contains('001A2B'));
    });

    test('match on BLE company ID from user JSON', () {
      final c = DeviceSignatureCatalog.fromUserJsonText(userJson);
      final matches = c.matchBle(companyId: 4660);
      expect(matches, hasLength(1));
      expect(matches.single.deviceClass, DeviceClass.tracker);
      expect(matches.single.isUserAdded, isTrue);
    });

    test('user JSON overrides a built-in entry by id', () {
      const overrideJson = '''
{"signatures": [
  {"id": "rid-ble-fffa", "class": "camera",
   "label": "My reclassified beacon", "bleServiceUuid": "fffa",
   "confidence": 0.9}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(overrideJson);
      // Replacement, not duplication.
      expect(c.merged.length, kBuiltInDeviceSignatures.length);
      final matches = c.matchBle(serviceUuids: const ['fffa']);
      expect(matches, hasLength(1));
      expect(matches.single.deviceClass, DeviceClass.camera);
      expect(matches.single.confidence, 0.9);
      expect(matches.single.isUserAdded, isTrue);
    });

    test('randomized (locally-administered) MAC never matches an OUI', () {
      // The entry OUI itself is locally administered here so the
      // stripped prefix matches exactly — only the randomized-MAC
      // guard can suppress the match.
      const json = '''
{"signatures": [
  {"id": "local-oui", "class": "drone", "label": "Local OUI",
   "wifiOui": "02:1A:2B", "confidence": 0.9}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(json);
      expect(c.matchWifi(bssid: '02:1a:2b:aa:bb:cc'), isEmpty);
    });
  });

  group('malformed user JSON degrades, never crashes', () {
    test('garbage JSON degrades to built-in only with a surfaced reason', () {
      final c = DeviceSignatureCatalog.fromUserJsonText('not json {{{');
      expect(c.userSignatures, isEmpty);
      expect(c.hasUserLoadWarnings, isTrue);
      expect(c.userLoadWarnings.single, contains('malformed JSON'));
      expect(c.merged, kBuiltInDeviceSignatures);
      // Built-in matching still works.
      expect(c.matchBle(serviceUuids: const ['fffa']), hasLength(1));
    });

    test('wrong JSON shape degrades to built-in only', () {
      final c = DeviceSignatureCatalog.fromUserJsonText('42');
      expect(c.userSignatures, isEmpty);
      expect(c.hasUserLoadWarnings, isTrue);
      expect(c.merged, kBuiltInDeviceSignatures);
    });

    test('one bad entry is skipped, valid entries survive', () {
      const json = '''
{"signatures": [
  {"id": "bad-one", "class": "not-a-class",
   "wifiOui": "00:1A:2B"},
  {"id": "good-one", "class": "drone", "label": "Good",
   "wifiOui": "00:1A:2B", "confidence": 0.7}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(json);
      expect(c.hasUserLoadWarnings, isTrue);
      expect(c.userSignatures.map((s) => s.id), ['good-one']);
      expect(c.matchWifi(bssid: '00:1a:2b:aa:bb:cc'), hasLength(1));
    });

    test('invalid SSID pattern drops the field, never throws', () {
      const json = '''
{"signatures": [
  {"id": "bad-pattern", "class": "drone", "label": "Bad pattern",
   "ssidPattern": "[unclosed", "wifiOui": "00:1A:2B",
   "confidence": 0.7}
]}
''';
      final c = DeviceSignatureCatalog.fromUserJsonText(json);
      expect(c.hasUserLoadWarnings, isTrue);
      // Entry survives on its OUI matcher; the bad pattern is gone.
      final sig = c.userSignatures.single;
      expect(sig.ssidPattern, isNull);
      expect(sig.wifiOui, isNotNull);
      expect(c.matchWifi(bssid: '00:1a:2b:aa:bb:cc'), hasLength(1));
    });

    test('absent user file is built-in only, not an error', () {
      expect(DeviceSignatureCatalog.fromUserJsonText(null).hasUserLoadWarnings,
          isFalse);
      expect(DeviceSignatureCatalog.fromUserJsonText('  ').hasUserLoadWarnings,
          isFalse);
    });
  });
}
