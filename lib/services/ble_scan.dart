/// Nearby wireless device discovery via Bluetooth Low Energy scanning.
///
/// Honest scope, stated in the UI: this sees BLE *advertisers* — phones,
/// earbuds, beacons, wearables that broadcast. It does NOT see Bluetooth
/// Classic devices (paired headphones, mice, keyboards), it is not an
/// image, and bearings are unknown. Typical range is 10-30 m.
///
/// Uses the `universal_ble` plugin (BSD-3-Clause, native Windows support).
/// Scanning is passive and fails soft: Bluetooth off / no adapter /
/// unsupported platform yields a plain message, never a crash.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_decode.dart';

/// One BLE device seen during a scan.
class BleNearbyDevice {
  BleNearbyDevice({
    required this.id,
    required this.name,
    required this.rssiDbm,
    required this.lastSeen,
    this.isSystemDevice = false,
    this.decoded = const BleDecodedInfo(),
  });

  /// MAC / device identifier.
  final String id;

  /// Advertised name, or '(unnamed)'.
  final String name;

  /// Signal strength in dBm. Coarse — walls and orientation swing it.
  final double rssiDbm;

  final DateTime lastSeen;
  final bool isSystemDevice;

  /// Decoded advertisement identity (vendor/kind/services). Estimates.
  final BleDecodedInfo decoded;

  /// Rough proximity bucket from RSSI. Estimate only, labeled as such.
  String get proximityLabel {
    if (rssiDbm >= -60) return 'VERY CLOSE (est.)';
    if (rssiDbm >= -75) return 'NEARBY (est.)';
    return 'FAR (est.)';
  }
}

class BleScanException implements Exception {
  BleScanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Source of BLE scan results. Real adapter on device, simulated demo
/// data otherwise (and in tests).
abstract class BleScanSource {
  Future<List<BleNearbyDevice>> scan(
      {Duration timeout = const Duration(seconds: 10)});
}

/// Real BLE scan via the universal_ble plugin. Passive scan only —
/// never connects to anything.
class UniversalBleScanSource extends BleScanSource {
  UniversalBleScanSource({this.onAdvertisement});

  /// Optional raw-result tap (see BleScanService.advertisementHook).
  final void Function(BleDevice device)? onAdvertisement;

  @override
  Future<List<BleNearbyDevice>> scan(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final AvailabilityState avail;
    try {
      avail = await UniversalBle.getBluetoothAvailabilityState();
    } catch (e) {
      throw BleScanException(
          'Bluetooth is not available on this machine ($e).');
    }
    if (avail != AvailabilityState.poweredOn) {
      throw BleScanException(_explain(avail));
    }

    final found = <String, BleNearbyDevice>{};
    final sub = UniversalBle.scanStream.listen((d) {
      try {
        onAdvertisement?.call(d);
      } catch (_) {
        // The tap must never break the scan path.
      }
      final name = (d.name?.trim().isNotEmpty ?? false)
          ? d.name!.trim()
          : '(unnamed)';
      final mfr = d.manufacturerDataList
          .map((m) => (
                companyId: m.companyId,
                payload: m.payload.toList(),
              ))
          .toList();
      found[d.deviceId] = BleNearbyDevice(
        id: d.deviceId,
        name: name,
        rssiDbm: (d.rssi ?? -100).toDouble(),
        lastSeen: DateTime.now(),
        isSystemDevice: d.isSystemDevice ?? false,
        decoded: decodeBleAdvertiser(mfr, d.services),
      );
    }, onError: (_) {});
    try {
      await UniversalBle.startScan();
      await Future<void>.delayed(timeout);
    } catch (e) {
      throw BleScanException('BLE scan failed: $e');
    } finally {
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
    final out = found.values.toList()
      ..sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
    return out;
  }

  String _explain(AvailabilityState s) {
    switch (s) {
      case AvailabilityState.poweredOff:
        return 'Bluetooth is off — turn it on and scan again.';
      case AvailabilityState.unsupported:
        return 'This machine has no Bluetooth LE adapter.';
      case AvailabilityState.unauthorized:
        return 'Bluetooth permission denied by the OS.';
      case AvailabilityState.unknown:
      case AvailabilityState.resetting:
        return 'Bluetooth is not ready — wait a moment and try again.';
      case AvailabilityState.poweredOn:
        return 'Bluetooth is on.';
    }
  }
}

/// Simulated nearby devices for demos and simulated mode.
class SimulatedBleScanSource extends BleScanSource {
  final math.Random _rng = math.Random();

