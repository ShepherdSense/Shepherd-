/// Shepherd CoT track output — emit-only, defensive-only.
///
/// Publishes Shepherd's fused tracks as Cursor-on-Target events so they
/// appear on ATAK / WinTAK / TAK Server alongside the rest of the COP.
///
/// DEFENSIVE-ONLY CONTRACT: the only bytes Shepherd ever sends are its
/// own CoT track events. Affiliation is ALWAYS 'u' (unknown) — Shepherd
/// never asserts hostile/friendly. No fire-control language, no weapon
/// cueing, no transmit beyond our own tracks.
///
/// Specs: docs/shepherd_cot_output_spec.md (emit format) and
/// docs/predator_integration_spec.md (callsign contract — NOTE: the
/// callsign format here uses `SHEPHERD-<trackId>` with a hyphen, no
/// space, superseding the old spec's spaced form).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'geo_projection.dart';

/// One fused-tracker track, as consumed from the tracker's map-meter
/// output stream.
class CotTrackInput {
  const CotTrackInput({
    required this.trackId,
    required this.xEast,
    required this.yNorth,
    required this.headingDeg,
    required this.speedMps,
    required this.sizeLabel,
    required this.sizeConfidence,
    required this.typeGuess,
    required this.typeConfidence,
    required this.inboundOutbound,
    required this.confidence,
    required this.positionUncertaintyM,
  });

  final String trackId;
  final double xEast; // map meters, east of origin
  final double yNorth; // map meters, north of origin
  final double headingDeg; // degrees true, 0..360
  final double speedMps;
  final String sizeLabel; // e.g. "S" / "M" / "L"
  final double sizeConfidence; // 0..1
  final String typeGuess; // e.g. "Possible fixed-wing drone"
  final double typeConfidence; // 0..1
  final String inboundOutbound; // e.g. "INBOUND TO DEFENDED POINT"
  final double confidence; // C_display, 0..1
  final double positionUncertaintyM; // ce/le for the point element
}

/// Destination and gating configuration. Publishing is OFF by default —
/// sending to a tactical net must be a deliberate act.
class CotPublisherConfig {
  const CotPublisherConfig({
    this.enabled = false,
    this.useMulticast = true,
    this.multicastGroup = '239.2.3.1',
    this.multicastPort = 6969,
    this.takHost = '',
    this.takPort = 8087,
    this.callsignPrefix = 'SHEPHERD-',
    this.staleSeconds = 30,
    this.publishFloor = 0.3,
    this.airTypeThreshold = 0.5,
  });

  final bool enabled;

  /// Destination selector: true = UDP multicast (default), false = TAK
  /// Server TCP.
  final bool useMulticast;

  final String multicastGroup;
  final int multicastPort;
  final String takHost;
  final int takPort;

  /// Callsign/uid prefix. Contract default: 'SHEPHERD-' (hyphen, no
  /// space) per docs/predator_integration_spec.md.
  final String callsignPrefix;

  /// Stale window in seconds (default 30). Track loss is signaled by
  /// letting the event go stale — no explicit deletes.
  final int staleSeconds;

  /// Tracks below this confidence are never published.
  final double publishFloor;

  /// Type-guess confidence at or above this, with an air-type guess,
  /// emits `a-u-A`; otherwise `a-u-G`.
  final double airTypeThreshold;
}

/// XML attribute escaping (deterministic for golden tests).
String _attr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// XML text-node escaping.
String _text(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Millisecond-precision UTC ISO 8601, e.g. "2026-10-18T19:35:00.123Z".
/// Dart's toIso8601String omits the fraction when millis are zero, so
/// we build it by hand for deterministic output.
String _isoMillisUtc(DateTime dt) {
  final u = dt.toUtc();
  String p(int v, int w) => v.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month, 2)}-${p(u.day, 2)}'
      'T${p(u.hour, 2)}:${p(u.minute, 2)}:${p(u.second, 2)}'
      '.${p(u.millisecond, 3)}Z';
}

/// Sanitized track identity for uid/callsign: prefix + trackId with any
/// dots or whitespace collapsed to '-' (TAK uids must not contain them).
String cotUid(String callsignPrefix, String trackId) {
  final clean = trackId.replaceAll(RegExp(r'[\s.]+'), '-');
  return '$callsignPrefix$clean';
}

/// CoT type selection. `a-u-A` (unknown air) iff the type guess names
/// an airframe class (case-insensitive substring match) AND its
/// confidence meets the air threshold; otherwise `a-u-G` (unknown
/// ground). Affiliation is ALWAYS 'u' — never emit h/f.
String cotTypeFor(
    String typeGuess, double typeConfidence, double airTypeThreshold) {
  if (typeConfidence >= airTypeThreshold) {
    final g = typeGuess.toLowerCase();
    if (g.contains('drone') ||
        g.contains('fixed-wing') ||
        g.contains('fixedwing') ||
        g.contains('rotary') ||
        g.contains('quad') ||
        g.contains('multirotor')) {
      return 'a-u-A';
    }
  }
  return 'a-u-G';
}

