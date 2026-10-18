/// Shepherd CoT ingest — Predator emitter tracks as corroboration-only
/// evidence.
///
/// RX-only: joins the CoT multicast group, parses inbound CoT XML
/// WITHOUT the xml package (hand parser), keeps only events whose
/// callsign starts with the configured emitter prefix (default
/// `PREDATOR-`), and holds them in a time window. [checkCoincidence]
/// reports emitter observations spatially coincident with Shepherd
/// tracks as upgrade-only, never-subtractive corroboration feeding the
/// gated confidence merger (see docs/predator_integration_spec.md).
///
/// CORROBORATION CONTRACT (structural):
///  - never originates a track: an emitter with no Shepherd track
///    produces nothing;
///  - never subtractive: coincidences carry boost >= 0 only;
///  - stale emitters (older than windowSeconds) contribute nothing.
///
/// License boundary (load-bearing): Predator is GPL-3.0, Shepherd is
/// MIT. This file speaks the CoT wire protocol only — no Predator
/// code, no shared code, no linking.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'multicast_lock.dart';

/// Ingest configuration. Listening is OFF by default — ingesting
/// someone else's emitter tracks must be a deliberate act.
class CotListenerConfig {
  const CotListenerConfig({
    this.enabled = false,
    this.multicastGroup = '239.2.3.1',
    this.multicastPort = 6969,
    this.emitterPrefix = 'PREDATOR-',
    this.windowSeconds = 60,
    this.coincidenceRadiusM = 50.0,
  });

  final bool enabled;
  final String multicastGroup;
  final int multicastPort;

  /// Only events whose callsign starts with this prefix are kept.
  /// Operator-editable so any CoT emitter feed can be ingested.
  final String emitterPrefix;

  /// Observation lifetime in seconds. Stale emitters are dropped and
  /// contribute zero corroboration.
  final int windowSeconds;

  /// Emitter-track spatial coincidence radius in meters. Must exceed
  /// the sum of both sensors' position errors or it's numerology —
  /// field-tunable, default 50 m per the integration spec.
  final double coincidenceRadiusM;
}

/// One inbound emitter observation from a CoT event.
///
/// `ce` (circular error, meters) defaults to **25.0** when the event
/// carries no parseable `ce` — a DOCUMENTED fixed default, never
/// silent (per the integration spec's "fixed defaults must be
/// documented" rule). TDOA estimates from two+ nodes are typically
/// tens of meters, so 25 m is the honest middle.
class EmitterObservation {
  const EmitterObservation({
    required this.callsign,
    required this.lat,
    required this.lon,
    this.ce = 25.0,
    required this.time,
    required this.type,
  });

  final String callsign;
  final double lat;
  final double lon;
  final double ce;
  final DateTime time; // UTC, from the event's time attribute
  final String type; // CoT type string, e.g. "a-u-S"
}

/// Emitter-mover coincidence: a fresh emitter observation within
/// [CotListenerConfig.coincidenceRadiusM] of an active Shepherd track.
///
/// "Coincident", never "confirmed" — spatial proximity of two
/// independent estimates, each with stated error. Feeds the gated
/// merger as upgrade-only corroboration.
class EmitterCoincidence {
  const EmitterCoincidence({
    required this.emitterCallsign,
    required this.trackId,
    required this.lat,
    required this.lon,
    required this.distanceM,
    required this.freshness01,
    this.boost = kEmitterBoost,
  });

  final String emitterCallsign;
  final String trackId;
  final double lat;
  final double lon;
  final double distanceM;

  /// 1 - age/window, 0 when stale. The freshness gate weight.
  final double freshness01;

  /// Upgrade-only corroboration class: the Doppler refinement layer's
  /// class (0.10). NEVER negative — the listener has no code path that
  /// emits a negative boost.
  final double boost;
}

/// Corroboration class for an emitter coincidence (Doppler layer class).
const double kEmitterBoost = 0.10;

/// Great-circle distance in meters (haversine, WGS84 mean radius).
double haversineMeters(
    double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
}

/// Shepherd track position for coincidence checks (WGS84).
class TrackPosition {
  const TrackPosition({required this.id, required this.lat, required this.lon});
  final String id;
  final double lat;
  final double lon;
}

