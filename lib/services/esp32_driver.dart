import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/link_sample.dart';
import 'node_udp_hub.dart';
import 'radio_driver.dart';

/// ESP32 node ingest driver (passive UDP listener).
///
/// Listens on UDP 49160 for the standard Shepherd node beacons and
/// events (see field_kit/esp32/shepherd_node/shepherd_node.ino):
///   beacon: {"type":"beacon","node":"SHN-XXXX",...,"lat":..,"lon":..}
///   event:  {"type":"event","node":"SHN-XXXX","sensor":"wifi",
///            "dur_s":5.2,"depth_db":6.1,"class":"PASSING","conf":0.7}
///
/// This covers BOTH node kinds with zero config: WiFi-direct
/// shepherd_nodes (broadcasting on their own AP) and lora_gateway
/// re-emits (the gateway rebroadcasts each LoRa node's beacon/event
/// with the original "SLN-XXXX" node id, so they appear as distinct
/// nodes here).
///
/// Event → LinkSample mapping: the node already ran its edge tripwire,
/// so the driver reconstructs the disturbance it reported — each
/// sensor gets a virtual link `esp32:<node> → esp32:<node>:<sensor>`
/// whose level sits at 0 and drops by depth_db for the event's
/// duration. The app tripwire then detects it with its own adaptive
/// threshold, exactly as if it had seen the raw dip. Node positions
/// come from beacon lat/lon via [meshPositions] (same hook as the
/// Meshtastic driver).
///
/// HONEST SCOPE: the app re-detects from the node's *reported* depth,
/// not raw samples — threshold and classification are Shepherd's, the
/// underlying measurement is the node's. Event classes are the node's
/// crude heuristics, shown as estimates.
class Esp32Driver extends RadioDriver {
  Esp32Driver();

  /// Node id → last beacon position.
  final Map<String, ({double lat, double lon})> _positions = {};

  /// Node/sensor identifiers: no ':' or whitespace, bounded length.
  static final RegExp _idOk = RegExp(r'^[A-Za-z0-9_.\-]{1,32}$');
  static const int maxNodes = 64;
  static const int maxSensorsPerNode = 8;
  static const int maxActive = 256;

  /// Node id → callsign broadcast in its beacon (status-page set).
  final Map<String, String> _callsigns = {};

  /// Callsigns heard in beacons, for AppState to merge (never
  /// overwriting a user-set callsign).
  Map<String, String> get beaconCallsigns => Map.unmodifiable(_callsigns);

  /// Node ids whose latest beacon carries `"calib": true` — nodes
  /// participating in the vacant-window calibration. A node
  /// mid-reboot (no flag, or flag false) must not contaminate the
  /// fit; the guided routine only trusts flagged nodes.
  final Set<String> calibNodes = {};

  /// Node id → sensor names from its beacon ("sensors" array).
  final Map<String, List<String>> _sensors = {};

  /// Node id → last beacon time (for pruning silent nodes).
  final Map<String, DateTime> _seenAt = {};

  /// "node:sensor" → active disturbance {depthDb, endsAt}.
  final Map<String, _Disturbance> _active = {};

  DateTime _lastBeaconAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  String get driverId => 'esp32';

  @override
  String get label => 'ESP32 NODE (UDP)';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint => NodeUdpHub.lastError != null
      ? 'Cannot listen for nodes: ${NodeUdpHub.lastError}'
      : 'Listening on UDP 49160 — no node beacons heard yet. Join the '
      'node AP (Shepherd-XXXX / Shepherd-LoRa-XXXX) on this device.';

  /// Beacons are slow (30 s); event evidence stays live briefly longer
  /// than the poller so a reconstructed dip isn't instantly stale.
  @override
  Duration? get sampleMaxAge => const Duration(seconds: 45);

  /// GPS positions for map placement, keyed by Shepherd node ID.
  Map<String, ({double lat, double lon})> meshPositions() =>
      Map.of(_positions);

  DateTime get lastBeaconAt => _lastBeaconAt;

  @override
  Future<List<LinkSample>> poll() async {
    await NodeUdpHub.ensureListening(_onDatagram);
    final now = DateTime.now();
    _active.removeWhere((_, d) => now.isAfter(d.endsAt));
    // Prune nodes silent > 5 min: node-LOSS, not phantom links.
    _seenAt.removeWhere((_, t) => now.difference(t) > const Duration(minutes: 5));
    _positions.removeWhere((k, _) => !_seenAt.containsKey(k));
    _callsigns.removeWhere((k, _) => !_seenAt.containsKey(k));
    _sensors.removeWhere((k, _) => !_seenAt.containsKey(k));
    calibNodes.removeWhere((k) => !_seenAt.containsKey(k));
    final out = <LinkSample>[];
    for (final e in _active.entries) {
      final parts = e.key.split(':');
      final node = parts[0];
      final sensor = parts.length > 1 ? parts[1] : 'unknown';
      out.add(LinkSample(
        timestamp: now,
        fromNode: 'esp32:$node',
        toNode: 'esp32:$node:$sensor',
        // Reconstructed dip: the node's reported depth, as a level
        // drop from the 0 baseline the tripwire will learn.
        snr: -e.value.depthDb,
      ));
    }
    // Quiet sensors still report: a flat 0 keeps the link (and its
    // node on the map) alive without tripping anything.
    for (final node in _sensors.entries) {
      for (final sensor in node.value) {
        final key = '${node.key}:$sensor';
        if (!_active.containsKey(key)) {
          out.add(LinkSample(
            timestamp: now,
            fromNode: 'esp32:${node.key}',
            toNode: 'esp32:${node.key}:$sensor',
            snr: 0.0,
          ));
        }
      }
    }
    return out;
  }

