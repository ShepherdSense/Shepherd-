/// Generic sensor-bus driver: "if it can sense something, it feeds
/// Shepherd."
///
/// Listens on the shared UDP 49160 hub ([NodeUdpHub]) for
/// `{"type":"sensor_obs",...}` datagrams (see [SensorProtocol]) and
/// ingests them into a bounded in-memory observation store. Zero
/// config — sensors just start talking.
///
/// Two downstream paths:
/// 1. Observations: [observationsSince] / [latestPerSensor] feed the
///    map overlay, the evidence view, tracker corroboration, and (for
///    ACOUSTIC/EO types) ZMeta export. SEAM: at merge, app_state calls
///    these from the evidence/triage path.
/// 2. Virtual tripwire links: ENERGY and BINARY observations ALSO emit
///    [LinkSample]s so the existing adaptive tripwire fires on them
///    with no new detection code:
///      `sensor:<id> → sensor:<id>:energy`  (snr = level, baseline learns it)
///      `sensor:<id> → sensor:<id>:binary`  (snr = 0 quiet / −20 triggered)
///    SEAM: at merge, exclude `sensor:` links from geometric fusion in
///    app_state (same treatment as `sdr:`/`esp32:` links — they carry
///    no link geometry).
///
/// HONEST SCOPE: a virtual link is the SENSOR's reported value
/// re-detected by Shepherd's tripwire — threshold and classification
/// are Shepherd's, the measurement is the sensor's. PIR-class binary
/// sensors are crude presence hints, not identification.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/link_sample.dart';
import '../models/sensor_observation.dart';
import 'node_udp_hub.dart';
import 'radio_driver.dart';
import 'sensor_protocol.dart';

class GenericSensorDriver extends RadioDriver {
  GenericSensorDriver();

  /// Bounded store: newest last. Pruned by age on every poll.
  final List<SensorObservation> _store = [];

  /// sensorId → latest observation (any type).
  final Map<String, SensorObservation> _latest = {};

  /// sensorId → last BINARY triggered state (for virtual-link output).
  final Map<String, bool> _binaryState = {};

  /// sensorId → last ENERGY level (for virtual-link output).
  final Map<String, double> _energyLevel = {};

  // ---- CSI motion pipeline (esp32_csi_pipeline_spec.md) ----
  //
  // Per-link CSI health gates live here (app-side), NOT in the
  // firmware: the decision inputs already exist here and the
  // computation is trivial. CSI is corroboration-only — it never
  // creates virtual tripwire links, so gating can NEVER remove the
  // RSSI tripwire (regression-prohibited by construction).

  /// sensorId → latest CSI motion observation.
  final Map<String, CsiObservation> _csi = {};

  /// sensorId → latest wind observation.
  final Map<String, WindObservation> _wind = {};

  /// sensorId → last evaluated CSI gate state (for flip events).
  final Map<String, bool> _csiGateState = {};

  /// Human-readable gate-flip events, newest last (bounded). The
  /// dashboard shows these so an operator sees WHY a node's CSI
  /// channel went quiet — "LINK GATED: path loss 63 dB" beats a
  /// silent feature.
  final List<String> csiGateEvents = [];
  static const int maxCsiGateEvents = 50;

  /// Conservative CSI path-loss gate (dB). The 60 dB knee was
  /// cable-conducted on better silicon with no multipath; the ESP32
  /// field knee will be worse. 5 dB safety margin until measured —
  /// narrowing it is field-test follow-up work.
  static const double csiPathLossGateDb = 55.0;

  /// Cross-link imbalance gate (dB): the multi-path analogue of the
  /// paper's >10 dB inter-chain rule. Spread between the strongest
  /// and weakest live CSI link beyond this disables the weak link's
  /// CSI features. (Documented caveat: the single-chain ESP32 has no
  /// on-node inter-chain imbalance; this is the cross-link analogue
  /// that protects the pipeline where multiple receive paths meet.)
  static const double csiImbalanceGateDb = 10.0;

