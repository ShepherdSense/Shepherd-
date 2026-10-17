/// Multi-radio driver framework.
///
/// Every supported radio family implements [RadioDriver]: it polls its
/// hardware and emits plain [LinkSample]s. Everything downstream —
/// tripwire, tracker, dashboard, map — is radio-agnostic and consumes
/// only LinkSamples.
///
/// Namespacing: each driver prefixes its node IDs (`silvus:90550`),
/// so link keys (`silvus:90550 → silvus:90551`) can never collide
/// across vendors, and per-link tripwire baselines stay independent.
library;

import 'dart:convert';
import 'dart:io';

import '../models/link_sample.dart';
import '../models/tracking.dart';
import 'silvus_api.dart';
import 'simulated.dart';
import 'kraken_driver.dart';

/// One configured radio network.
class RadioConfig {
  RadioConfig({
    required this.driverId,
    required this.address,
    this.label = '',
    this.enabled = true,
    this.pollInterval = 0.25,
  });

  /// 'silvus' | 'mpu5' | 'harris' | 'sdr' | 'simulated'.
  final String driverId;

  /// IP/host for network drivers; '' for simulated.
  final String address;
  final String label;
  bool enabled;
  double pollInterval;

  String get displayLabel =>
      label.isEmpty ? '${driverId.toUpperCase()} · $address' : label;

  Map<String, dynamic> toJson() => {
        'driverId': driverId,
        'address': address,
        'label': label,
        'enabled': enabled,
        'pollInterval': pollInterval,
      };

  factory RadioConfig.fromJson(Map<String, dynamic> j) => RadioConfig(
        driverId: '${j['driverId'] ?? 'silvus'}',
        address: '${j['address'] ?? ''}',
        label: '${j['label'] ?? ''}',
        enabled: j['enabled'] != false,
        pollInterval:
            (double.tryParse('${j['pollInterval']}') ?? 0.25)
                .clamp(0.1, 60.0)
                .toDouble(),
      );
}

/// Live status of one driver instance, for the dashboard radio card.
class DriverStatus {
  DriverStatus({
    required this.driverId,
    required this.label,
    required this.enabled,
    this.lastPoll,
    this.linkCount = 0,
    this.error,
  });

  final String driverId;
  final String label;
  final bool enabled;
  DateTime? lastPoll;
  int linkCount;
  String? error;
}

/// The contract every radio family implements.
abstract class RadioDriver {
  /// 'silvus' | 'mpu5' | 'harris' | 'sdr' | 'simulated'.
  String get driverId;

  /// Human label, e.g. 'SILVUS'.
  String get label;

  /// True when this driver can actually run (telemetry implemented).
  bool get isImplemented;

  /// One poll: raw link samples with driver-namespaced node IDs.
  Future<List<LinkSample>> poll();

  /// Quick reachability check for discovery / setup validation.
  Future<bool> probe();

  /// Shown on the radio card when a poll succeeds but returns no links.
  String get emptyHint =>
      'Radio reachable but reports no RF links (radios unmeshed?)';

  /// Longest a sample from this driver may age before it stops counting
  /// as live evidence. Null = derive from the poll interval (default).
  /// Drivers whose hardware reports slower than they are polled (a
  /// sweeping SDR) override this.
  Duration? get sampleMaxAge => null;

  void dispose() {}
}

/// Silvus StreamCaster driver: HTTP JSON-RPC `streamscape_data`.
class SilvusDriver extends RadioDriver {
  SilvusDriver({required String ip}) : _api = SilvusApi(ip: ip);

  final SilvusApi _api;

  @override
  String get driverId => 'silvus';

  @override
  String get label => 'SILVUS';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async {
    final snap = await _api.fetchSnapshot();
    if (snap == null) return [];
    // Namespace node IDs so vendors can never collide.
    return [
      for (final l in snap.links)
        LinkSample(
          timestamp: l.timestamp,
          fromNode: 'silvus:${l.fromNode}',
          toNode: 'silvus:${l.toNode}',
          snr: l.snr,
          mcs: l.mcs,
          pcns: l.pcns,
          noiseFrom: l.noiseFrom,
          noiseTo: l.noiseTo,
        ),
    ];
  }