/// PURE function: one [CotTrackInput] -> one byte-deterministic CoT
/// event XML string. No I/O, no clock reads (caller supplies [nowUtc]).
String buildEventXml(
  CotTrackInput t,
  DateTime nowUtc, {
  required GeoProjection projection,
  CotPublisherConfig config = const CotPublisherConfig(),
}) {
  final uid = cotUid(config.callsignPrefix, t.trackId);
  final type = cotTypeFor(t.typeGuess, t.typeConfidence, config.airTypeThreshold);
  final geo = projection.metersToLatLon(t.xEast, t.yNorth);
  final time = _isoMillisUtc(nowUtc);
  final stale = _isoMillisUtc(
      nowUtc.add(Duration(seconds: config.staleSeconds)));
  final confPct = (t.sizeConfidence * 100).round();
  var remarks = '${t.sizeLabel} (conf $confPct%). ${t.typeGuess} — ${t.inboundOutbound}.';
  if (remarks.length > 200) remarks = remarks.substring(0, 200);

  final b = StringBuffer();
  b.write('<event version="2.0"');
  b.write(' uid="${_attr(uid)}"');
  b.write(' type="${_attr(type)}"');
  b.write(' time="${_attr(time)}"');
  b.write(' start="${_attr(time)}"');
  b.write(' stale="${_attr(stale)}"');
  b.write(' how="m-g">');
  b.write('<point lat="${geo.lat.toStringAsFixed(6)}"');
  b.write(' lon="${geo.lon.toStringAsFixed(6)}"');
  b.write(' hae="0.0"');
  b.write(' ce="${t.positionUncertaintyM.toStringAsFixed(1)}"');
  b.write(' le="${t.positionUncertaintyM.toStringAsFixed(1)}"/>');
  b.write('<detail>');
  b.write('<contact callsign="${_attr(uid)}"/>');
  b.write('<track course="${t.headingDeg.toStringAsFixed(1)}"');
  b.write(' speed="${t.speedMps.toStringAsFixed(2)}"/>');
  b.write('<remarks>${_text(remarks)}</remarks>');
  b.write('</detail>');
  b.write('</event>');
  return b.toString();
}

/// CoT event publisher: throttle, gates, transport (UDP multicast or
/// TAK Server TCP).
///
/// Read-only consumer of the fused tracker: [publishTrack] is called
/// per track update. Emits nothing when disabled, when no GPS anchor
/// is set ([projection] null — log and skip), or when track
/// confidence is below the publish floor.
class CotPublisher {
  CotPublisher({
    required this.config,
    this.projection,
    Future<void> Function(List<int> bytes)? sender,
  }) : _sender = sender;

  final CotPublisherConfig config;

  /// Map-meters -> WGS84 anchor. Null until the map is registered —
  /// publish is impossible without it, so tracks are skipped.
  GeoProjection? projection;

  /// Test seam: injected sender replaces the real transport. Default
  /// is the real transport (multicast UDP or TAK Server TCP).
  final Future<void> Function(List<int> bytes)? _sender;

  final Map<String, DateTime> _lastSentAt = {};
  RawDatagramSocket? _udp;

  /// Shared bind future: two concurrent first-sends must not both
  /// bind and leak one socket (see _udpSocket).
  Future<RawDatagramSocket>? _udpBind;

  Socket? _tak;
  int _takBackoffSeconds = 1;
  DateTime? _takNextRetryAt;

  int _publishedCount = 0;
  String? _lastError;
  DateTime? _lastSendAt;

  /// Log-once guard so the missing-anchor skip doesn't spam the log
  /// once per track update.
  bool _anchorSkipLogged = false;

  /// Publish one track update. Drops when: disabled, no projection,
  /// confidence below floor, or throttled (< 1 s since this track's
  /// last datagram). Never throws out of the transport path — errors
  /// are recorded in [stats] so a dead network can't break detection.
  Future<void> publishTrack(CotTrackInput t) async {
    if (!config.enabled) return;
    final proj = projection;
    if (proj == null) {
      // No GPS anchor: can't project — log (once per anchor loss) and
      // skip.
      if (!_anchorSkipLogged) {
        _anchorSkipLogged = true;
        debugPrint('CotPublisher: no GPS anchor — skipping CoT publish');
      }
      return;
    }
    if (t.confidence < config.publishFloor) return;

    final now = DateTime.now().toUtc();
    _lastSentAt.removeWhere(
        (_, at) => now.difference(at).inSeconds > config.staleSeconds);
    final last = _lastSentAt[t.trackId];
    if (last != null &&
        now.difference(last) < const Duration(seconds: 1)) {
      return; // throttle: max 1 datagram/sec per track
    }
    // Pessimistic record BEFORE the send await: the check-then-act
    // above spans an await, so two concurrent publishTrack calls for
    // the same track could both pass the throttle check. Recording
    // the slot up front closes the race; a failed send still consumes
    // the slot (no hot retry loop against a dead network).
    _lastSentAt[t.trackId] = now;

    final xml = buildEventXml(t, now, projection: proj, config: config);
    final bytes = utf8.encode(xml);
    try {
      final send = _sender ?? _defaultSend;
      await send(bytes);
      _anchorSkipLogged = false;
      _lastSendAt = now;
      _publishedCount++;
    } catch (e) {
      _lastError = e.toString();
    }
  }