  /// Suzuki's wind gate (m/s): vegetation flutter dominates above this.
  static const double csiWindGateMs = 3.5;

  int _malformed = 0;
  int _ingested = 0;

  /// Max observations kept; oldest evicted first.
  static const int maxStored = 500;

  /// Max distinct sensors tracked in [_latest] (and the virtual-link
  /// state derived from it). Bounds memory when a broken sensor spams
  /// random IDs; oldest-seen evicted first.
  static const int maxSensors = 200;

  /// Observations older than this are pruned (they're history, and
  /// the recorder owns history).
  static const Duration maxAge = Duration(minutes: 10);

  @override
  String get driverId => 'sensor';

  @override
  String get label => 'SENSOR BUS';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'Listening on UDP 49160 — no sensor_obs datagrams yet. Sensors '
      'speak {"type":"sensor_obs",...} (see docs/sensor_protocol_spec.md).';

  @override
  Duration? get sampleMaxAge => const Duration(seconds: 90);

  int get ingestedCount => _ingested;
  int get malformedCount => _malformed;

  /// All observations at/after [ts], oldest first.
  List<SensorObservation> observationsSince(DateTime ts) => [
        for (final o in _store)
          if (!o.timestamp.isBefore(ts)) o
      ];

  /// Latest observation per sensor id (read-only view).
  Map<String, SensorObservation> latestPerSensor() => Map.of(_latest);

  /// Test hook: feed one observation directly.
  @visibleForTesting
  void ingestForTest(SensorObservation o) => _ingest(o, DateTime.now());

  /// Test hook: feed one raw UDP datagram body.
  @visibleForTesting
  void datagramForTest(String text) => _onDatagram(text);

  @override
  Future<List<LinkSample>> poll() async {
    await NodeUdpHub.ensureListening(_onDatagram);
    _prune();
    _refreshCsiGates(DateTime.now());
    final now = DateTime.now();
    final out = <LinkSample>[];
    for (final e in _energyLevel.entries) {
      out.add(LinkSample(
        timestamp: now,
        fromNode: 'sensor:${e.key}',
        toNode: 'sensor:${e.key}:energy',
        snr: e.value,
      ));
    }
    for (final e in _binaryState.entries) {
      out.add(LinkSample(
        timestamp: now,
        fromNode: 'sensor:${e.key}',
        toNode: 'sensor:${e.key}:binary',
        // Quiet sits at 0 (baseline learns it); a trigger reads as a
        // −20 dB-style dip the adaptive threshold fires on.
        snr: e.value ? -20.0 : 0.0,
      ));
    }
    return out;
  }

