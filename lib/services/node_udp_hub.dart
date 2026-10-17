/// Process-wide shared UDP 49160 listener.
///
/// Only one socket can bind port 49160, so every driver that listens
/// for node traffic shares it through here with refcounting. Each
/// listener receives every datagram as text and filters by its own
/// `type` field.
///
/// SEAM: at merge, migrate Esp32Driver._Esp32UdpHub to this hub — the
/// API is intentionally identical (ensureListening/release), so it is
/// a mechanical swap: replace `_Esp32UdpHub.ensureListening(_onDatagram)`
/// with `NodeUdpHub.ensureListening(_onDatagram)` (and the import),
/// then delete the private hub class. Until then, do NOT enable the
/// 'esp32' and 'sensor' drivers simultaneously: the second bind fails
/// silently and that driver hears nothing.
library;

import 'dart:io';

class NodeUdpHub {
  NodeUdpHub._();

  /// The Shepherd node broadcast port (beacons, events, sensor_obs).
  static const int port = 49160;

  static RawDatagramSocket? _sock;
  static final Set<void Function(String)> _listeners = {};
  static Future<void>? _starting;

  /// Register [onDatagram] (text of each received datagram). Safe to
  /// call repeatedly; safe to call from dispose-paired drivers.
  static Future<void> ensureListening(
      void Function(String) onDatagram) async {
    _listeners.add(onDatagram);
    if (_sock != null) return;
    _starting ??= _bind();
    await _starting;
  }

  static Future<void> _bind() async {
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _sock!.broadcastEnabled = true;
      _sock!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = _sock?.receive()) != null) {
          final text = String.fromCharCodes(dg!.data);
          for (final l in _listeners.toList()) {
            try {
              l(text);
            } catch (_) {}
          }
        }
      });
    } catch (_) {
      _sock = null;
    } finally {
      _starting = null;
    }
  }

  /// Unregister [onDatagram]; closes the socket when no listeners
  /// remain.
  static void release(void Function(String) onDatagram) {
    _listeners.remove(onDatagram);
    if (_listeners.isEmpty) {
      try {
        _sock?.close();
      } catch (_) {}
      _sock = null;
    }
  }

  /// Test hook: number of registered listeners.
  static int get listenerCountForTest => _listeners.length;
}