  /// Lazily-bound multicast socket with a shared bind future: two
  /// concurrent first-sends share one bind instead of each binding
  /// and leaking one socket. A failed bind clears the shared future
  /// so the next send retries the bind rather than reusing a
  /// permanently-failed future.
  Future<RawDatagramSocket> _udpSocket() {
    final bound = _udp;
    if (bound != null) return Future.value(bound);
    var bind = _udpBind;
    if (bind == null) {
      bind = RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((s) {
        _udp = s;
        return s;
      });
      _udpBind = bind;
      bind.then((_) {}, onError: (_) => _udpBind = null);
    }
    return bind;
  }

  /// Real transport: UDP multicast or TAK Server TCP with
  /// reconnect + backoff. Plaintext CoT over the established socket.
  Future<void> _defaultSend(List<int> bytes) async {
    if (config.useMulticast) {
      final udp = await _udpSocket();
      final group = InternetAddress(config.multicastGroup);
      final sent = udp.send(bytes, group, config.multicastPort);
      if (sent <= 0) {
        // send() reports a full socket buffer / no route as 0, not an
        // exception — don't count that as a published event.
        throw StateError('multicast send returned 0 bytes');
      }
      return;
    }
    final sock = await _ensureTakSocket();
    if (sock == null) {
      throw StateError('TAK Server unreachable (${config.takHost}:${config.takPort})');
    }
    sock.add(bytes);
    await sock.flush();
  }

  /// Shared in-flight connect: two tracks publishing at once must not
  /// both connect and leak one socket (same fix as [_udpBind]).
  Future<Socket?>? _takConnecting;
  bool _disposed = false;

  /// TAK TCP socket with exponential backoff (1 s -> 60 s). Returns
  /// null when the server is currently unreachable (retry later).
  Future<Socket?> _ensureTakSocket() {
    final cur = _tak;
    if (cur != null) return Future.value(cur);
    final inflight = _takConnecting;
    if (inflight != null) return inflight;
    final f = _connectTak().whenComplete(() => _takConnecting = null);
    _takConnecting = f;
    return f;
  }

  Future<Socket?> _connectTak() async {
    final now = DateTime.now().toUtc();
    if (_takNextRetryAt != null && now.isBefore(_takNextRetryAt!)) {
      return null;
    }
    try {
      final sock = await Socket.connect(
        config.takHost,
        config.takPort,
        timeout: const Duration(seconds: 5),
      );
      if (_disposed) {
        sock.destroy();
        return null;
      }
      _tak = sock;
      _takBackoffSeconds = 1;
      _takNextRetryAt = null;
      void lost() {
        if (identical(_tak, sock)) _tak = null;
        sock.destroy();
      }

      // Drain inbound bytes. TAK Server streams its own traffic to
      // every client; never reading lets the buffers fill and the
      // server drop us. Listening also surfaces a server-side close
      // immediately instead of on the next failed write.
      sock.listen((_) {},
          onError: (Object _) => lost(), onDone: lost, cancelOnError: true);
      sock.done.then((_) => lost()).catchError((Object _) => lost());
      return sock;
    } catch (e) {
      _lastError = 'TAK connect failed: $e';
      _takNextRetryAt = now.add(Duration(seconds: _takBackoffSeconds));
      _takBackoffSeconds = (_takBackoffSeconds * 2).clamp(1, 60);
      return null;
    }
  }

  /// Dashboard status: how many tracks are currently publishing,
  /// last transport error, last successful send time.
  ({int tracksPublishing, String? lastError, DateTime? lastSentAt}) get stats =>
      (
        tracksPublishing: _lastSentAt.length,
        lastError: _lastError,
        lastSentAt: _lastSendAt,
      );

  /// True while the TAK TCP socket is up (multicast mode: always false,
  /// connectionless by design).
  bool get takConnected => _tak != null;

  /// Eager TAK connect for auto-connect: called at configure time when
  /// emit is enabled so the link state is known before the first track
  /// publish. No-op for multicast (connectionless), disabled configs,
  /// empty host, and the injected test sender. Failures reuse the
  /// existing backoff — a dead server just reads "RETRYING" until it
  /// answers. Never throws.
  Future<void> connectNow() async {
    if (!config.enabled || config.useMulticast) return;
    if (_sender != null) return;
    if (config.takHost.isEmpty) return;
    if (_disposed) return;
    try {
      await _ensureTakSocket();
    } catch (_) {}
  }

  /// Number of datagrams successfully sent this session (diagnostic).
  int get publishedCount => _publishedCount;

  void dispose() {
    _disposed = true;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    _udpBind = null;
    try {
      _tak?.destroy();
    } catch (_) {}
    _tak = null;
    _lastSentAt.clear();
  }
}