  @override
  Future<List<BleNearbyDevice>> scan(
      {Duration timeout = const Duration(seconds: 10)}) async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final now = DateTime.now();
    final demo = [
      (
        'Phone-7A2',
        'aa:bb:cc:dd:ee:11',
        -58.0,
        const BleDecodedInfo(
            vendor: 'APPLE', kind: 'APPLE · NEARBY DEVICE (est.)')
      ),
      (
        '[TV] Living Room',
        'aa:bb:cc:dd:ee:22',
        -71.0,
        const BleDecodedInfo(vendor: 'SAMSUNG')
      ),
      (
        '(unnamed)',
        'aa:bb:cc:dd:ee:33',
        -79.0,
        const BleDecodedInfo(
            kind: 'BEACON (est.)',
            serviceLabels: ['BEACON (EDDYSTONE)'],
            companyId: 0x00E0)
      ),
      (
        'FitBand Pro',
        'aa:bb:cc:dd:ee:44',
        -86.0,
        const BleDecodedInfo(
            kind: 'FITNESS SENSOR (est.)',
            serviceLabels: ['HEART RATE'],
            companyId: 0x0059)
      ),
    ];
    return demo
        .map((t) => BleNearbyDevice(
              name: t.$1,
              id: t.$2,
              rssiDbm: t.$3 + _rng.nextDouble() * 4 - 2,
              lastSeen: now,
              decoded: t.$4,
            ))
        .toList();
  }
}

/// One BLE signal-disturbance episode: this device's RSSI as seen by
/// THIS phone/PC dipped and stayed down, then recovered (or is still
/// down). Tripwire parity with the radio and WiFi crossing logs.
///
/// Honest scope: a dip means the signal weakened — the device moved,
/// something passed between you and it, or an obstruction appeared.
/// RSSI cannot tell those apart, and phone MACs randomize, so device
/// counts are approximate. Estimates only.
class BleCrossingEvent {
  BleCrossingEvent({
    required this.deviceId,
    required this.deviceName,
    required this.startTime,
    this.peakDipDb = 0.0,
  });

  final String deviceId;
  final String deviceName;
  final DateTime startTime;
  DateTime? endTime;
  double peakDipDb;

  bool get closed => endTime != null;

  double get durationSecs => (endTime ?? DateTime.now())
      .difference(startTime)
      .inMilliseconds /
      1000.0;

  String get durationLabel =>
      '${durationSecs.toStringAsFixed(0)}s${closed ? '' : '+'} (est.)';
}

/// Per-device tripwire state: RSSI ring buffer + rolling baseline.
class _BleDeviceTrip {
  final List<double> samples = [];
  BleCrossingEvent? open;
  int disturbedStreak = 0;
  String name = '(unnamed)';
}

/// One sighting record in the accumulating history. Phone MACs
/// randomize, so sighting counts are approximate — never identifiers.
class BleSighting {
  BleSighting({required this.firstSeen, required this.lastSeen})
      : count = 1;

  DateTime firstSeen;
  DateTime lastSeen;
  int count;
}

/// Owns manual BLE scans. Mirrors the LAN-scan pattern: the user taps
/// SCAN, results accumulate, nothing runs continuously.
class BleScanService {
  /// Injected in tests; otherwise chosen from [simulate].
  BleScanSource? testSource;

  /// Passive tap on raw advertisements, invoked for every scan
  /// result that carries service data: (deviceId, {serviceUuid:
  /// bytes}). The Remote ID service uses this to decode drone
  /// broadcasts off the SAME scan this service already runs — no
  /// second radio session, no transmit of any kind. Set by AppState;
  /// null = tap off. Invocations are wrapped so a tap failure can
  /// never break the scan path.
  void Function(String deviceId, Map<String, Uint8List> serviceData)?
      advertisementHook;

