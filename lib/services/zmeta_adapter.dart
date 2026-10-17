/// Shepherd → ZMeta event adapter (emit-only).
///
/// Translates Shepherd detections into ZMeta v1.1 events and ships them
/// over UDP to a ZMeta gateway (default 127.0.0.1:5555 — the gateway's
/// ingest port). One adapter runs per Shepherd mesh; the gateway fuses
/// across meshes. Shepherd never receives anything back: this is the
/// same emit-only posture as the ATAK CoT output path.
///
/// Targets the v1.1 lane (spec v1.1.26, schema zmeta-event-1.1.0):
/// declared-2D geo (semantics-contract 21.8) and SYSTEM_EVENT /
/// PLATFORM_STATUS (21.6) both require v1.1 — the v1.0 schema rejects
/// them. Everything else is unchanged from the v1.0 shape and validates
/// under 1.1 unchanged.
///
/// Event mapping:
///   tripwire CrossingEvent  → OBSERVATION_EVENT / RF
///   AI classifier label     → INFERENCE_EVENT / CLASSIFICATION
///   mesh heartbeat          → SYSTEM_EVENT / PLATFORM_STATUS (opt-in)
///
/// Honesty rules (mirroring ZMeta's own adapter contract, which is why
/// this pairing works):
/// - `power_dbm` is the DOCUMENTED SENTINEL `0.0`, flagged in
///   `quality.shepherd_power_sentinel` — a passive link sensor measures
///   channel disturbance, not emitter power, and the dip depth is in
///   radio-internal units, not dBm. The real measurement rides in the
///   explicitly-named `shepherd_dip_depth_db` feature. See
///   docs/zmeta_adapter_spec.md.
/// - No bearing is emitted for omnidirectional sensors. A KrakenSDR DoA
///   travels array-relative in `features` until a surveyed array
///   heading is configured.
/// - `bandwidth_hz: 0.0` is the documented sentinel for sensors that
///   cannot measure emitter bandwidth (same convention as ZMeta's own
///   kraken/moth/signalhunter adapters).
/// - `confidence` appears ONLY on INFERENCE/FUSION/STATE envelopes —
///   never on OBSERVATION (per ZMeta contract 7.1).
/// - GEO HONESTY (semantics-contract 6.2 + 21.8): canonical `geo` is
///   declared `"2D"` (lat/lon only, no `alt_m`). The device-reported
///   altitude is platform-dependent (Android: WGS-84 ellipsoid per
///   platform docs; iOS: MSL) and is NEVER verified HAE, so 6.2 forbids
///   it in `alt_m` — it rides in the explicitly-named
///   `features.shepherd_sensor_alt_m` instead, flagged in quality.
///   Substituting a non-HAE altitude into `alt_m` was rejected on the
///   ZMeta record (doctrine A1-02); a 2-D position is the honest
///   complete statement of what the sensor measured. `geo` is the
///   SENSOR (platform) position, never the target's — stated in quality.
/// - Original observations carry no `lineage` block (no ZMeta parent
///   exists); the INFERENCE carries a genuine `based_on` link to its
///   observation.
///
/// Pure Dart — no Flutter imports — so it stays unit-testable.
library zmeta_adapter;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/sensor_observation.dart';

/// ZMeta spec lane this adapter targets. v1.1: declared-2D geo (21.8)
/// and PLATFORM_STATUS (21.6) are v1.1 additions; the v1.0 schema
/// rejects both.
const String kZmetaVersion = '1.1.0';

/// Default ZMeta gateway ingest endpoint (their reference gateway
/// listens on UDP 0.0.0.0:5555).
const String kZmetaDefaultHost = '127.0.0.1';
const int kZmetaDefaultPort = 5555;

