/// Shepherd → ZMeta event adapter (emit-only).
///
/// Translates Shepherd detections into ZMeta v1.0 events and ships them
/// over UDP to a ZMeta gateway (default 127.0.0.1:5555 — the gateway's
/// ingest port). One adapter runs per Shepherd mesh; the gateway fuses
/// across meshes. Shepherd never receives anything back: this is the
/// same emit-only posture as the ATAK CoT output path.
///
/// Event mapping:
///   tripwire CrossingEvent  → OBSERVATION_EVENT / RF
///   AI classifier label     → INFERENCE_EVENT / CLASSIFICATION
///   (radio health           → SYSTEM_EVENT / LINK_STATUS — planned)
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
/// - Original observations carry no `lineage` block (no ZMeta parent
///   exists); the INFERENCE carries a genuine `based_on` link to its
///   observation.
///
/// Pure Dart — no Flutter imports — so it stays unit-testable.
library zmeta_adapter;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// ZMeta spec lane this adapter targets.
const String kZmetaVersion = '1.0';

/// Default ZMeta gateway ingest endpoint (their reference gateway
/// listens on UDP 0.0.0.0:5555).
const String kZmetaDefaultHost = '127.0.0.1';
const int kZmetaDefaultPort = 5555;

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
  };

  final quality = <String, dynamic>{
    'calibration_state': 'UNCALIBRATED',
    'shepherd_estimates': true, // dip/size/duration are heuristic estimates
    // Consumer-visible sentinel flag: power_dbm is the documented
    // "not measured" sentinel, not 1 mW of received power.
    'shepherd_power_sentinel': true,
    'geo_status': 'UNAVAILABLE',
  };

  final tsZ = zmetaUtcZ(ts);
  final payload = <String, dynamic>{
    'modality': 'RF',
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

  // v1.0 geo is all-or-nothing (needs WGS-84 HAE altitude). Shepherd's
  // node positions are 2-D fixes, so canonical geo is omitted rather
  // than zero-filled; the sensor is identified by
  // source.platform_id + source.sensor_id.

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
  bool _closed = false;

  /// Sends one event as a single UDP datagram (the gateway's ingest
  /// format). Safe to call without awaiting; errors are swallowed.
  Future<void> send(Map<String, dynamic> event) async {
    if (_closed) return;
    try {
      _sock ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final data = utf8.encode(jsonEncode(event));
      _sock!.send(data, InternetAddress(host), port);
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