  final List<BleNearbyDevice> devices = [];
  bool scanning = false;
  String? error;
  DateTime? scannedAt;
  bool simulated = true;

  /// Accumulating sighting history across scans (pruned past 30 min).
  final Map<String, BleSighting> sightings = {};

  void Function()? onUpdate;

  /// Fire the advertisement tap for one raw scan result, if set.
  void _fireAdvertisementHook(BleDevice device) {
    final hook = advertisementHook;
    if (hook == null) return;
    final sd = device.serviceData;
    if (sd.isEmpty) return;
    try {
      hook(device.deviceId, sd);
    } catch (e) {
      debugPrint('advertisement hook failed: $e');
    }
  }

  Future<void> scan({required bool simulate}) async {
    if (scanning) return;
    scanning = true;
    error = null;
    onUpdate?.call();
    simulated = simulate;
    try {
      final src = testSource ??
          (simulate
              ? SimulatedBleScanSource()
              : UniversalBleScanSource(onAdvertisement: _fireAdvertisementHook));
      final found = await src.scan();
      devices
        ..clear()
        ..addAll(found);
      scannedAt = DateTime.now();
      _recordSightings(found);
    } on BleScanException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'SCAN FAILED: $e';
    } finally {
      scanning = false;
      onUpdate?.call();
    }
  }

  void _recordSightings(List<BleNearbyDevice> found) {
    final now = DateTime.now();
    for (final d in found) {
      final s = sightings[d.id];
      if (s == null) {
        sightings[d.id] = BleSighting(firstSeen: now, lastSeen: now);
      } else {
        s.lastSeen = now;
        s.count++;
      }
    }
    sightings.removeWhere(
        (_, s) => now.difference(s.lastSeen).inMinutes > 30);
  }

  void clear() {
    devices.clear();
    sightings.clear();
    error = null;
    scannedAt = null;
    scanning = false;
  }

  // ---- Continuous tripwire monitoring ----
  //
  // The phone/PC is the "home node"; every BLE advertiser is a remote
  // node, and the monitored path is the signal between them. A sustained
  // RSSI dip on that path means the signal weakened — the device moved,
  // something passed between you and it, or an obstruction appeared.
  // RSSI cannot distinguish those, so dips are reported as signal
  // disturbances (estimates), never as located objects.

  bool monitoring = false;

  /// Dip threshold in dB below the rolling baseline. Lower = twitchier.
  double dipThresholdDb = 8.0;

  /// Closed BLE disturbance episodes, newest first.
  final List<BleCrossingEvent> bleEvents = [];

  /// Devices currently in a dip episode.
  List<BleCrossingEvent> get activeBleDips => [
        for (final t in _trips.values)
          if (t.open != null) t.open!,
      ];

  final Map<String, _BleDeviceTrip> _trips = {};
  StreamSubscription<BleDevice>? _monitorSub;
  Timer? _simTimer;

