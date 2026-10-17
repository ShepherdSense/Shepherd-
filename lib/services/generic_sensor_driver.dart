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
    final r = SensorProtocol.parseUdpJson(j);
    if (r.observation == null) {
      _malformed++;
      return;
    }
    _ingest(r.observation!, DateTime.now());
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
    if (_latest.length > maxSensors) {
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
  Future<bool> probe() async => true; // passive listener

  @override
  void dispose() => NodeUdpHub.release(_onDatagram);
}

// SEAM: at merge, wire into radio_driver.dart:
//   import 'generic_sensor_driver.dart';
//   case 'sensor': return GenericSensorDriver();
// and append to driverTypes:
//   (id: 'sensor', label: 'SENSOR BUS (lidar/acoustic/PIR/…)', implemented: true),
// No config address needed — the driver listens, sensors talk.