/// True for loopback targets, where no wire is involved — a local
/// gateway needs no WireGuard tunnel. Accepts the app's own prefill
/// style (`127.0.0.1:5555`), bracketed IPv6 (`[::1]`), trailing dots
/// (`localhost.`), and the whole 127/8 block. Canonical definition
/// shared by the settings UI warning (settings.dart) and the fail-closed
/// emit path (state/app_state.dart): keep exactly one copy.
bool zmetaIsLocalHost(String h) {
  var s = h.trim().toLowerCase();
  // Strip brackets, e.g. [::1] or [::1]:5555.
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close > 0) s = s.substring(1, close) + s.substring(close + 1);
  }
  // Strip a :port suffix. Bare IPv6 (::1) has more than one colon.
  final firstColon = s.indexOf(':');
  if (firstColon >= 0 && s.indexOf(':', firstColon + 1) < 0) {
    s = s.substring(0, firstColon);
  }
  // Trailing dot is a fully-qualified root form of the same name.
  s = s.replaceAll(RegExp(r'\.+$'), '');
  if (s == 'localhost' || s == '::1' || s == '127.1') return true;
  if (s.startsWith('127.')) {
    // 127.0.0.0/8 is loopback; validate the octets so 127.1.2.9999
    // doesn't sneak in as local.
    final parts = s.split('.');
    if (parts.length == 4 &&
        parts.every((p) {
          final n = int.tryParse(p);
          return n != null && n >= 0 && n <= 255;
        })) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Small primitives
// ---------------------------------------------------------------------------

/// UUIDv7 per RFC 9562 (what ZMeta's schema requires for event_id).
String zmetaUuid7() {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final rand = Random.secure();
  final b = List<int>.filled(16, 0);
  for (var i = 0; i < 6; i++) {
    b[i] = (nowMs >> (8 * (5 - i))) & 0xff;
  }
  b[6] = 0x70 | rand.nextInt(16); // version 7
  for (var i = 7; i < 16; i++) {
    b[i] = rand.nextInt(256);
  }
  b[8] = 0x80 | (b[8] & 0x3f); // variant 10xx
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// UTC timestamp in the exact form the ZMeta schema requires: trailing
/// `Z`, never an offset. Second resolution is plenty for detections.
String zmetaUtcZ(DateTime t) {
  final u = t.toUtc();
  String p(int n, int w) => n.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month, 2)}-${p(u.day, 2)}'
      'T${p(u.hour, 2)}:${p(u.minute, 2)}:${p(u.second, 2)}Z';
}

// ---------------------------------------------------------------------------
// Event builders
// ---------------------------------------------------------------------------

/// Best-known SENSOR (platform/mesh) position for one observation.
///
/// This is where the DETECTOR is, never where the target is — stated in
/// quality on every event that carries it. `altM` is the device-reported
/// altitude in meters; its reference frame is platform-dependent
/// (Android documents WGS-84 ellipsoid, iOS documents MSL) and is never
/// verified HAE, so it is excluded from canonical `geo` per ZMeta 6.2
/// and carried in features instead (semantics-contract 21.8).
class ZmetaSensorGeo {
  const ZmetaSensorGeo({
    required this.lat,
    required this.lon,
    this.altM,
    required this.source, // 'node-midpoint' | 'phone-gps'
    this.accuracyM,
    this.ageSec,
  });

  final double lat;
  final double lon;
  final double? altM;
  final String source;
  final double? accuracyM;
  final int? ageSec;

  /// Canonical ZMeta geo: declared 2-D (lat/lon only — 21.8 prohibits
  /// alt_m on a "2D" geo, and 6.2 prohibits non-HAE altitude in alt_m).
  Map<String, dynamic> toGeoJson() => {
        'lat': lat,
        'lon': lon,
        'dimensionality': '2D',
      };
}

