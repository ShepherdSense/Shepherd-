/// Shepherd Sensor Protocol — the wire format for "if it can sense
/// something, it feeds Shepherd."
///
/// Two transports, one data model ([SensorObservation]):
///
/// 1. UART text lines (from a sensor wired to a node's serial port):
///      RANGE lidar1 12.4 45
///      RANGE tof1 3.2
///      BEARING micarray 137 0.8
///      SPECTRUM mic1 120:0.2,240:0.9,480:0.15
///      BINARY pir1 1
///      ENERGY rf1 -67
///      MOTION cam1 zone=3
///      MOTION cam1
///      WIND anem1 4.2 6.1          (wind_ms [gust_ms])
///    And the legacy form (still parsed, as ENERGY):
///      SENSOR <name> <rssi_dbm>
///
/// 2. UDP 49160 JSON (node → app, or anything → app):
///      {"type":"sensor_obs","obs":"RANGE","sensor":"lidar1",
///       "dist_m":12.4,"angle_deg":45,"lat":..,"lon":..}
///      {"type":"sensor_obs","obs":"CSI","sensor":"csi_ap_buffalo",
///       "dev_hz":12.4,"pairs_active":19,"path_loss_db":54.0,
///       "link":"ap:buffalo","wind_ms":1.8,"wind_gated":false,"t":..}
///      {"type":"sensor_obs","obs":"WIND","sensor":"anem_1",
///       "wind_ms":4.2,"gust_ms":6.1,"t":..}
///
/// The parser is LENIENT BY DESIGN: malformed lines are logged and
/// skipped, never thrown. A chatty broken sensor must not take down
/// the ingest path. [parseLine] and [parseUdpJson] never throw.
/// Unknown `obs` verbs are skipped per the §1c parser contract (a
/// future sensor must not break today's app).
///
/// Field reference (all numbers finite-checked; NaN/Inf rejected):
/// - RANGE:   <sensor> <dist_m> [angle_deg]
/// - BEARING: <sensor> <deg_0-360> [confidence_0-1, default 0.5]
/// - SPECTRUM:<sensor> <hz:mag,hz:mag,...>   (1..64 bins)
/// - BINARY:  <sensor> <0|1|true|false>
/// - ENERGY:  <sensor> <level_db>
/// - MOTION:  <sensor> [zone=<id>] [label=<text>]
/// - WIND:    <sensor> <wind_ms> [gust_ms]
/// - CSI:     UDP JSON only (see [CsiObservation])
library;

import '../models/sensor_observation.dart';

/// Result of parsing one wire message.
class SensorParseResult {
  const SensorParseResult(this.observation, this.warning);
  final SensorObservation? observation;

  /// Non-null when the line was malformed (observation is null then).
  /// For the log; throttled by the caller.
  final String? warning;
}

/// Result of parsing one CSI wire message.
class CsiParseResult {
  const CsiParseResult(this.observation, this.warning);
  final CsiObservation? observation;
  final String? warning;
}

/// Result of parsing one WIND wire message.
class WindParseResult {
  const WindParseResult(this.observation, this.warning);
  final WindObservation? observation;
  final String? warning;
}

/// CSI motion observation (esp32_csi_pipeline_spec.md).
///
/// One ESP32's WiFi-CSI motion channel: symmetric-subcarrier phase
/// averaging in firmware, Hz-deviation metric per 1 s window. This is
/// meters-class *disturbance on a link*, not a target at a coordinate —
/// tripwire, not radar. Never identity, never classification of what
/// moved; dev_hz bands are size-class heuristics with confidence.
class CsiObservation {
  const CsiObservation({
    required this.sensorId,
    required this.timestamp,
    required this.devHz,
    this.pairsActive,
    this.pathLossDb,
    this.link,
    this.windMs,
    this.windGated = true,
    this.sensorLat,
    this.sensorLon,
  });

  final String sensorId;
  final DateTime timestamp;

  /// Hz-deviation of the averaged phase time series (req).
  final double devHz;