  @override
  Future<bool> probe() => _api.probe();

  @override
  void dispose() => _api.close();
}

/// Simulated mesh driver: wraps [SimulatedSource] so simulated mode is
/// just another driver. Node IDs are namespaced `sim:...`.
class SimulatedDriver extends RadioDriver {
  SimulatedDriver({this.pollInterval = 0.25}) : _sim = SimulatedSource();

  final SimulatedSource _sim;
  final double pollInterval;

  @override
  String get driverId => 'sim';

  @override
  String get label => 'SIMULATED';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async {
    final raw = _sim.tick(dt: pollInterval);
    return [
      for (final l in raw)
        LinkSample(
          timestamp: l.timestamp,
          fromNode: 'sim:${l.fromNode}',
          toNode: 'sim:${l.toNode}',
          snr: l.snr,
          mcs: l.mcs,
          pcns: l.pcns,
          noiseFrom: l.noiseFrom,
          noiseTo: l.noiseTo,
        ),
    ];
  }

  @override
  Future<bool> probe() async => true;

  /// Canonical sim layout with namespaced keys, matching [poll] output.
  Map<String, NodePosition> get nodeLayout => {
        for (final e in _sim.nodeLayout.entries)
          'sim:${e.key}': NodePosition(
            nodeId: 'sim:${e.key}',
            x: e.value.x,
            y: e.value.y,
            height: e.value.height,
            antenna: e.value.antenna,
          ),
      };
}

/// MPU5 (Persistent Systems Wave Relay) — telemetry not yet implemented.
/// Wave Relay does not mesh with Silvus MN-MIMO; it would be a separate
/// driver emitting LinkSamples once its management API is mapped.
class Mpu5Driver extends RadioDriver {
  @override
  String get driverId => 'mpu5';

  @override
  String get label => 'MPU5';

  @override
  bool get isImplemented => false;

  @override
  Future<List<LinkSample>> poll() =>
      throw UnimplementedError('MPU5 telemetry not yet implemented');

  @override
  Future<bool> probe() async => false;
}

/// L3Harris Falcon family — telemetry not yet implemented.
/// Needs a pollable per-neighbor signal interface (SNMP MIB or similar);
/// an SNMP probe will determine what is actually exposed.
class L3HarrisDriver extends RadioDriver {
  @override
  String get driverId => 'harris';

  @override
  String get label => 'L3HARRIS';

  @override
  bool get isImplemented => false;

  @override
  Future<List<LinkSample>> poll() =>
      throw UnimplementedError('L3Harris telemetry not yet implemented');

  @override
  Future<bool> probe() async => false;
}

/// One band-energy reading from the PC-side `sdr_bridge.py`.
/// Pure data + parsing; unit-tested in test/sdr_bridge_test.dart.
class SdrBand {
  SdrBand({
    required this.radio,
    required this.band,
    required this.centerMhz,
    required this.bwMhz,
    required this.energyDbfs,
    required this.noiseDbfs,
    required this.binsDbfs,
    required this.t,
    this.peakMhz,
    this.peakDbfs,
    this.spanMhz,
  });

  final String radio;
  final String band;
  final double centerMhz;
  final double bwMhz;

  /// Band-median PSD in dBFS (negative). The stable wideband metric.
  final double energyDbfs;

  /// 10th-percentile PSD: the band's noise floor estimate, dBFS.
  final double noiseDbfs;

  /// Per-sub-band (8) PEAK PSD, dBFS. Catches narrowband emitters the
  /// median ignores; peak-based, so spur-sensitive.
  final List<double> binsDbfs;

  final DateTime t;

  /// Absolute frequency (MHz) and level of the strongest non-DC bin the
  /// bridge saw in this band. Null from older bridges. An investigation
  /// aid, not an identification.
  final double? peakMhz;
  final double? peakDbfs;

  /// Width (MHz) of spectrum actually measured; can be narrower than
  /// [bwMhz] when the radio's sample rate can't cover the whole band.
  final double? spanMhz;

