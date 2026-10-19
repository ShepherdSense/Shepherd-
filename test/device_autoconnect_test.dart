/// Tests for the device auto-connect framework
/// (docs/device_autoconnect_spec.md).
///
/// Load-bearing invariants:
///  1. hasUsbLink: only the 172.17.97.x subnet counts — no other
///     interface may trigger a Silvus probe.
///  2. The watcher reports NOTHING unless the interface is present AND
///     the protocol handshake validates (no ghosts).
///  3. The coordinator dedupes by familyId+address (interface flaps
///     must not clone configs) and never calls onCandidate for known
///     devices.
///  4. A watcher that throws does not kill the other watchers' tick.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/device_autoconnect.dart';

void main() {
  group('SilvusUsbWatcher.hasUsbLink', () {
    test('detects the Silvus USB subnet', () {
      expect(
        SilvusUsbWatcher.hasUsbLink(['192.168.1.5', '172.17.97.44']),
        isTrue,
      );
    });

    test('rejects everything else', () {
      expect(SilvusUsbWatcher.hasUsbLink(['192.168.1.5', '10.0.0.2']),
          isFalse);
      expect(SilvusUsbWatcher.hasUsbLink([]), isFalse);
      // Near-miss prefixes must not match.
      expect(SilvusUsbWatcher.hasUsbLink(['172.17.970.1']), isFalse);
      expect(SilvusUsbWatcher.hasUsbLink(['172.17.9.7']), isFalse);
    });
  });

  group('SilvusUsbWatcher.poll (full path)', () {
    test('no interface -> no candidate, validation never attempted',
        () async {
      var validated = false;
      final w = SilvusUsbWatcher(
        listInterfaceAddresses: () async => ['192.168.1.5'],
        validate: (ip) async {
          validated = true;
          return true;
        },
      );
      expect(await w.poll(), isEmpty);
      expect(validated, isFalse);
    });

    test('interface present + handshake ok -> one validated candidate',
        () async {
      var validatedIp = '';
      final w = SilvusUsbWatcher(
        listInterfaceAddresses: () async => ['172.17.97.44'],
        validate: (ip) async {
          validatedIp = ip;
          return true;
        },
      );
      final found = await w.poll();
      expect(validatedIp, '172.17.97.182');
      expect(found.length, 1);
      expect(found.first.familyId, 'silvus');
      expect(found.first.address, '172.17.97.182');
    });

    test('interface present + handshake fails -> no candidate (no ghosts)',
        () async {
      var validated = false;
      final w = SilvusUsbWatcher(
        listInterfaceAddresses: () async => ['172.17.97.44'],
        validate: (ip) async {
          validated = true;
          return false;
        },
      );
      expect(await w.poll(), isEmpty);
      expect(validated, isTrue);
    });

    test('interface listing throws -> empty, no crash', () async {
      final w = SilvusUsbWatcher(
        listInterfaceAddresses: () => throw StateError('nope'),
        validate: (_) async => true,
      );
      expect(await w.poll(), isEmpty);
    });

    test('already-known address -> handshake skipped', () async {
      var validated = false;
      final w = SilvusUsbWatcher(
        listInterfaceAddresses: () async => ['172.17.97.44'],
        validate: (_) async {
          validated = true;
          return true;
        },
        knownAddresses: () => {'172.17.97.182'},
      );
      expect(await w.poll(), isEmpty);
      expect(validated, isFalse);
    });
  });

  group('DeviceAutoConnect coordinator', () {
    test('dedupes by familyId+address', () async {
      final added = <AutoConnectCandidate>[];
      final coord = DeviceAutoConnect(
        watchers: [
          _FakeWatcher('silvus', const [
            AutoConnectCandidate(
                familyId: 'silvus',
                address: '172.17.97.182',
                label: 'x'),
          ]),
        ],
        pollInterval: const Duration(milliseconds: 20),
        onCandidate: (c) async => added.add(c),
        // Already known -> must be skipped.
        isKnown: (f, a) => f == 'silvus' && a == '172.17.97.182',
      );
      coord.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      coord.stop();
      expect(added, isEmpty);
    });

    test('unknown validated candidate -> onCandidate, then deduped',
        () async {
      final added = <AutoConnectCandidate>[];
      var known = false;
      final coord = DeviceAutoConnect(
        watchers: [
          _FakeWatcher('silvus', const [
            AutoConnectCandidate(
                familyId: 'silvus',
                address: '172.17.97.182',
                label: 'x'),
          ]),
        ],
        pollInterval: const Duration(milliseconds: 20),
        onCandidate: (c) async {
          added.add(c);
          known = true; // simulate the config being added
        },
        isKnown: (f, a) => known,
      );
      coord.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      coord.stop();
      // Added once; later ticks see it as known (no flap clones).
      expect(added.length, 1);
    });

    test('a throwing watcher does not starve the others', () async {
      final added = <AutoConnectCandidate>[];
      final coord = DeviceAutoConnect(
        watchers: [
          _ThrowingWatcher('bad'),
          _FakeWatcher('silvus', const [
            AutoConnectCandidate(
                familyId: 'silvus', address: '1.2.3.4', label: 'x'),
          ]),
        ],
        pollInterval: const Duration(milliseconds: 20),
        onCandidate: (c) async => added.add(c),
        isKnown: (f, a) => false,
      );
      coord.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      coord.stop();
      expect(added.length, greaterThanOrEqualTo(1));
      expect(added.first.familyId, 'silvus');
    });
  });
}

class _FakeWatcher extends DeviceWatcher {
  _FakeWatcher(this._family, this._found);
  final String _family;
  final List<AutoConnectCandidate> _found;

  @override
  String get familyId => _family;

  @override
  Future<List<AutoConnectCandidate>> poll() async => _found;
}

class _ThrowingWatcher extends DeviceWatcher {
  _ThrowingWatcher(this._family);
  final String _family;

  @override
  String get familyId => _family;

  @override
  Future<List<AutoConnectCandidate>> poll() =>
      Future.error(StateError('boom'));
}