  /// Subcarrier pairs above the noise floor (opt).
  final int? pairsActive;

  /// Firmware's path-loss estimate in dB (opt — the app re-derives).
  final double? pathLossDb;

  /// AP/link id the motion is attributed to (opt).
  final String? link;

  /// Local wind at the node, m/s (opt).
  final double? windMs;

  /// True when this window's motion claim was suppressed by the wind
  /// gate. Defaults true (fail-safe): without wind data the feature is
  /// OFF, not degraded.
  final bool windGated;

  final double? sensorLat;
  final double? sensorLon;

  /// Staleness horizon: 30 s (ENERGY-class cadence).
  static const Duration stalenessHorizon = Duration(seconds: 30);

  bool get isStale =>
      DateTime.now().difference(timestamp) > stalenessHorizon;

  bool isStaleAt(DateTime now) =>
      now.difference(timestamp) > stalenessHorizon;

  /// Size-class band from the paper's outdoor operating points —
  /// starting estimates to field-calibrate, not constants.
  CsiBand get band {
    if (devHz < 3) return CsiBand.noise;
    if (devHz < 10) return CsiBand.smallMover;
    if (devHz < 30) return CsiBand.personAnimal;
    return CsiBand.vehicleClass;
  }
}

/// CSI Hz-deviation bands (heuristic size classes, never identities).
enum CsiBand {
  /// < 3 Hz: below the paper's bird floor — noise; no claim.
  noise,

  /// 3–10 Hz: small-mover band (crow-class ~5 Hz).
  smallMover,

  /// 10–30 Hz: person/animal class.
  personAnimal,

  /// > 30 Hz: vehicle-class intrusion (paper's SUV floor).
  vehicleClass,
}

/// Wind observation (anemometer module / operator gate / weather API).
class WindObservation {
  const WindObservation({
    required this.sensorId,
    required this.timestamp,
    required this.windMs,
    this.gustMs,
    this.sensorLat,
    this.sensorLon,
  });

  final String sensorId;
  final DateTime timestamp;

  /// Wind speed, m/s (req).
  final double windMs;

  /// Gust speed, m/s (opt).
  final double? gustMs;

  final double? sensorLat;
  final double? sensorLon;

  /// Staleness horizon: 5 min (weather changes slowly; a stale wind
  /// reading fails safe to wind_gated).
  static const Duration stalenessHorizon = Duration(minutes: 5);

  bool get isStale =>
      DateTime.now().difference(timestamp) > stalenessHorizon;

  /// Suzuki's gate: motion claims suppressed at/above 3.5 m/s.
  bool get exceedsGate => windMs >= 3.5;
}