/// Hand-rolled CoT event attribute extractor. Parses `<tag attr="v"
/// ...>` WITHOUT the xml package: finds the opening tag, then matches
/// attr="value" pairs. Returns null when the tag or any attribute
/// cannot be extracted. Never throws.
Map<String, String>? _tagAttrs(String xml, String tag) {
  try {
    final open = xml.indexOf('<$tag');
    if (open < 0) return null;
    final close = xml.indexOf('>', open);
    if (close < 0) return null;
    final head = xml.substring(open, close);
    final attrs = <String, String>{};
    for (final m in RegExp(r'([A-Za-z0-9_:\-]+)="([^"]*)"')
        .allMatches(head)) {
      attrs[m.group(1)!] = m.group(2)!;
    }
    return attrs;
  } catch (_) {
    return null;
  }
}

/// CoT ingest listener. [handleDatagram] and [checkCoincidence] are
/// fully testable without sockets; [start]/[stop] own the multicast
/// subscription.
class CotListener {
  CotListener({required this.config});

  final CotListenerConfig config;

  /// Observations keyed by callsign (upsert on repeat events).
  final Map<String, EmitterObservation> _observations = {};

  RawDatagramSocket? _socket;

  /// Last time the observation map was pruned. Pruning is O(n) over
  /// the map, so the per-datagram path amortizes it to at most once
  /// per second (see _maybePrune).
  DateTime? _lastPruneAt;

  /// Last bind/start failure, for the dashboard status line. Null
  /// when the socket is up (or has never been started).
  String? _lastError;

  /// True while the multicast socket is bound. A failed bind leaves
  /// this false and records [_lastError] instead of throwing.
  bool get isListening => _socket != null;

  /// Bind/start failure detail (null when healthy).
  String? get lastError => _lastError;

  /// Feed one raw UDP datagram body through the CoT parser. NEVER
  /// throws: any parse failure drops the datagram silently.
  void handleDatagram(List<int> bytes, DateTime nowUtc) {
    try {
      _handle(bytes, nowUtc.toUtc());
    } catch (_) {
      // Structural guarantee: a bad datagram can never crash the
      // listener (and therefore never break detection).
    }
    _maybePrune(nowUtc.toUtc());
  }

  void _handle(List<int> bytes, DateTime now) {
    final xml = utf8.decode(bytes, allowMalformed: true);
    final event = _tagAttrs(xml, 'event');
    final point = _tagAttrs(xml, 'point');
    final contact = _tagAttrs(xml, 'contact');
    if (event == null || point == null || contact == null) return;

    final callsign = contact['callsign'] ?? '';
    if (!callsign.startsWith(config.emitterPrefix)) return;

    final lat = double.tryParse(point['lat'] ?? '');
    final lon = double.tryParse(point['lon'] ?? '');
    if (lat == null || lon == null) return;
    if (!lat.isFinite || !lon.isFinite) return;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return;

    final time = DateTime.tryParse(event['time'] ?? '');
    if (time == null) return;

    final ceRaw = double.tryParse(point['ce'] ?? '');
    // DOCUMENTED default: 25.0 m when ce is absent/unparseable (see
    // EmitterObservation docs).
    final ce =
        (ceRaw == null || !ceRaw.isFinite || ceRaw < 0) ? 25.0 : ceRaw;

    _observations[callsign] = EmitterObservation(
      callsign: callsign,
      lat: lat,
      lon: lon,
      ce: ce,
      time: time.toUtc(),
      type: event['type'] ?? '',
    );
  }

  /// Drop observations older than the window.
  void _prune(DateTime now) {
    final cutoff = now.subtract(Duration(seconds: config.windowSeconds));
    _observations.removeWhere((_, o) => o.time.isBefore(cutoff));
  }

