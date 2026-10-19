/// Tests for TAK eager auto-connect (docs/device_autoconnect_spec.md).
///
/// connectNow() is the configure-time eager connect: it must be a safe
/// no-op unless emit is enabled AND the transport is TAK TCP AND a
/// host is set. A failed connect must never throw out of configure —
/// the backoff path owns the retry, and the dashboard reads RETRYING.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/cot_publisher.dart';

void main() {
  group('CotPublisher.connectNow guards', () {
    test('disabled config -> no-op, never connected', () async {
      final p = CotPublisher(
        config: const CotPublisherConfig(enabled: false),
      );
      await p.connectNow();
      expect(p.takConnected, isFalse);
      p.dispose();
    });

    test('multicast mode -> no-op (connectionless by design)', () async {
      final p = CotPublisher(
        config: const CotPublisherConfig(
          enabled: true,
          useMulticast: true,
        ),
      );
      await p.connectNow();
      expect(p.takConnected, isFalse);
      p.dispose();
    });

    test('TAK mode, empty host -> no-op', () async {
      final p = CotPublisher(
        config: const CotPublisherConfig(
          enabled: true,
          useMulticast: false,
          takHost: '',
        ),
      );
      await p.connectNow();
      expect(p.takConnected, isFalse);
      p.dispose();
    });

    test('injected test sender -> no real socket attempted', () async {
      var sent = 0;
      final p = CotPublisher(
        config: const CotPublisherConfig(
          enabled: true,
          useMulticast: false,
          takHost: '127.0.0.1',
        ),
        sender: (_) async => sent++,
      );
      await p.connectNow();
      expect(p.takConnected, isFalse);
      expect(sent, 0);
      p.dispose();
    });

    test('fresh publisher reports not connected', () {
      final p = CotPublisher(config: const CotPublisherConfig());
      expect(p.takConnected, isFalse);
      p.dispose();
    });
  });

  group('CotPublisher.connectNow positive path', () {
    test('TAK mode, reachable server -> connects eagerly', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = CotPublisher(
        config: CotPublisherConfig(
          enabled: true,
          useMulticast: false,
          takHost: '127.0.0.1',
          takPort: server.port,
        ),
      );
      await p.connectNow();
      expect(p.takConnected, isTrue);
      p.dispose();
      await server.close();
    });

    test('TAK mode, refused -> false, no throw', () async {
      // Bind-then-close for a definitely-closed port.
      final tmp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = tmp.port;
      await tmp.close();
      final p = CotPublisher(
        config: CotPublisherConfig(
          enabled: true,
          useMulticast: false,
          takHost: '127.0.0.1',
          takPort: port,
        ),
      );
      await p.connectNow(); // must not throw
      expect(p.takConnected, isFalse);
      p.dispose();
    });
  });
}