class SensorProtocol {
  /// Parse one UART text line. Never throws.
  static SensorParseResult parseLine(String line, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) {
      return const SensorParseResult(null, null); // comment/blank: silent
    }
    try {
      return SensorParseResult(_parseInner(t, now), null);
    } catch (e) {
      return SensorParseResult(null, 'unparseable sensor line: "$t" ($e)');
    }
  }

  static SensorObservation? _parseInner(String t, DateTime now) {
    final parts = t.split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    final verb = parts[0].toUpperCase();

    // Legacy form: SENSOR <name> <rssi_dbm> → ENERGY.
    if (verb == 'SENSOR') {
      if (parts.length < 3) return null;
      final level = _finite(parts[2]);
      if (level == null) return null;
      return SensorObservation(
        type: SensorObsType.energy,
        sensorId: _id(parts[1]),
        timestamp: now,
        levelDb: level,
      );
    }

    if (parts.length < 2) return null;
    final id = _id(parts[1]);
    if (id.isEmpty) return null;

    switch (verb) {
      case 'RANGE':
        if (parts.length < 3) return null;
        final d = _finite(parts[2]);
        if (d == null || d <= 0 || d > 100000) return null;
        double? angle;
        if (parts.length >= 4) {
          angle = _finite(parts[3]);
          if (angle == null) return null;
          angle = angle % 360;
        }
        return SensorObservation(
          type: SensorObsType.range,
          sensorId: id,
          timestamp: now,
          distanceM: d,
          angleDeg: angle,
        );
      case 'BEARING':
        if (parts.length < 3) return null;
        final b = _finite(parts[2]);
        if (b == null) return null;
        var conf = 0.5;
        if (parts.length >= 4) {
          final c = _finite(parts[3]);
          if (c == null) return null;
          conf = c.clamp(0.0, 1.0).toDouble();
        }
        return SensorObservation(
          type: SensorObsType.bearing,
          sensorId: id,
          timestamp: now,
          bearingDeg: b % 360,
          confidence: conf,
        );
      case 'SPECTRUM':
        if (parts.length < 3) return null;
        final freqs = <double>[];
        final mags = <double>[];
        for (final bin in parts[2].split(',')) {
          final kv = bin.split(':');
          if (kv.length != 2) return null;
          final f = _finite(kv[0]);
          final m = _finite(kv[1]);
          if (f == null || m == null || f <= 0) return null;
          freqs.add(f);
          mags.add(m);
          if (freqs.length > 64) return null;
        }
        if (freqs.isEmpty) return null;
        return SensorObservation(
          type: SensorObsType.spectrum,
          sensorId: id,
          timestamp: now,
          freqHz: freqs,
          magnitudes: mags,
        );
      case 'BINARY':
        if (parts.length < 3) return null;
        final v = parts[2].toLowerCase();
        final on = v == '1' || v == 'true';
        final off = v == '0' || v == 'false';
        if (!on && !off) return null;
        return SensorObservation(
          type: SensorObsType.binary,
          sensorId: id,
          timestamp: now,
          triggered: on,
        );
      case 'ENERGY':
        if (parts.length < 3) return null;
        final level = _finite(parts[2]);
        if (level == null) return null;
        return SensorObservation(
          type: SensorObsType.energy,
          sensorId: id,
          timestamp: now,
          levelDb: level,
        );
      case 'MOTION':
        String? zone;
        String? label;
        for (final kv in parts.skip(2)) {
          final i = kv.indexOf('=');
          if (i <= 0) continue;
          final k = kv.substring(0, i).toLowerCase();
          final v = kv.substring(i + 1);
          if (v.isEmpty) continue;
          if (k == 'zone') {
            zone = v;
          } else if (k == 'label') {
            label = v;
          }
        }
        return SensorObservation(
          type: SensorObsType.motion,
          sensorId: id,
          timestamp: now,
          zone: zone,
          zoneLabel: label,
        );
      case 'WIND':
        // WIND has its own typed model (not a SensorObservation); the
        // UART path surfaces it via parseWindLine. Here: skip silently
        // so the generic sensor-bus parser doesn't call it malformed.
        return null;
      default:
        return null;
    }
  }

  /// Parse one UDP JSON datagram body. Never throws.
  ///
  /// Accepted shapes:
  ///   {"type":"sensor_obs","obs":"RANGE","sensor":"lidar1",
  ///    "dist_m":12.4,"angle_deg":45,"lat":..,"lon":..}
  /// The "t" field (unix seconds) overrides the receive time when
  /// present and sane; otherwise receive time is used.
  static SensorParseResult parseUdpJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    final now = receivedAt ?? DateTime.now();
    try {
      return SensorParseResult(_parseUdpInner(j, now), null);
    } catch (e) {
      return SensorParseResult(null, 'unparseable sensor_obs JSON ($e)');
    }
  }

  static SensorObservation? _parseUdpInner(
      Map<String, dynamic> j, DateTime now) {
    if ('${j['type']}' != 'sensor_obs') return null;
    final obs = '${j['obs']}'.toUpperCase();
    final id = _id('${j['sensor'] ?? ''}');
    if (id.isEmpty) return null;

    DateTime ts = now;
    final t = j['t'];
    if (t is num && t.isFinite && t > 946684800 && t < 4102444800) {
      ts = DateTime.fromMillisecondsSinceEpoch((t * 1000).round(),
          isUtc: true);
    }
    double? lat, lon;
    final la = j['lat'];
    final lo = j['lon'];
    if (la is num && lo is num && la.isFinite && lo.isFinite) {
      if (la.abs() <= 90 && lo.abs() <= 180 && (la != 0 || lo != 0)) {
        lat = la.toDouble();
        lon = lo.toDouble();
      }
    }

    double? fin(String k) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    switch (obs) {
      case 'RANGE':
        final d = fin('dist_m');
        if (d == null || d <= 0 || d > 100000) return null;
        final a = fin('angle_deg');
        return SensorObservation(
          type: SensorObsType.range,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          distanceM: d,
          angleDeg: a == null ? null : a % 360,
        );
      case 'BEARING':
        final b = fin('bearing_deg') ?? fin('deg');
        if (b == null) return null;
        return SensorObservation(
          type: SensorObsType.bearing,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          bearingDeg: b % 360,
          confidence:
              (fin('confidence') ?? 0.5).clamp(0.0, 1.0).toDouble(),
        );
      case 'SPECTRUM':
        final f = j['freq_hz'];
        final m = j['magnitudes'];
        if (f is! List || m is! List || f.isEmpty) return null;
        final freqs = <double>[];
        final mags = <double>[];
        for (var i = 0; i < f.length && i < m.length && i < 64; i++) {
          final ff = f[i];
          final mm = m[i];
          if (ff is! num || mm is! num) return null;
          if (!ff.isFinite || !mm.isFinite || ff <= 0) return null;
          freqs.add(ff.toDouble());
          mags.add(mm.toDouble());
        }
        if (freqs.isEmpty) return null;
        return SensorObservation(
          type: SensorObsType.spectrum,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          freqHz: freqs,
          magnitudes: mags,
        );
      case 'BINARY':
        final v = j['triggered'];
        final on = v == true || v == 1 || '${j['value']}' == '1';
        final off = v == false || v == 0 || '${j['value']}' == '0';
        if (!on && !off) return null;
        return SensorObservation(
          type: SensorObsType.binary,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          triggered: on,
        );
      case 'ENERGY':
        final level = fin('level_db') ?? fin('rssi_dbm');
        if (level == null) return null;
        return SensorObservation(
          type: SensorObsType.energy,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          levelDb: level,
        );
      case 'MOTION':
        return SensorObservation(
          type: SensorObsType.motion,
          sensorId: id,
          timestamp: ts,
          sensorLat: lat,
          sensorLon: lon,
          zone: j['zone'] is String && (j['zone'] as String).isNotEmpty
              ? '${j['zone']}'
              : null,
          zoneLabel:
              j['zone_label'] is String && (j['zone_label'] as String).isNotEmpty
                  ? '${j['zone_label']}'
                  : null,
        );
      default:
        return null;
    }
  }

  /// Serialize an observation to its UDP JSON form (for node firmware
  /// and bridges speaking back to the app).
  static Map<String, dynamic> toUdpJson(SensorObservation o) {
    final j = <String, dynamic>{
      'type': 'sensor_obs',
      'obs': o.type.name.toUpperCase(),
      'sensor': o.sensorId,
      't': o.timestamp.toUtc().millisecondsSinceEpoch / 1000.0,
    };
    if (o.sensorLat != null && o.sensorLon != null) {
      j['lat'] = o.sensorLat;
      j['lon'] = o.sensorLon;
    }
    switch (o.type) {
      case SensorObsType.range:
        j['dist_m'] = o.distanceM;
        if (o.angleDeg != null) j['angle_deg'] = o.angleDeg;
      case SensorObsType.bearing:
        j['bearing_deg'] = o.bearingDeg;
        j['confidence'] = o.confidence;
      case SensorObsType.spectrum:
        j['freq_hz'] = o.freqHz;
        j['magnitudes'] = o.magnitudes;
      case SensorObsType.binary:
        j['triggered'] = o.triggered;
      case SensorObsType.energy:
        j['level_db'] = o.levelDb;
      case SensorObsType.motion:
        if (o.zone != null) j['zone'] = o.zone;
        if (o.zoneLabel != null) j['zone_label'] = o.zoneLabel;
    }
    return j;
  }

  /// Serialize to the UART text form (for documentation / loopback).
  static String toLine(SensorObservation o) {
    switch (o.type) {
      case SensorObsType.range:
        return 'RANGE ${o.sensorId} ${_n(o.distanceM)}'
            '${o.angleDeg != null ? ' ${_n(o.angleDeg)}' : ''}';
      case SensorObsType.bearing:
        return 'BEARING ${o.sensorId} ${_n(o.bearingDeg)} '
            '${o.confidence.toStringAsFixed(2)}';
      case SensorObsType.spectrum:
        final bins = [
          for (var i = 0;
              i < o.freqHz.length && i < o.magnitudes.length;
              i++)
            '${_n(o.freqHz[i])}:${_n(o.magnitudes[i])}'
        ].join(',');
        return 'SPECTRUM ${o.sensorId} $bins';
      case SensorObsType.binary:
        return 'BINARY ${o.sensorId} ${o.triggered == true ? 1 : 0}';
      case SensorObsType.energy:
        return 'ENERGY ${o.sensorId} ${_n(o.levelDb)}';
      case SensorObsType.motion:
        var s = 'MOTION ${o.sensorId}';
        if (o.zone != null) s += ' zone=${o.zone}';
        if (o.zoneLabel != null) s += ' label=${o.zoneLabel}';
        return s;
    }
  }

  /// True for `obs` verbs this app understands (sensor bus + CSI +
  /// WIND). Unknown verbs are SKIPPED per the §1c parser contract — a
  /// future sensor must not break today's app, and an unknown verb is
  /// not a malformed message.
  static bool isKnownVerb(String obs) {
    switch (obs.toUpperCase()) {
      case 'RANGE':
      case 'BEARING':
      case 'SPECTRUM':
      case 'BINARY':
      case 'ENERGY':
      case 'MOTION':
      case 'CSI':
      case 'WIND':
        return true;
      default:
        return false;
    }
  }

  /// Parse one UDP JSON CSI observation. Never throws.
  ///
  ///   {"type":"sensor_obs","obs":"CSI","sensor":"csi_ap_buffalo",
  ///    "dev_hz":12.4,"pairs_active":19,"path_loss_db":54.0,
  ///    "link":"ap:buffalo","wind_ms":1.8,"wind_gated":false,"t":..}
  ///
  /// `wind_gated` defaults TRUE (fail-safe): without wind data the CSI
  /// motion features are OFF, not degraded.
  static CsiParseResult parseCsiUdpJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    final now = receivedAt ?? DateTime.now();
    try {
      return CsiParseResult(_parseCsiInner(j, now), null);
    } catch (e) {
      return CsiParseResult(null, 'unparseable CSI sensor_obs JSON ($e)');
    }
  }

  static CsiObservation? _parseCsiInner(
      Map<String, dynamic> j, DateTime now) {
    if ('${j['type']}' != 'sensor_obs') return null;
    if ('${j['obs']}'.toUpperCase() != 'CSI') return null;
    final id = _id('${j['sensor'] ?? ''}');
    if (id.isEmpty) return null;
    final dev = j['dev_hz'];
    if (dev is! num || !dev.isFinite || dev < 0) return null;

    DateTime ts = now;
    final t = j['t'];
    if (t is num && t.isFinite && t > 946684800 && t < 4102444800) {
      ts = DateTime.fromMillisecondsSinceEpoch((t * 1000).round(),
          isUtc: true);
    }
    double? lat, lon;
    final la = j['lat'];
    final lo = j['lon'];
    if (la is num && lo is num && la.isFinite && lo.isFinite) {
      if (la.abs() <= 90 && lo.abs() <= 180 && (la != 0 || lo != 0)) {
        lat = la.toDouble();
        lon = lo.toDouble();
      }
    }
    double? fin(String k) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final pairs = j['pairs_active'];
    final link = j['link'];
    final wg = j['wind_gated'];
    return CsiObservation(
      sensorId: id,
      timestamp: ts,
      devHz: dev.toDouble(),
      pairsActive: pairs is num ? pairs.toInt() : null,
      pathLossDb: fin('path_loss_db'),
      link: link is String && link.isNotEmpty ? link : null,
      windMs: fin('wind_ms'),
      // Fail-safe default: unknown wind ⇒ gated.
      windGated: wg is bool ? wg : true,
      sensorLat: lat,
      sensorLon: lon,
    );
  }

  /// Parse one UDP JSON WIND observation. Never throws.
  ///
  ///   {"type":"sensor_obs","obs":"WIND","sensor":"anem_1",
  ///    "wind_ms":4.2,"gust_ms":6.1,"t":..}
  static WindParseResult parseWindUdpJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    final now = receivedAt ?? DateTime.now();
    try {
      return WindParseResult(_parseWindInner(j, now), null);
    } catch (e) {
      return WindParseResult(null, 'unparseable WIND sensor_obs JSON ($e)');
    }
  }

  static WindObservation? _parseWindInner(
      Map<String, dynamic> j, DateTime now) {
    if ('${j['type']}' != 'sensor_obs') return null;
    if ('${j['obs']}'.toUpperCase() != 'WIND') return null;
    final id = _id('${j['sensor'] ?? ''}');
    if (id.isEmpty) return null;
    final w = j['wind_ms'];
    if (w is! num || !w.isFinite || w < 0 || w > 150) return null;

    DateTime ts = now;
    final t = j['t'];
    if (t is num && t.isFinite && t > 946684800 && t < 4102444800) {
      ts = DateTime.fromMillisecondsSinceEpoch((t * 1000).round(),
          isUtc: true);
    }
    double? lat, lon;
    final la = j['lat'];
    final lo = j['lon'];
    if (la is num && lo is num && la.isFinite && lo.isFinite) {
      if (la.abs() <= 90 && lo.abs() <= 180 && (la != 0 || lo != 0)) {
        lat = la.toDouble();
        lon = lo.toDouble();
      }
    }
    final g = j['gust_ms'];
    return WindObservation(
      sensorId: id,
      timestamp: ts,
      windMs: w.toDouble(),
      gustMs: g is num && g.isFinite ? g.toDouble() : null,
      sensorLat: lat,
      sensorLon: lon,
    );
  }

  /// Parse one UART WIND line: `WIND <name> <wind_ms> [gust_ms]`.
  /// Never throws.
  static WindParseResult parseWindLine(String line, {DateTime? at}) {
    final now = at ?? DateTime.now();
    try {
      final t = line.trim();
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 3 || parts[0].toUpperCase() != 'WIND') {
        return const WindParseResult(null, null);
      }
      final id = _id(parts[1]);
      final w = _finite(parts[2]);
      if (id.isEmpty || w == null || w < 0 || w > 150) {
        return WindParseResult(
            null, 'unparseable WIND line: "$t"');
      }
      double? gust;
      if (parts.length >= 4) {
        gust = _finite(parts[3]);
        if (gust == null) {
          return WindParseResult(null, 'unparseable WIND line: "$t"');
        }
      }
      return WindParseResult(
        WindObservation(
            sensorId: id, timestamp: now, windMs: w, gustMs: gust),
        null,
      );
    } catch (e) {
      return WindParseResult(null, 'unparseable WIND line ($e)');
    }
  }

  static String _id(String s) {
    final t = s.trim();
    if (t.length > 48) return t.substring(0, 48);
    return t;
  }

  static double? _finite(String s) {
    final v = double.tryParse(s.trim());
    return (v != null && v.isFinite) ? v : null;
  }

  static String _n(double? v) {
    if (v == null || !v.isFinite) return '0';
    return v.toStringAsFixed(v.abs() < 1000 && v != v.roundToDouble()
        ? 2
        : 0);
  }
}