  void _onDatagram(String text) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return; // not JSON / not ours; other drivers' traffic passes by
    }
    if ('${j['type']}' != 'sensor_obs') return;
    final obs = '${j['obs'] ?? ''}';
    // CSI / WIND verbs: typed ingest (additive). Unknown verbs are
    // skipped per the §1c parser contract — never counted malformed.
    if (obs.toUpperCase() == 'CSI') {
      final r = SensorProtocol.parseCsiUdpJson(j);
      if (r.observation == null) {
        _malformed++;
        return;
      }
      _ingestCsi(r.observation!, DateTime.now());
      return;
    }
    if (obs.toUpperCase() == 'WIND') {
      final r = SensorProtocol.parseWindUdpJson(j);
      if (r.observation == null) {
        _malformed++;
        return;
      }
      _ingestWind(r.observation!, DateTime.now());
      return;
    }
    if (!SensorProtocol.isKnownVerb(obs)) return; // future sensor: skip
    final r = SensorProtocol.parseUdpJson(j);
    if (r.observation == null) {
      _malformed++;
      return;
    }
    _ingest(r.observation!, DateTime.now());
  }

  /// Test hook: feed one CSI observation directly (gates are
  /// evaluated as of the observation's own timestamp).
  @visibleForTesting
  void ingestCsiForTest(CsiObservation o) => _ingestCsi(o, o.timestamp);

  /// Test hook: feed one WIND observation directly (gates are
  /// evaluated as of the observation's own timestamp).
  @visibleForTesting
  void ingestWindForTest(WindObservation o) =>
      _ingestWind(o, o.timestamp);

  void _ingestCsi(CsiObservation o, DateTime now) {
    _ingested++;
    _csi[o.sensorId] = o;
    _refreshCsiGates(now);
  }

  void _ingestWind(WindObservation o, DateTime now) {
    _ingested++;
    _wind[o.sensorId] = o;
    _refreshCsiGates(now);
  }

  /// Latest CSI observation per sensor (read-only view).
  Map<String, CsiObservation> latestCsi() => Map.of(_csi);

  /// Latest wind observation per sensor (read-only view).
  Map<String, WindObservation> latestWind() => Map.of(_wind);

  /// CSI observations fresher than the 30 s staleness horizon.
  List<CsiObservation> liveCsiObservations(DateTime now) => [
        for (final o in _csi.values)
          if (!o.isStaleAt(now)) o
      ];

  /// Per-link CSI health verdict: enabled only when the path-loss
  /// gate, the imbalance gate, and the wind gate all pass. Any gate
  /// failure forces the merger weight to exactly 0 (the AV-FDTI
  /// zero-weight case) — the RSSI tripwire is unaffected.
  CsiLinkHealth csiHealthFor(String sensorId, DateTime now) {
    final o = _csi[sensorId];
    if (o == null) {
      return const CsiLinkHealth(
          enabled: false, reason: 'no CSI observation');
    }
    if (o.isStaleAt(now)) {
      return const CsiLinkHealth(enabled: false, reason: 'stale');
    }
    // Wind gate (load-bearing, not cosmetic): without wind data the
    // feature is OFF, not degraded.
    final wind = o.windMs ?? _freshestWindMs(now);
    if (wind == null) {
      return const CsiLinkHealth(
          enabled: false, reason: 'no wind source (fail-safe)');
    }
    if (o.windGated || wind >= csiWindGateMs) {
      return CsiLinkHealth(
          enabled: false,
          reason:
              'wind gated (${wind.toStringAsFixed(1)} m/s ≥ $csiWindGateMs m/s)');
    }
    // Path-loss gate (conservative 55 dB default).
    final pl = o.pathLossDb;
    if (pl == null || !pl.isFinite) {
      return const CsiLinkHealth(
          enabled: false, reason: 'path loss unknown');
    }
    if (pl > csiPathLossGateDb) {
      return CsiLinkHealth(
          enabled: false,
          reason:
              'path loss ${pl.toStringAsFixed(1)} dB > $csiPathLossGateDb dB');
    }
    // Imbalance gate: weak links in a >10 dB spread are untrustworthy.
    final spread = _csiLevelSpread(now);
    if (spread != null && pl > spread.min + csiImbalanceGateDb) {
      return CsiLinkHealth(
          enabled: false,
          reason:
              'imbalance spread ${spread.range.toStringAsFixed(1)} dB > $csiImbalanceGateDb dB');
    }
    return const CsiLinkHealth(enabled: true, reason: 'ok');
  }

  /// Freshest wind reading across all wind sensors within the 5 min
  /// horizon, or null when there is no wind source.
  double? _freshestWindMs(DateTime now) {
    double? best;
    DateTime? bestAt;
    for (final w in _wind.values) {
      if (now.difference(w.timestamp) > WindObservation.stalenessHorizon) {
        continue;
      }
      if (bestAt == null || w.timestamp.isAfter(bestAt)) {
        bestAt = w.timestamp;
        best = w.windMs;
      }
    }
    return best;
  }

  /// (min, range) of live path-loss estimates across CSI sensors, or
  /// null with fewer than 2 live readings.
  ({double min, double range})? _csiLevelSpread(DateTime now) {
    final pls = <double>[];
    for (final o in _csi.values) {
      if (o.isStaleAt(now)) continue;
      final pl = o.pathLossDb;
      if (pl != null && pl.isFinite) pls.add(pl);
    }
    if (pls.length < 2) return null;
    final lo = pls.reduce((a, b) => a < b ? a : b);
    final hi = pls.reduce((a, b) => a > b ? a : b);
    return (min: lo, range: hi - lo);
  }

  /// Re-evaluate every CSI gate; emit a health event on each flip so
  /// the operator sees why a channel went quiet.
  void _refreshCsiGates(DateTime now) {
    for (final id in _csi.keys) {
      final h = csiHealthFor(id, now);
      final prev = _csiGateState[id];
      if (prev == null) {
        _csiGateState[id] = h.enabled;
        continue; // first sighting: no flip to report
      }
      if (prev != h.enabled) {
        _csiGateState[id] = h.enabled;
        _gateEvent(h.enabled
            ? 'LINK UNGATED: $id — ${h.reason}'
            : 'LINK GATED: $id — ${h.reason}');
      }
    }
    _csiGateState.removeWhere((k, _) => !_csi.containsKey(k));
  }

  void _gateEvent(String msg) {
    csiGateEvents.add(msg);
    if (csiGateEvents.length > maxCsiGateEvents) {
      csiGateEvents.removeRange(
          0, csiGateEvents.length - maxCsiGateEvents);
    }
  }

  void _ingest(SensorObservation o, DateTime now) {
    _ingested++;
    _store.add(o);
    if (_store.length > maxStored) {
      _store.removeRange(0, _store.length - maxStored);
    }
    _latest[o.sensorId] = o;
    switch (o.type) {
      case SensorObsType.energy:
        final l = o.levelDb;
        if (l != null && l.isFinite) _energyLevel[o.sensorId] = l;
      case SensorObsType.binary:
        if (o.triggered != null) _binaryState[o.sensorId] = o.triggered!;
      case SensorObsType.range:
      case SensorObsType.bearing:
      case SensorObsType.spectrum:
      case SensorObsType.motion:
        break;
    }
    _pruneAt(now);
  }

  void _prune() => _pruneAt(DateTime.now());

  void _pruneAt(DateTime now) {
    final cutoff = now.subtract(maxAge);
    _store.removeWhere((o) => o.timestamp.isBefore(cutoff));
    _latest.removeWhere((_, o) => o.timestamp.isBefore(cutoff));
    // CSI (30 s) and WIND (5 min) have their own staleness horizons —
    // prune on those, not the 10 min store horizon.
    _csi.removeWhere((_, o) => o.isStaleAt(now));
    _wind.removeWhere(
        (_, w) => now.difference(w.timestamp) > WindObservation.stalenessHorizon);
    _csiGateState.removeWhere((k, _) => !_csi.containsKey(k));    if (_latest.length > maxSensors) {
      final sorted = _latest.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      for (final e in sorted.take(_latest.length - maxSensors)) {
        _latest.remove(e.key);
      }
    }
    // Virtual-link state follows the store: a sensor silent past the
    // store horizon stops emitting links (no phantom sensors).
    _energyLevel.removeWhere((k, _) =>
        !_latest.containsKey(k) || _latest[k]!.type != SensorObsType.energy);
    _binaryState.removeWhere((k, _) =>
        !_latest.containsKey(k) || _latest[k]!.type != SensorObsType.binary);
  }

  @override
  Future<bool> probe() async {
    await NodeUdpHub.ensureListening(_onDatagram);
    return NodeUdpHub.isBound;
  }

  @override
  void dispose() => NodeUdpHub.release(_onDatagram);
}

/// Per-link CSI health verdict (esp32_csi_pipeline_spec.md §Stage 3).
class CsiLinkHealth {
  const CsiLinkHealth({required this.enabled, required this.reason});

  /// False ⇒ the merger weight is exactly 0 (AV-FDTI zero-weight
  /// case). The RSSI tripwire is never affected.
  final bool enabled;

  /// Human-readable why, for the gate-flip health events.
  final String reason;
}

// Wired into radio_driver.dart as driver id 'sensor'
// (driverTypes: 'SENSOR BUS (lidar / acoustic / PIR / …)').
// No config address needed — the driver listens, sensors talk.
