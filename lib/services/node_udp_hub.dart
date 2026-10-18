/// Process-wide shared UDP 49160 listener.
///
/// Only one socket can bind port 49160, so every driver that listens
/// for node traffic shares it through here with refcounting. Each
/// listener receives every datagram as text and filters by its own
/// `type` field.
///
/// Esp32Driver and GenericSensorDriver both listen through this hub,
/// so the 'esp32' and 'sensor' drivers may run simultaneously — one
/// socket, every listener gets every datagram.
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

  /// Sniff the `calib` flag from a node beacon datagram without a full
  /// parse: true = the node is participating in the vacant-window
  /// calibration, false = explicitly not, null = not a beacon / no
  /// flag / unparseable. Never throws. (The full beacon parse lives in
  /// the drivers; this is the shared, cheap pre-check.)
  static bool? beaconCalibFlag(String text) {
    try {
      final t = text.trim();
      if (!t.startsWith('{')) return null;
      // Cheap structural check before JSON decode: must look like a
      // beacon and mention calib at all.
      if (!t.contains('"type"') || !t.contains('calib')) return null;
      // Minimal manual extraction: avoids a full jsonDecode on the
      // hot path for non-beacon traffic.
      final typeM = RegExp(r'"type"\s*:\s*"beacon"').firstMatch(t);
      if (typeM == null) return null;
      final m =
          RegExp(r'"calib"\s*:\s*(true|false)').firstMatch(t);
      if (m == null) return null;
      return m.group(1) == 'true';
    } catch (_) {
      return null;
    }
  }
}