/// Builds a ZMeta OBSERVATION_EVENT / RF for one Shepherd link
/// disturbance.
///
/// [freqHz] is the measurement channel's center frequency and is required
/// by the schema (Silvus 2440 MHz, SDR band center, ESP32 2.4 GHz ISM,
/// KrakenSDR tuned frequency from the link key). [bwHz] is the channel
/// bandwidth when known, else the documented 0.0 sentinel.
///
/// `power_dbm` — the schema requires it, but a passive link-disturbance
/// sensor measures channel disturbance, not emitter power, and Shepherd's
/// dip depth is in radio-internal units, not dBm. Following ZMeta's own
/// documented-sentinel precedent (bandwidth_hz: 0.0 for receiver-class
/// sensors that cannot measure emitter bandwidth), this adapter emits the
/// fixed documented sentinel `power_dbm: 0.0` and flags it in
/// `quality.shepherd_power_sentinel`. The real measurement — disturbance
/// depth in dB (radio units) — rides in the explicitly-named
/// `features.shepherd_dip_depth_db`. See docs/zmeta_adapter_spec.md.
Map<String, dynamic> zmetaObservation({
  required String platformId,
  required String sensorId,
  required DateTime ts,
  required String linkKey,
  required String driverId,
  required double dipDepthDb,
  required String direction, // 'dip' | 'rise'
  required double durationSecs,
  required String sizeEstimate, // S | M | L (heuristic)
  required double freqHz,
  double? bwHz,
  bool viaVariance = false,
  String? sigHint, // SDR signature hint, e.g. 'fhss-2g4'
  double? energyDbfs, // SDR band energy, dBFS (not dBm — kept explicit)
  double? doaArrayRelativeDeg, // KrakenSDR, array-relative until surveyed
  bool ppsLocked = false,
  ZmetaSensorGeo? sensorGeo, // detector position; 2-D canonical geo (21.8)
}) {
  final features = <String, dynamic>{
    'center_freq_hz': freqHz.isFinite ? freqHz : 0.0,
    // Documented sentinel: this sensor cannot measure emitter bandwidth.
    'bandwidth_hz': (bwHz != null && bwHz.isFinite) ? bwHz : 0.0,
    // Documented sentinel: passive link sensors don't measure emitter
    // power. See quality.shepherd_power_sentinel and the spec doc.
    // The disturbance magnitude is shepherd_dip_depth_db below.
    'power_dbm': 0.0,
    'shepherd_link': linkKey,
    'shepherd_driver': driverId,
    'shepherd_disturbance': direction,
    // Non-finite measurements are a programming error upstream; 0.0 keeps
    // the event schema-valid rather than emitting invalid JSON.
    'shepherd_dip_depth_db': dipDepthDb.isFinite ? dipDepthDb : 0.0,
    'shepherd_duration_s': durationSecs.isFinite ? durationSecs : 0.0,
    'shepherd_size_est': sizeEstimate,
    if (viaVariance) 'shepherd_via_variance': true,
    if (sigHint != null) 'shepherd_sig_hint': sigHint,
    if (energyDbfs != null && energyDbfs.isFinite)
      'shepherd_energy_dbfs': energyDbfs,
    if (doaArrayRelativeDeg != null && doaArrayRelativeDeg.isFinite)
      'kraken_doa_array_relative_deg': doaArrayRelativeDeg,
    // Device-reported altitude: platform-dependent reference frame,
    // never verified HAE — excluded from canonical geo per ZMeta 6.2,
    // carried here explicitly instead (21.8).
    if (sensorGeo?.altM != null && sensorGeo!.altM!.isFinite)
      'shepherd_sensor_alt_m': sensorGeo.altM,
  };

  final quality = <String, dynamic>{
    'calibration_state': 'UNCALIBRATED',
    'shepherd_estimates': true, // dip/size/duration are heuristic estimates
    // Consumer-visible sentinel flag: power_dbm is the documented
    // "not measured" sentinel, not 1 mW of received power.
    'shepherd_power_sentinel': true,
    // Canonical geo is the SENSOR (platform) position — never the
    // target's. Declared 2-D per 21.8: horizontal WGS-84 is real, the
    // vertical is device-reported (not verified HAE) and lives in
    // features.shepherd_sensor_alt_m instead.
    if (sensorGeo != null) ...{
      'geo_status': 'VERTICAL_UNAVAILABLE',
      'shepherd_geo_source': sensorGeo.source,
      'shepherd_geo_note':
          'Sensor (platform) position, not target position. '
          'Altitude is device-reported, reference frame not verified '
          'HAE — see features.shepherd_sensor_alt_m and the adapter spec.',
      if (sensorGeo.accuracyM != null && sensorGeo.accuracyM!.isFinite)
        'shepherd_geo_accuracy_m': sensorGeo.accuracyM,
      if (sensorGeo.ageSec != null) 'shepherd_geo_age_s': sensorGeo.ageSec,
    } else
      'geo_status': 'UNAVAILABLE',
  };

  final tsZ = zmetaUtcZ(ts);
  final payload = <String, dynamic>{
    'modality': 'RF',
    // Declared-2D canonical geo (21.8): present only when the detector
    // position is genuinely known; omitted — never zero-filled — per
    // 6.8 otherwise. This is the sensor's position, not the target's.
    if (sensorGeo != null) 'geo': sensorGeo.toGeoJson(),
    'features': features,
    'quality': quality,
    // Degraded timing stays visible: only a GPS-PPS-locked node may
    // claim better than UNKNOWN/UNSYNCED. last_sync_ts falls back to
    // the event timestamp per ZMeta's own reference convention, and
    // the error bound widens to their unsynced default (60 s).
    'timing_quality': {
      'time_source': ppsLocked ? 'GPS_PPS' : 'UNKNOWN',
      'sync_state': ppsLocked ? 'LOCKED' : 'UNSYNCED',
      'est_error_ms': ppsLocked ? 1 : 60000,
      'last_sync_ts': tsZ,
    },
  };

  // v1.1 geo: declared "2D" (lat/lon, no alt_m) when the detector
  // position is known (21.8); omitted — never zero-filled — per 6.8
  // otherwise. The sensor is identified by source.platform_id +
  // source.sensor_id regardless.

  return {
    'zmeta_version': kZmetaVersion,
    'event': {
      'event_id': zmetaUuid7(),
      'event_type': 'OBSERVATION_EVENT',
      'event_subtype': 'RF',
      'ts': zmetaUtcZ(ts),
    },
    'source': {
      'platform_id': platformId,
      'node_role': 'EDGE',
      'producer': 'rf-sensor-shepherd',
      'sensor_id': sensorId,
    },
    'profile': 'H',
    'payload': payload,
  };
}

