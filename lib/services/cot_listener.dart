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
    this.allowedSources = const <String>[],
  });

  /// Sender IPs accepted (empty = any). CoT multicast is unauthenticated:
  /// any host on the segment can send events that earn the corroboration
  /// boost, so deployments on shared networks should list their sources.
  final List<String> allowedSources;

  /// Parse a comma/space separated IP list.
  static List<String> parseSources(String text) => text
      .split(RegExp(r'[,\s;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList()
    ..sort();

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

/// Domain of a platform observation, from its CoT type: friendly
/// GROUND (`a-f-G*` — a dismount's PLI out of an ATAK EUD, the
/// PRC-163 path, v0.23.0) vs AIR (everything else the platform path
/// accepts). Derived from the type string at read time — the type
/// IS the source of truth, so domain and type can never disagree.
enum PlatformDomain { air, ground }

/// One inbound FRIENDLY PLATFORM observation from a CoT event
/// (Skydio integration P1: his X10Ds arrive as controller CoT;
/// v0.23.0: his dismounts arrive the same way, as `a-f-G*` PLI).
///
/// This is a separate collection from [EmitterObservation] with a
/// separate contract: emitter observations are corroboration-only
/// and never originate anything; platform observations ARE the
/// platform's own cooperative self-report (air: position node
/// evidence, Class B; ground: a friendly track position) and render
/// as friendly platforms. They never feed the confidence merger and
/// never corroborate or suppress a track.
class PlatformObservation {
  const PlatformObservation({
    required this.uid,
    required this.callsign,
    required this.type,
    required this.lat,
    required this.lon,
    required this.time,
    this.haeM,
    this.courseDeg,
    this.speedMps,
    this.batteryPct,
  });

  /// CoT event uid (stable per platform while the feed runs).
  final String uid;
  final String callsign;

  /// CoT type string, e.g. `a-f-A` (friendly air) or `a-f-G-U-C`
  /// (friendly ground unit).
  final String type;

  /// Ground vs air, derived from [type] (see [PlatformDomain]).
  PlatformDomain get domain =>
      type.startsWith('a-f-G') ? PlatformDomain.ground : PlatformDomain.air;

  bool get isGround => domain == PlatformDomain.ground;
  final double lat;
  final double lon;
  final DateTime time; // UTC, from the event's time attribute

  /// Height above ellipsoid (m) from the point element, when sane.
  final double? haeM;

  /// Course over ground (deg) and speed (m/s) from `<track>`.
  final double? courseDeg;
  final double? speedMps;

  /// Battery percent 0..100 from `<status battery>`, when present.
  /// ATAK writes an integer percent; a non-integer value in (0,1)
  /// is read as a fraction (documented ambiguity, see parser).
  final double? batteryPct;
}

/// Whether a CoT event belongs to a known friendly platform:
/// (callsign, uid, cotType) → keep as platform observation. Supplied
/// by the app from the friendly registry; the listener stays dumb.
typedef CotPlatformMatcher = bool Function(
    String callsign, String uid, String cotType);

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
    // Double- or single-quoted values (both are valid XML).
    for (final m in RegExp(r'''([A-Za-z0-9_:\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''')
        .allMatches(head)) {
      attrs[m.group(1)!] = m.group(2) ?? m.group(3) ?? '';
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
  CotListener({required this.config, this.platformMatcher});

  final CotListenerConfig config;

  /// Friendly-platform ingest (Skydio P1). When non-null, CoT events
  /// are ALSO evaluated as platform observations: an event is kept as
  /// a platform when its type is friendly air (`a-f-A*`) or this
  /// matcher accepts it (registry callsign/uid). Null = platform
  /// ingest off; the emitter path is unaffected either way.
  final CotPlatformMatcher? platformMatcher;

  /// Platform observations keyed by event uid (upsert on repeat).
  final Map<String, PlatformObservation> _platforms = {};

  /// Largest tolerated future-dating of an event vs. local time.
  static const Duration maxClockSkew = Duration(seconds: 30);

  /// Most distinct emitters held at once.
  static const int maxObservations = 256;

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

    // Shared position/time validation for both ingest paths. The
    // emitter path historically applied exactly these checks; the
    // platform path needs the same hygiene (a far-future timestamp
    // would never be pruned and pins memory).
    final lat = double.tryParse(point['lat'] ?? '');
    final lon = double.tryParse(point['lon'] ?? '');
    if (lat == null || lon == null) return;
    if (!lat.isFinite || !lon.isFinite) return;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return;

    final time = DateTime.tryParse(event['time'] ?? '');
    if (time == null) return;
    // A far-future timestamp would never be pruned (age stays negative)
    // and lets a sender pin entries in memory indefinitely: allow only
    // modest clock skew.
    if (time.toUtc().isAfter(now.add(maxClockSkew))) return;

    final type = event['type'] ?? '';
    final uid = event['uid'] ?? '';

    // --- Emitter path (Predator corroboration contract, unchanged).
    if (callsign.startsWith(config.emitterPrefix)) {
      final ceRaw = double.tryParse(point['ce'] ?? '');
      // DOCUMENTED default: 25.0 m when ce is absent/unparseable (see
      // EmitterObservation docs).
      final ce =
          (ceRaw == null || !ceRaw.isFinite || ceRaw < 0) ? 25.0 : ceRaw;

      // Bounded: unique callsigns under the prefix must not grow the
      // map without limit between prunes.
      if (_observations.containsKey(callsign) ||
          _observations.length < maxObservations) {
        _observations[callsign] = EmitterObservation(
          callsign: callsign,
          lat: lat,
          lon: lon,
          ce: ce,
          time: time.toUtc(),
          type: type,
        );
      }
    }

    // --- Platform path (Skydio P1 friendly platforms; v0.23.0
    // adds friendly GROUND: `a-f-G*` PLI events — a PRC-163
    // carrier's position out of an EUD — enter by type exactly as
    // `a-f-A*` does. The domain is read off the type downstream
    // ([PlatformObservation.domain]), so ground events can never
    // be mistaken for airframes by this collection's consumers.
    final matcher = platformMatcher;
    if (matcher != null &&
        (type.startsWith('a-f-A') ||
            type.startsWith('a-f-G') ||
            matcher(callsign, uid, type))) {
      _handlePlatform(xml, event, point,
          callsign: callsign, uid: uid, type: type,
          lat: lat, lon: lon, time: time.toUtc());
    }
  }

  void _handlePlatform(
    String xml,
    Map<String, String> event,
    Map<String, String> point, {
    required String callsign,
    required String uid,
    required String type,
    required double lat,
    required double lon,
    required DateTime time,
  }) {
    final key = uid.isNotEmpty ? uid : callsign;
    if (key.isEmpty) return;
    if (!_platforms.containsKey(key) &&
        _platforms.length >= maxObservations) {
      return;
    }
    // hae: CoT uses 999999.0 as the unknown sentinel; only plausible
    // altitudes are kept, absence stays null (never zero-filled).
    final haeRaw = double.tryParse(point['hae'] ?? '');
    final hae = (haeRaw != null && haeRaw.isFinite && haeRaw.abs() < 100000)
        ? haeRaw
        : null;
    final track = _tagAttrs(xml, 'track');
    final courseRaw =
        track == null ? null : double.tryParse(track['course'] ?? '');
    final course = (courseRaw != null &&
            courseRaw.isFinite &&
            courseRaw >= 0 &&
            courseRaw <= 360)
        ? courseRaw
        : null;
    final speedRaw =
        track == null ? null : double.tryParse(track['speed'] ?? '');
    final speed =
        (speedRaw != null && speedRaw.isFinite && speedRaw >= 0)
            ? speedRaw
            : null;
    final status = _tagAttrs(xml, 'status');
    final battRaw =
        status == null ? null : double.tryParse(status['battery'] ?? '');
    double? battery;
    if (battRaw != null && battRaw.isFinite) {
      // ATAK convention is integer percent 0..100. A non-integer
      // value strictly inside (0,1) can only be a fraction — read it
      // as one; 0 and 1 stay percent (documented ambiguity).
      battery = (battRaw > 0 && battRaw < 1)
          ? (battRaw * 100).clamp(0.0, 100.0)
          : battRaw.clamp(0.0, 100.0);
    }
    _platforms[key] = PlatformObservation(
      uid: key,
      callsign: callsign,
      type: type,
      lat: lat,
      lon: lon,
      time: time,
      haeM: hae,
      courseDeg: course,
      speedMps: speed,
      batteryPct: battery,
    );
  }

  /// Drop observations older than the window.
  void _prune(DateTime now) {
    final cutoff = now.subtract(Duration(seconds: config.windowSeconds));
    _observations.removeWhere((_, o) => o.time.isBefore(cutoff));
    _platforms.removeWhere((_, o) => o.time.isBefore(cutoff));
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

  /// Fresh friendly-platform observations (pruned to the window),
  /// for the identity classifier (air + ground records). The Drone
  /// tab reads only the classifier's AIR records — ground
  /// observations can never reach it. Empty unless a platform
  /// matcher was supplied at construction.
  List<PlatformObservation> get platformObservations {
    _maybePrune(DateTime.now().toUtc());
    return List.unmodifiable(_platforms.values);
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
          final allow = config.allowedSources;
          if (allow.isNotEmpty && !allow.contains(dg.address.address)) {
            continue;
          }
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
  void clear() {
    _observations.clear();
    _platforms.clear();
  }
}