  void _onDatagram(String text) {
    try {
      _onDatagramInner(text);
    } catch (_) {
      // Malformed or wrong-typed fields: ignore the datagram.
    }
  }

  void _onDatagramInner(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;
    final j = decoded;
    final type = '${j['type'] ?? ''}';
    final node = '${j['node'] ?? ''}';
    // IDs end up in ':'-joined link keys and as map keys: constrain
    // them (no ':' to split on, bounded length) so a hostile or buggy
    // sender cannot corrupt keys or grow state without limit.
    if (!_idOk.hasMatch(node)) return;
    if (type == 'beacon') {
      if (!_seenAt.containsKey(node) && _seenAt.length >= maxNodes) return;
      final latV = j['lat'];
      final lonV = j['lon'];
      final lat = latV is num ? latV.toDouble() : null;
      final lon = lonV is num ? lonV.toDouble() : null;
      // 0 is a valid coordinate; only the (0,0) "no fix" pair, NaN and
      // out-of-range values are rejected.
      if (lat != null &&
          lon != null &&
          lat.isFinite &&
          lon.isFinite &&
          lat >= -90 &&
          lat <= 90 &&
          lon >= -180 &&
          lon <= 180 &&
          !(lat == 0 && lon == 0)) {
        _positions[node] = (lat: lat, lon: lon);
      }
      final sens = j['sensors'];
      final sensList = sens is List
          ? [
              for (final e in sens)
                if (_idOk.hasMatch('$e')) '$e'
            ].take(maxSensorsPerNode).toList()
          : <String>[];
      if (sensList.isNotEmpty) {
        _sensors[node] = sensList;
      } else {
        _sensors.putIfAbsent(node, () => ['wifi']);
      }
      var cs = '${j['callsign'] ?? ''}'.trim();
      if (cs.length > 32) cs = cs.substring(0, 32);
      if (cs.isNotEmpty) {
        _callsigns[node] = cs;
      } else {
        _callsigns.remove(node);
      }
      // Vacant-window calibration flag (adaptive_baseline_spec.md):
      // only nodes explicitly flagging `calib: true` count toward
      // the guided routine's fit.
      // The firmware sends calib as an integer (%d → 0/1 in the
      // beacon JSON), not a JSON bool — accept both, or the flag
      // never reads true from real nodes (reviewer catch, 2026-10-21).
      if (j['calib'] == true || j['calib'] == 1) {
        calibNodes.add(node);
      } else {
        calibNodes.remove(node);
      }
      _lastBeaconAt = DateTime.now();
      _seenAt[node] = _lastBeaconAt;
    } else if (type == 'event') {
      final sensor = '${j['sensor'] ?? 'unknown'}';
      if (!_idOk.hasMatch(sensor)) return;
      if (!_active.containsKey('$node:$sensor') &&
          _active.length >= maxActive) {
        return;
      }
      final depth = (j['depth_db'] as num?)?.toDouble() ?? 0.0;
      final dur = (j['dur_s'] as num?)?.toDouble() ?? 5.0;
      if (!depth.isFinite || depth <= 0) return;
      _active['$node:$sensor'] = _Disturbance(
        depthDb: depth.clamp(0.5, 60.0).toDouble(),
        endsAt: DateTime.now().add(
          Duration(milliseconds: (dur.clamp(1.0, 120.0) * 1000).toInt()),
        ),
      );
    }
  }

  /// Test hook: feed a raw UDP datagram through the JSON parser.
  @visibleForTesting
  void datagramForTest(String text) => _onDatagram(text);

  @override
  Future<bool> probe() async {
    // Passive listener: binding IS the test. A failed bind (port in
    // use, no permission) must read as unhealthy, not "listening".
    await NodeUdpHub.ensureListening(_onDatagram);
    return NodeUdpHub.isBound;
  }

  @override
  void dispose() {
    NodeUdpHub.release(_onDatagram);
  }
}

class _Disturbance {
  _Disturbance({required this.depthDb, required this.endsAt});
  final double depthDb;
  final DateTime endsAt;
}