/// Builds a ZMeta OBSERVATION_EVENT for a universal sensor observation
/// (acoustic bearing/spectrum, camera motion). The payload comes from
/// [SensorObservation.toZMetaPayload] — this function ONLY wraps it in
/// the envelope and MUST NOT invent fields the payload doesn't carry.
/// Returns null when the observation has no honest ZMeta modality
/// (RANGE/BINARY/ENERGY stay local).
Map<String, dynamic>? zmetaSensorObservation({
  required String platformId,
  required SensorObservation obs,
}) {
  final inner = obs.toZMetaPayload();
  if (inner == null) return null;
  final modality = '${inner['modality'] ?? ''}';
  final features = Map<String, dynamic>.of(
      (inner['features'] as Map?)?.cast<String, dynamic>() ?? {});
  // Sensor position (platform position, never the target's): declared
  // 2-D per 21.8 when genuinely known, omitted — never zero-filled —
  // per 6.8 otherwise.
  ZmetaSensorGeo? geo;
  if (obs.sensorLat != null &&
      obs.sensorLon != null &&
      obs.sensorLat!.isFinite &&
      obs.sensorLon!.isFinite &&
      !(obs.sensorLat == 0 && obs.sensorLon == 0)) {
    geo = ZmetaSensorGeo(
      lat: obs.sensorLat!,
      lon: obs.sensorLon!,
      source: 'sensor-observation',
    );
  }
  final tsZ = zmetaUtcZ(obs.timestamp);
  final payload = <String, dynamic>{
    'modality': modality,
    if (geo != null) 'geo': geo.toGeoJson(),
    'features': {
      ...features,
      'shepherd_obs_type': features['shepherd_obs_type'] ?? 'UNKNOWN',
      'shepherd_sensor_id': obs.sensorId,
    },
    'quality': {
      'calibration_state': 'UNCALIBRATED',
      'shepherd_estimates': true,
      if (geo != null) ...{
        'geo_status': 'VERTICAL_UNAVAILABLE',
        'shepherd_geo_source': geo.source,
        'shepherd_geo_note':
            'Sensor (platform) position, not target position.',
      } else
        'geo_status': 'UNAVAILABLE',
    },
    'timing_quality': {
      'time_source': 'UNKNOWN',
      'sync_state': 'UNSYNCED',
      'est_error_ms': 60000,
      'last_sync_ts': tsZ,
    },
  };
  return {
    'zmeta_version': kZmetaVersion,
    'event': {
      'event_id': zmetaUuid7(),
      'event_type': 'OBSERVATION_EVENT',
      'event_subtype': modality,
      'ts': tsZ,
    },
    'source': {
      'platform_id': platformId,
      'node_role': 'EDGE',
      // eo-sensor-* is the governed producer pattern for EO events
      // (policy/producer-authority.yaml).
      'producer': 'eo-sensor-shepherd',
      'sensor_id': obs.sensorId,
    },
    'profile': 'H',
    'payload': payload,
  };
}

