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

import 'dart:convert';
import 'dart:io';

class NodeUdpHub {
  NodeUdpHub._();

  /// The Shepherd node broadcast port (beacons, events, sensor_obs).
  static const int port = 49160;

  /// Datagrams larger than this are dropped unparsed (real node
  /// traffic is a few hundred bytes of JSON).
  static const int maxDatagramBytes = 16384;

  /// Flood guard: at most this many datagrams are processed per second.
  static const int maxPerSecond = 2000;

  /// Optional source allowlist (IP strings). Null/empty = accept any
  /// sender on the segment. Node traffic is otherwise unauthenticated,
  /// so on a shared network set this to the nodes' addresses.
  static Set<String>? allowedSources;

  /// Parse a comma/space separated list into [allowedSources].
  static void setAllowedSourcesFromText(String text) {
    final set = text
        .split(RegExp(r'[,\s;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    allowedSources = set.isEmpty ? null : set;
  }

  /// Last bind/socket failure (null when healthy), so callers can say
  /// "cannot listen" instead of claiming to listen.
  static String? lastError;

  /// True while the socket is bound.
  static bool get isBound => _sock != null;

  static RawDatagramSocket? _sock;
  static final Set<void Function(String)> _listeners = {};
  static Future<void>? _starting;

  static DateTime _winStart = DateTime.fromMillisecondsSinceEpoch(0);
  static int _winCount = 0;

  static bool _rateOk() {
    final now = DateTime.now();
    if (now.difference(_winStart) >= const Duration(seconds: 1)) {
      _winStart = now;
      _winCount = 0;
    }
    return ++_winCount <= maxPerSecond;
  }

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
      final sock =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      sock.broadcastEnabled = true;
      _sock = sock;
      lastError = null;
      sock.listen(
        (event) => _onEvent(sock, event),
        onError: (Object e) => _died(sock, '$e'),
        onDone: () => _died(sock, 'socket closed'),
        cancelOnError: true,
      );
      // Every listener released while we were still binding: don't leave
      // an orphan socket holding the port.
      if (_listeners.isEmpty) {
        _sock = null;
        sock.close();
      }
    } catch (e) {
      _sock = null;
      lastError = 'cannot bind UDP $port: $e';
    } finally {
      _starting = null;
    }
  }

  static void _onEvent(RawDatagramSocket sock, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    for (var dg = sock.receive(); dg != null; dg = sock.receive()) {
      if (dg.data.length > maxDatagramBytes) continue;
      if (!_rateOk()) continue;
      final allow = allowedSources;
      if (allow != null && !allow.contains(dg.address.address)) continue;
      // UTF-8, not fromCharCodes (which maps each byte to one code unit
      // and garbles every non-ASCII name).
      final text = utf8.decode(dg.data, allowMalformed: true);
      for (final l in _listeners.toList()) {
        try {
          l(text);
        } catch (_) {}
      }
    }
  }

  /// The socket ended without [release]: record why and clear it so the
  /// next [ensureListening] rebinds.
  static void _died(RawDatagramSocket sock, String why) {
    if (!identical(_sock, sock)) return;
    _sock = null;
    lastError = 'node socket lost: $why';
    try {
      sock.close();
    } catch (_) {}
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