  /// Parse a decoded bridge datagram. Returns null for beacons,
  /// wrong versions, and malformed packets (never throws).
  static SdrBand? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'band') return null;
      final bins = (j['bins_dbfs'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
      final energy = (j['energy_dbfs'] as num).toDouble();
      final noise = (j['noise_dbfs'] as num).toDouble();
      // NaN / infinite readings must never reach the tripwire's baseline.
      if (!energy.isFinite ||
          !noise.isFinite ||
          bins.any((b) => !b.isFinite)) {
        return null;
      }
      double? opt(String k) {
        final v = j[k];
        return v is num && v.isFinite ? v.toDouble() : null;
      }

      return SdrBand(
        radio: '${j['radio']}',
        band: '${j['band']}',
        centerMhz: (j['center_mhz'] as num).toDouble(),
        bwMhz: (j['bw_mhz'] as num).toDouble(),
        energyDbfs: energy,
        noiseDbfs: noise,
        binsDbfs: bins,
        peakMhz: opt('peak_mhz'),
        peakDbfs: opt('peak_dbfs'),
        spanMhz: opt('span_mhz'),
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }

  /// Virtual link `sdr:<radio> → sdr:band-<label>`.
  ///
  /// Polarity convention (shared with the bridge): bridge energy is dBFS
  /// (negative). Negated into [LinkSample.snr], an emitter APPEARING in
  /// the band reads as a positive "dip" in dB for the tripwire:
  /// dip = baseline - snr = energy_now - energy_baseline. Sub-band peaks
  /// ride along in [LinkSample.pcns] for investigation.
  LinkSample toLinkSample() => LinkSample(
        timestamp: t,
        fromNode: 'sdr:$radio',
        toNode: 'sdr:band-$band',
        snr: -energyDbfs,
        noiseFrom: -noiseDbfs,
        pcns: [for (final b in binsDbfs) -b],
      );
}

/// SDR spectrum-sensor driver: listens for the PC-side bridge
/// (`field_kit/sdr_bridge/sdr_bridge.py` — any supported SDR: RTL-SDR,
/// ADALM-Pluto, USRP B200/B210, HackRF/Airspy/LimeSDR via SoapySDR;
/// RX only, never transmits) on UDP.
///
/// Each watched band becomes a virtual tripwire link, so the whole
/// downstream pipeline (adaptive thresholds, baseline hold, alerts,
/// event log) works unchanged. Honest scope: one radio reports band
/// ENERGY, not direction, range, or identity — and these virtual links
/// carry no geometry, so app_state keeps them out of the position
/// solver, shadow grid, and stitcher. Alerts still fire.
class SdrDriver extends RadioDriver {
  SdrDriver({required this.host, required this.port});

  /// The bridge's destination, i.e. where THIS app listens:
  /// "127.0.0.1:49161" (default), "host", or "host:port".
  factory SdrDriver.fromAddress(String address) {
    var host = '127.0.0.1';
    var port = defaultBridgePort;
    final addr = address.trim();
    if (addr.isNotEmpty) {
      final i = addr.lastIndexOf(':');
      if (i > 0) {
        host = addr.substring(0, i);
        port = int.tryParse(addr.substring(i + 1)) ?? port;
      } else {
        host = addr;
      }
    }
    return SdrDriver(host: host, port: port);
  }

  /// UDP port the bridge sends to (and this driver listens on).
  static const int defaultBridgePort = 49161;

  final String host;
  final int port;

  /// Bands the bridge hasn't refreshed in this long are dropped, so a
  /// dead bridge reads as no data instead of a frozen last reading.
  static const Duration maxBandAge = Duration(seconds: 15);

  RawDatagramSocket? _socket;
  DateTime? _lastBeaconAt;
  DateTime? _lastDataAt;
  String _bridgeBackend = '';
  final Map<String, SdrBand> _latest = {};
  final Map<String, DateTime> _arrivedAt = {};

  /// What the bridge last announced itself as ('' until first beacon).
  String get bridgeBackend => _bridgeBackend;

  /// Latest reading per band (read-only view, for UI panels).
  List<SdrBand> get latestBands => List.unmodifiable(_latest.values);

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    // `InternetAddress(host)` throws for anything but an IP literal;
    // fall back to all interfaces so a hostname (or "0.0.0.0") works.
    final ip = InternetAddress.tryParse(host) ?? InternetAddress.anyIPv4;
    _socket = await RawDatagramSocket.bind(ip, port);
  }

  void _handle(List<int> data) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (j['v'] != 1) return;
    if (j['kind'] == 'beacon') {
      _lastBeaconAt = DateTime.now();
      final b = j['backend'];
      if (b is String) _bridgeBackend = b;
      return;
    }
    final band = SdrBand.tryParse(j);
    if (band == null) return;
    _lastDataAt = DateTime.now();
    final key = '${band.radio}:${band.band}';
    _latest[key] = band;
    _arrivedAt[key] = DateTime.now();
  }

  void _drain() {
    final s = _socket;
    if (s == null) return;
    Datagram? d;
    while ((d = s.receive()) != null) {
      _handle(d!.data);
    }
  }

  @override
  String get driverId => 'sdr';

  @override
  String get label => 'SDR';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'No SDR bridge data — is sdr_bridge.py running and sending to '
      '$host:$port?';

  // The bridge sweeps bands one after another, so each band refreshes
  // only every few seconds. Stay live as long as the driver itself
  // keeps the reading.
  @override
  Duration? get sampleMaxAge => maxBandAge + const Duration(seconds: 1);

  @override
  Future<List<LinkSample>> poll() async {
    await _ensureSocket();
    _drain();
    // Report the latest reading per band on EVERY poll, not just fresh
    // arrivals: a sweep revisits each band every couple of seconds, and
    // an empty poll reads as "radio broken" downstream. But bands the
    // bridge hasn't refreshed in a while are dropped, so a dead bridge
    // reads as no data instead of a frozen last reading.
    final cutoff = DateTime.now().subtract(maxBandAge);
    _latest.removeWhere((k, _) => (_arrivedAt[k] ?? cutoff).isBefore(cutoff));
    _arrivedAt.removeWhere((k, _) => !_latest.containsKey(k));
    return [for (final b in _latest.values) b.toLinkSample()];
  }

  @override
  Future<bool> probe() async {
    try {
      await _ensureSocket();
    } catch (_) {
      return false;
    }
    // Listen briefly for the bridge; it is a separate process the user
    // starts, so probe() reports what setup validation needs: true only
    // when the bridge is actually talking. ANY bridge packet counts --
    // beacons come every few seconds and a sweep's band packets nearly
    // as often, so waiting for one specific kind made a healthy bridge
    // fail the probe most of the time.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      _drain();
      final now = DateTime.now();
      for (final heard in [_lastBeaconAt, _lastDataAt]) {
        if (heard != null &&
            now.difference(heard) < const Duration(seconds: 30)) {
          return true;
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  @override
  void dispose() {
    _socket?.close();
    _socket = null;
    _latest.clear();
    _arrivedAt.clear();
  }
}

/// Build a driver from a config. Throws for unimplemented families.
RadioDriver driverFor(RadioConfig config) {
  switch (config.driverId) {
    case 'silvus':
      return SilvusDriver(ip: config.address);
    case 'mpu5':
      return Mpu5Driver();
    case 'harris':
      return L3HarrisDriver();
    case 'sdr':
      return SdrDriver.fromAddress(config.address);
    case 'kraken':
      return KrakenDriver.fromAddress(config.address);
    default:
      throw ArgumentError('Unknown driver: ${config.driverId}');
  }
}

/// Driver types the user can pick in the radio manager.
const List<({String id, String label, bool implemented})> driverTypes = [
  (id: 'silvus', label: 'SILVUS', implemented: true),
  (id: 'sdr', label: 'SDR (Pluto / USRP / RTL-SDR / HackRF…)', implemented: true),
  (id: 'kraken', label: 'KRAKENSDR (DF bearings)', implemented: true),
  (id: 'mpu5', label: 'MPU5 (Wave Relay)', implemented: false),
  (id: 'harris', label: 'L3HARRIS', implemented: false),
];