/// Builds a ZMeta INFERENCE_EVENT / CLASSIFICATION for the embedded
/// disturbance classifier's label on one observation.
///
/// [observationId] must be the genuine event_id of the OBSERVATION this
/// label was derived from — lineage is never fabricated.
Map<String, dynamic> zmetaInference({
  required String platformId,
  required String observationId,
  required DateTime ts,
  required String label, // PASSING | LINGERING | INTERFERENCE | FAULT
  required double confidence, // 0..1
  String modelName = 'shepherd-disturbance-clf',
  String modelVersion = '1.0.0',
}) {
  final conf = confidence.clamp(0.0, 1.0);
  return {
    'zmeta_version': kZmetaVersion,
    'event': {
      'event_id': zmetaUuid7(),
      'event_type': 'INFERENCE_EVENT',
      'event_subtype': 'CLASSIFICATION',
      'ts': zmetaUtcZ(ts),
    },
    'source': {
      'platform_id': platformId,
      // policy/roles.yaml permits INFERENCE_EVENT only from node_role
      // GATEWAY — same convention as ZMeta's own eo-cv/sapient adapters,
      // whose inference also runs on the edge device.
      'node_role': 'GATEWAY',
      'producer': 'classifier-shepherd',
    },
    'profile': 'H',
    // Envelope confidence is REQUIRED on INFERENCE (contract 7.1).
    'confidence': conf,
    'lineage': {
      'based_on': [observationId],
    },
    'payload': {
      'inference_type': 'CLASSIFICATION',
      'claim': {
        'label': label,
        // Heuristic estimate, synthetic-trained — the confidence_hint
        // vocabulary keeps the claim honest about what it is.
        'confidence_hint': conf >= 0.8
            ? 'high'
            : conf >= 0.5
                ? 'medium'
                : 'low',
      },
      'model': {
        'name': modelName,
        'version': modelVersion,
      },
      'based_on': [observationId],
      'timing_quality': {
        'time_source': 'UNKNOWN',
        'sync_state': 'UNSYNCED',
        'est_error_ms': 60000,
        'last_sync_ts': zmetaUtcZ(ts),
      },
    },
  };
}