  /// Start continuous monitoring. Keeps the BLE scan stream open and
  /// runs the per-device tripwire; call [stopMonitoring] to end it.
  Future<void> startMonitoring({required bool simulate}) async {
    if (monitoring) return;
    if (scanning) return;
    error = null;
    simulated = simulate;
    if (simulate) {
      monitoring = true;
      // Seed from the simulated scan list so there is something to watch.
      final src = SimulatedBleScanSource();
      final found = await src.scan();
      devices
        ..clear()
        ..addAll(found);
      for (final d in found) {
        _trips.putIfAbsent(d.id, () => _BleDeviceTrip()).name = d.name;
      }
      _simTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => _simTick());
      onUpdate?.call();
      return;
    }
    try {
      final avail = await UniversalBle.getBluetoothAvailabilityState();
      if (avail != AvailabilityState.poweredOn) {
        throw BleScanException(
            'Bluetooth is not on — cannot monitor.');
      }
      monitoring = true;
      _monitorSub = UniversalBle.scanStream.listen(
        (d) {
          _fireAdvertisementHook(d);
          _onAdvertisement(
            d.deviceId,
            (d.name?.trim().isNotEmpty ?? false)
                ? d.name!.trim()
                : '(unnamed)',
            (d.rssi ?? -100).toDouble(),
          );
        },
        onError: (_) {},
      );
      await UniversalBle.startScan();
    } catch (e) {
      monitoring = false;
      error = e is BleScanException ? e.message : 'MONITOR FAILED: $e';
    }
    onUpdate?.call();
  }

  Future<void> stopMonitoring() async {
    monitoring = false;
    _simTimer?.cancel();
    _simTimer = null;
    await _monitorSub?.cancel();
    _monitorSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    // Close any open episodes.
    final now = DateTime.now();
    for (final t in _trips.values) {
      final o = t.open;
      if (o != null) {
        o.endTime = now;
        bleEvents.insert(0, o);
        t.open = null;
      }
    }
    if (bleEvents.length > 100) {
      bleEvents.removeRange(100, bleEvents.length);
    }
    onUpdate?.call();
  }

  /// Simulated monitoring tick: jitter RSSI, occasionally inject a dip
  /// episode so the tripwire has something to catch in demos.
  void _simTick() {
    if (!monitoring) return;
    final rng = math.Random();
    for (final d in devices) {
      var rssi = d.rssiDbm + rng.nextDouble() * 3 - 1.5;
      // ~8% chance per device per second to start a passing dip.
      if (rng.nextDouble() < 0.08) {
        rssi -= 10 + rng.nextDouble() * 8;
      }
      final i = devices.indexOf(d);
      devices[i] = BleNearbyDevice(
        id: d.id,
        name: d.name,
        rssiDbm: rssi.clamp(-100.0, -30.0),
        lastSeen: DateTime.now(),
        decoded: d.decoded,
      );
      _onAdvertisement(d.id, d.name, devices[i].rssiDbm);
    }
    onUpdate?.call();
  }

  void _onAdvertisement(String id, String name, double rssi) {
    final t = _trips.putIfAbsent(id, () => _BleDeviceTrip());
    t.name = name;
    t.samples.add(rssi);
    while (t.samples.length > 40) {
      t.samples.removeAt(0);
    }
    // Keep the device list's RSSI fresh for the proximity display.
    final di = devices.indexWhere((d) => d.id == id);
    if (di >= 0) {
      final d = devices[di];
      devices[di] = BleNearbyDevice(
        id: d.id,
        name: d.name,
        rssiDbm: rssi,
        lastSeen: DateTime.now(),
        isSystemDevice: d.isSystemDevice,
        decoded: d.decoded,
      );
    }
    if (t.samples.length < 12) return;
    // Baseline = median of older samples (a current dip must not
    // pollute it); recent = median of the newest few.
    final older = t.samples.sublist(0, t.samples.length - 5);
    final recent = t.samples.sublist(t.samples.length - 5);
    final base = _median(older);
    final now_ = _median(recent);
    final dip = base - now_;
    if (t.open == null) {
      if (dip >= dipThresholdDb) {
        t.disturbedStreak++;
        if (t.disturbedStreak >= 3) {
          t.open = BleCrossingEvent(
            deviceId: id,
            deviceName: name,
            startTime:
                DateTime.now().subtract(const Duration(seconds: 3)),
            peakDipDb: dip,
          );
          onUpdate?.call();
        }
      } else {
        t.disturbedStreak = 0;
      }
    } else {
      t.open!.peakDipDb = math.max(t.open!.peakDipDb, dip);
      if (dip < dipThresholdDb * 0.5) {
        t.open!.endTime = DateTime.now();
        bleEvents.insert(0, t.open!);
        if (bleEvents.length > 100) bleEvents.removeLast();
        t.open = null;
        t.disturbedStreak = 0;
        onUpdate?.call();
      }
    }
  }

  static double _median(List<double> xs) {
    final s = List<double>.from(xs)..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  /// Test hook: feed one RSSI sample as if heard on the scan stream.
  @visibleForTesting
  void debugInjectRssi(String id, String name, double rssiDbm) =>
      _onAdvertisement(id, name, rssiDbm);
}