  /// Amortized prune: datagrams can arrive at high rate and each
  /// prune is O(n) over the observation map, so skip when less than
  /// a second has passed since the last prune. Staleness granularity
  /// is 1 s against a 60 s (default) window — immaterial.
  void _maybePrune(DateTime now) {
    final last = _lastPruneAt;
    if (last != null &&
        now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _prune(now);
    _lastPruneAt = now;
  }

  /// Fresh emitter observations (pruned to the window), for the
  /// dashboard. INCLUDES future-dated observations: use
  /// [activeEmitterCount] for the "N emitters tracked" line.
  List<EmitterObservation> get activeEmitters {
    _maybePrune(DateTime.now().toUtc());
    return List.unmodifiable(_observations.values);
  }

  /// Dashboard "N emitters tracked" count: fresh observations that are
  /// not future-dated. A future-dated observation can never coincide
  /// ([checkCoincidence] skips age < 0), so counting it as "tracked"
  /// would be dishonest.
  int get activeEmitterCount {
    final now = DateTime.now().toUtc();
    _maybePrune(now);
    var n = 0;
    for (final o in _observations.values) {
      if (!o.time.isAfter(now)) n++;
    }
    return n;
  }

  /// Emitter-mover coincidences for the given Shepherd tracks.
  ///
  /// For each fresh observation x each track: haversine distance; if
  /// <= [CotListenerConfig.coincidenceRadiusM], emit one
  /// [EmitterCoincidence] with freshness-weighted gate (stale = 0).
  /// An emitter with no track in radius produces nothing — and no
  /// track is ever created here.
  List<EmitterCoincidence> checkCoincidence(
      List<TrackPosition> tracks, DateTime nowUtc) {
    if (!config.enabled) return const [];
    final now = nowUtc.toUtc();
    _maybePrune(now);
    final window = Duration(seconds: config.windowSeconds);
    final out = <EmitterCoincidence>[];
    for (final obs in _observations.values) {
      final age = now.difference(obs.time);
      if (age.isNegative) continue;
      final freshness = 1.0 - age.inMicroseconds / window.inMicroseconds;
      if (freshness <= 0) continue;
      for (final track in tracks) {
        final d = haversineMeters(obs.lat, obs.lon, track.lat, track.lon);
        if (d <= config.coincidenceRadiusM) {
          out.add(EmitterCoincidence(
            emitterCallsign: obs.callsign,
            trackId: track.id,
            lat: obs.lat,
            lon: obs.lon,
            distanceM: d,
            freshness01: freshness.clamp(0.0, 1.0),
            boost: kEmitterBoost,
          ));
        }
      }
    }
    return out;
  }

  /// start()/stop() run strictly one after another. Concurrent calls
  /// (rapid settings edits) used to interleave across the socket
  /// awaits, leaking a socket or stopping one a newer call relied on.
  Future<void> _opChain = Future<void>.value();

  Future<void> _serialize(Future<void> Function() op) {
    final next = _opChain.then((_) => op()).catchError((Object _) {});
    _opChain = next;
    return next;
  }

  /// Non-fatal condition (listening, but degraded), e.g. the Android
  /// multicast lock could not be taken. Null when healthy.
  String? _warning;
  String? get warning => _warning;

  /// Join the CoT multicast group and ingest datagrams. No-op when
  /// disabled. A bind failure does NOT throw: it is recorded in
  /// [lastError] and the listener reports not-listening, so the
  /// dashboard can say so instead of claiming to listen. A socket that
  /// dies later (network change, interface down) is detected through
  /// the stream's error/done handlers and also reported.
  Future<void> start() => _serialize(_start);

  Future<void> _start() async {
    if (!config.enabled) return;
    await _stop();
    _lastError = null;
    _warning = null;
    // Android drops inbound multicast without a MulticastLock.
    final locked = await MulticastLock.acquire();
    if (!locked) {
      _warning = 'multicast lock unavailable — Wi-Fi may drop CoT';
    }
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, config.multicastPort);
      sock.joinMulticast(InternetAddress(config.multicastGroup));
    } catch (e) {
      try {
        sock?.close();
      } catch (_) {}
      _lastError = e.toString();
      await MulticastLock.release();
      return;
    }
    final bound = sock;
    _socket = bound;
    bound.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        // Drain everything queued; one receive per event can lag.
        for (var dg = bound.receive(); dg != null; dg = bound.receive()) {
          handleDatagram(dg.data, DateTime.now().toUtc());
        }
      },
      onError: (Object e) => _socketDied(bound, e.toString()),
      onDone: () => _socketDied(bound, 'socket closed'),
      cancelOnError: true,
    );
  }

  /// The socket ended without [stop] being called. Only acts when it
  /// is still the current socket (our own close clears [_socket]
  /// first, so an intentional stop is ignored here).
  void _socketDied(RawDatagramSocket sock, String why) {
    if (!identical(_socket, sock)) return;
    _socket = null;
    _lastError = 'listen socket lost: $why';
    try {
      sock.close();
    } catch (_) {}
    unawaited(MulticastLock.release());
  }

  /// Leave the group and close the socket.
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    final sock = _socket;
    _socket = null;
    if (sock != null) {
      try {
        sock.leaveMulticast(InternetAddress(config.multicastGroup));
      } catch (_) {}
      try {
        sock.close();
      } catch (_) {}
      await MulticastLock.release();
    }
  }

  /// Clear all held observations (for tests / operator reset).
  void clear() => _observations.clear();
}