/// Builds a ZMeta SYSTEM_EVENT / PLATFORM_STATUS heartbeat for the mesh.
///
/// Opt-in (default off): a periodic "this mesh is alive, here is where
/// its platform is" for teams on the move. v1.1 subtype (21.6):
/// platform health and operating state — the platform's own position is
/// operating state, NOT track position (no target is implied).
///
/// [sensorGeo] is the platform position when freshly known (2-D, same
/// honesty rules as observations); omitted when unknown. [state] must be
/// one of the schema's platform states: NOMINAL | CAUTION | WARNING |
/// CRITICAL | UNKNOWN.
///
/// Schema note: PLATFORM_STATUS metrics require one power field
/// (battery_pct | fuel_remaining_pct | endurance_remaining_ms |
/// power_state). Shepherd runs on a phone/PC whose power state the app
/// does not measure, so it honestly reports `power_state: 'UNKNOWN'`
/// (an allowed enum value) rather than inventing a battery percentage.
Map<String, dynamic> zmetaPlatformStatus({
  required String platformId,
  required DateTime ts,
  required String state,
  required int nodeCount,
  required int detectionCount,
  required int heartbeatIntervalSec,
  ZmetaSensorGeo? sensorGeo,
}) {
  final metrics = <String, dynamic>{
    // Required by the schema (anyOf power fields); UNKNOWN is the
    // honest value — the app does not measure device power.
    'power_state': 'UNKNOWN',
    // Dismounted team carrying the mesh: ground platform.
    'platform_type': 'GROUND',
    'shepherd_node_count': nodeCount,
    'shepherd_detection_count': detectionCount,
    'shepherd_heartbeat_interval_s': heartbeatIntervalSec,
    if (sensorGeo != null) ...{
      'position': {
        'lat': sensorGeo.lat,
        'lon': sensorGeo.lon,
        'dimensionality': '2D',
        'source': sensorGeo.source,
        if (sensorGeo.altM != null && sensorGeo.altM!.isFinite)
          'sensor_alt_m': sensorGeo.altM,
        if (sensorGeo.accuracyM != null && sensorGeo.accuracyM!.isFinite)
          'accuracy_m': sensorGeo.accuracyM,
        if (sensorGeo.ageSec != null) 'age_s': sensorGeo.ageSec,
      },
      // Same honesty note as observations: platform position, and the
      // altitude is device-reported (not verified HAE).
      'position_note':
          'Platform (mesh) position, not a target track. Altitude is '
          'device-reported, reference frame not verified HAE.',
    },
  };
  return {
    'zmeta_version': kZmetaVersion,
    'event': {
      'event_id': zmetaUuid7(),
      'event_type': 'SYSTEM_EVENT',
      'event_subtype': 'PLATFORM_STATUS',
      'ts': zmetaUtcZ(ts),
    },
    'source': {
      'platform_id': platformId,
      // policy/roles.yaml: EDGE may emit OBSERVATION and SYSTEM.
      // policy/producer-authority.yaml: rf-sensor-* may emit
      // OBSERVATION_EVENT and SYSTEM_EVENT.
      'node_role': 'EDGE',
      'producer': 'rf-sensor-shepherd',
    },
    'profile': 'H',
    'payload': {
      'system_type': 'PLATFORM_STATUS',
      'state': state,
      'metrics': metrics,
    },
  };
}

// ---------------------------------------------------------------------------
// UDP emitter
// ---------------------------------------------------------------------------

/// Fire-and-forget UDP emitter for ZMeta events. Never throws into the
/// app: a down gateway must not disturb detection.
class ZMetaEmitter {
  ZMetaEmitter({required this.host, required this.port});

  final String host;
  final int port;

  RawDatagramSocket? _sock;

  /// Resolved destination, looked up ONCE per emitter lifetime — not
  /// per datagram. A hostname must not flap mid-session, and a
  /// per-datagram failure reads as silent data loss.
  InternetAddress? _dest;
  bool _resolved = false;

  bool _closed = false;

  Future<InternetAddress?> _resolve() async {
    if (_resolved) return _dest;
    _resolved = true;
    try {
      final addrs = await InternetAddress.lookup(host);
      if (addrs.isNotEmpty) _dest = addrs.first;
    } catch (_) {
      // Unresolvable: sends are dropped below, detection continues.
    }
    return _dest;
  }

  /// Sends one event as a single UDP datagram (the gateway's ingest
  /// format). Safe to call without awaiting; errors are swallowed.
  Future<void> send(Map<String, dynamic> event) async {
    if (_closed) return;
    try {
      _sock ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final dest = await _resolve();
      if (dest == null) return;
      final data = utf8.encode(jsonEncode(event));
      _sock!.send(data, dest, port);
    } catch (_) {
      // Emit-only: never let the export path break detection.
    }
  }

  void close() {
    _closed = true;
    try {
      _sock?.close();
    } catch (_) {}
    _sock = null;
  }
}
