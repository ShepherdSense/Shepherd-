/// Ambient WiFi sensing using the host device's own wireless adapter.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'ble_scan.dart';
import 'lan_scan.dart';
import 'wifi_threats.dart';

/// One AP reading from the device adapter.
class WifiApReading {
  WifiApReading({
    required this.ssid,
    required this.bssid,
    required this.rssiDbm,
    required this.isConnected,
    this.auth = '',
    this.cipher = '',
  });

  final String ssid;
  final String bssid;
  final double rssiDbm;
  final bool isConnected;

  /// Authentication / cipher as reported by the survey (netsh
  /// mode=bssid), e.g. 'WPA2-Personal' / 'CCMP'. Empty when unknown.
  /// Used by rogue-AP detection to spot security mismatches.
  final String auth;
  final String cipher;

  /// Rough indoor distance estimate (log-distance path loss).
  /// Labeled an estimate everywhere it is shown — RSSI ranging is
  /// notoriously noisy (±50% or worse).
  double get estimatedDistanceM {
    const p0 = -40.0; // dBm at 1 m
    const n = 3.0; // indoor path-loss exponent
    final d = math.pow(10, (p0 - rssiDbm) / (10 * n));
    return d.clamp(2.0, 80.0).toDouble();
  }
}

/// Rolling-median baseline + sustained-dip detector per BSSID,
/// mirroring the Silvus tripwire logic at coarser resolution.
///
/// Cadence-aware: the connected AP is polled ~1/sec and confirms on a
/// streak of 2, but neighbor-survey samples (~20 s cadence) can't afford
/// to wait 40 s — a strong dip confirms immediately, and a solid survey
/// sample (≥1.5× threshold) confirms on its own.
class _WifiBaseline {
  _WifiBaseline({this.dipThresholdDb = 6.0});

  final double dipThresholdDb;
  final int window = 30;
  final Queue<double> _samples = Queue<double>();
  int _dipStreak = 0;
  bool disturbed = false;

  /// Depth of the latest sample below the median, dB. 0 when at/above.
  double lastDepthDb = 0.0;

  void add(double rssi, {bool survey = false}) {
    _samples.addLast(rssi);
    while (_samples.length > window) {
      _samples.removeFirst();
    }
    if (_samples.length < 8) {
      disturbed = false;
      _dipStreak = 0;
      lastDepthDb = 0.0;
      return;
    }
    final sorted = _samples.toList()..sort();
    final median = sorted[sorted.length ~/ 2];
    lastDepthDb = rssi < median ? median - rssi : 0.0;
    if (rssi < median - dipThresholdDb) {
      _dipStreak++;
    } else {
      _dipStreak = 0;
    }
    if (rssi < median - dipThresholdDb * 2) {
      // Strong dip: confirm immediately, any cadence.
      _dipStreak = 2;
    } else if (survey && rssi < median - dipThresholdDb * 1.5) {
      // Survey cadence: one solid sample is enough evidence.
      _dipStreak = 2;
    }
    disturbed = _dipStreak >= 2;
  }
}

/// One WiFi disturbance episode on a single AP — the WiFi equivalent of
/// the radio tripwire's CrossingEvent. Duration and peak dip are measured.
/// Magnitude here is dip depth in dB, NOT an object-size estimate: a deep
/// dip can be a person close to the AP or plain interference.
class WifiCrossingEvent {
  WifiCrossingEvent({
    required this.bssid,
    required this.ssid,
    required this.startTime,
    this.peakDipDb = 0.0,
  });

  final String bssid;
  final String ssid;
  final DateTime startTime;
  DateTime? endTime;
  double peakDipDb;

  bool get closed => endTime != null;

  double get durationSecs => (endTime ?? DateTime.now())
      .difference(startTime)
      .inMilliseconds /
      1000.0;

  String get clockLabel {
    final t = startTime;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  /// Plain-words description of the *signal* — duration and depth.
  /// This describes the dip, never the object: a "lingering deep dip"
  /// can be a person by the router or plain interference.
  String get characterLabel {
    final d = durationSecs;
    final dur = d < 5
        ? 'BRIEF'
        : d < 20
            ? 'PASSING'
            : 'LINGERING';
    final dep = peakDipDb < 8
        ? 'SHALLOW'
        : peakDipDb < 15
            ? 'DEEP'
            : 'VERY DEEP';
    return '$dur · $dep DIP';
  }
}

/// Source of ambient WiFi readings. Windows uses netsh; Android is not
/// yet implemented (needs a scan plugin + platform channel for
/// connected-AP RSSI); anything else falls back to simulation.
abstract class WifiRssiSource {
  /// Fast poll: connected AP RSSI (cheap).
  Future<List<WifiApReading>> pollFast();

  /// Slow poll: nearby AP survey (triggers a real scan; seconds).
  Future<List<WifiApReading>> pollSurvey();
}

/// Windows implementation via netsh. Assumes English netsh output.
class NetshWifiSource extends WifiRssiSource {
  List<WifiApReading> _lastSurvey = [];

  @override
  Future<List<WifiApReading>> pollFast() async {
    try {
      final res = await Process.run(
          'netsh', ['wlan', 'show', 'interfaces']);
      if (res.exitCode != 0) return [];
      final out = res.stdout as String;
      // Only the connected interface carries a Signal line.
      final stateM =
          RegExp(r'State\s*:\s*connected', caseSensitive: false)
              .firstMatch(out);
      if (stateM == null) return [];
      final ssidM =
          RegExp(r'^\s*SSID\s*:\s*(.+?)\s*$', multiLine: true)
              .firstMatch(out);
      final bssidM = RegExp(
              r'^\s*BSSID\s*:\s*([0-9a-fA-F:]{17})\s*$',
              multiLine: true)
          .firstMatch(out);
      final sigM = RegExp(r'^\s*Signal\s*:\s*(\d+)\s*%\s*$',
              multiLine: true)
          .firstMatch(out);
      if (sigM == null) return [];
      final pct = double.parse(sigM.group(1)!);
      return [
        WifiApReading(
          ssid: ssidM?.group(1)?.trim() ?? '(unknown)',
          bssid: (bssidM?.group(1) ?? 'local').toLowerCase(),
          // Standard rough conversion: dBm ≈ pct/2 − 100.
          rssiDbm: pct / 2 - 100,
          isConnected: true,
        ),
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<WifiApReading>> pollSurvey() async {
    try {
      final res = await Process.run(
          'netsh', ['wlan', 'show', 'networks', 'mode=bssid']);
      if (res.exitCode != 0) return _lastSurvey;
      final out = res.stdout as String;
      final found = <WifiApReading>[];
      // Block parser: an SSID header carries Authentication/Cipher for
      // every BSSID beneath it; each BSSID block ends with its Signal
      // line. (A previous version read Signal from the BSSID line itself
      // and always got 0% — this parses the real layout.)
      String ssid = '';
      String auth = '';
      String cipher = '';
      String? pendingBssid;
      // netsh prints CRLF. Split on either: a stray '\r' at the end of a
      // line stops `(.*)$` from matching (Dart's `.` excludes '\r', and
      // `$` is end-of-input without multiLine), which made EVERY SSID
      // header fail and every AP read as "(hidden)" on Windows -- which
      // silently disabled rogue-AP detection.
      for (final rawLine in out.split(RegExp(r'\r?\n'))) {
        final line = rawLine.trimRight();
        final ssidM =
            RegExp(r'^SSID \d+ :\s*(.*)$').firstMatch(line);
        if (ssidM != null) {
          ssid = ssidM.group(1)!.trim();
          auth = '';
          cipher = '';
          pendingBssid = null;
          continue;
        }
        final authM = RegExp(
                r'^\s*Authentication\s*:\s*(.+?)\s*$')
            .firstMatch(line);
        if (authM != null) {
          auth = authM.group(1)!.trim();
          continue;
        }
        final cipherM =
            RegExp(r'^\s*Cipher\s*:\s*(.+?)\s*$')
                .firstMatch(line);
        if (cipherM != null) {
          cipher = cipherM.group(1)!.trim();
          continue;
        }
        final bssidM = RegExp(
                r'BSSID \d+\s*:\s*([0-9a-fA-F:]{17})')
            .firstMatch(line);
        if (bssidM != null) {
          pendingBssid = bssidM.group(1)!.toLowerCase();
          continue;
        }
        final sigM =
            RegExp(r'^\s*Signal\s*:\s*(\d+)\s*%')
                .firstMatch(line);
        if (sigM != null && pendingBssid != null) {
          final pct = double.parse(sigM.group(1)!);
          found.add(WifiApReading(
            ssid: ssid.isEmpty ? '(hidden)' : ssid,
            bssid: pendingBssid,
            rssiDbm: pct / 2 - 100,
            isConnected: false,
            auth: auth,
            cipher: cipher,
          ));
          pendingBssid = null;
        }
      }
      if (found.isNotEmpty) _lastSurvey = found;
      return _lastSurvey;
    } catch (_) {
      return _lastSurvey;
    }
  }
}

/// Simulated ambient field: one "connected" AP plus neighbors, with
/// occasional wandering disturbance dips. Used when no real adapter
/// source exists, and for demos.
class SimulatedWifiSource extends WifiRssiSource {
  final math.Random _rng = math.Random();
  final Map<String, double> _base = {
    'aa:bb:cc:dd:ee:01': -55,
    'aa:bb:cc:dd:ee:02': -66,
    'aa:bb:cc:dd:ee:03': -73,
    'aa:bb:cc:dd:ee:04': -81,
  };
  final Map<String, String> _ssids = {
    'aa:bb:cc:dd:ee:01': 'HOME-NET',
    'aa:bb:cc:dd:ee:02': 'Neighbor-5G',
    'aa:bb:cc:dd:ee:03': 'xfinitywifi',
    'aa:bb:cc:dd:ee:04': 'Printer-2.4',
  };
  String? _disturbBssid;
  int _disturbLeft = 0;

  @override
  Future<List<WifiApReading>> pollFast() async {
    // Occasionally start a disturbance on a random AP.
    if (_disturbLeft == 0 && _rng.nextDouble() < 0.04) {
      final keys = _base.keys.toList();
      _disturbBssid = keys[_rng.nextInt(keys.length)];
      _disturbLeft = 3 + _rng.nextInt(4);
    }
    final out = <WifiApReading>[];
    var first = true;
    for (final e in _base.entries) {
      var rssi = e.value + _rng.nextDouble() * 3 - 1.5;
      if (e.key == _disturbBssid && _disturbLeft > 0) {
        rssi -= 8 + _rng.nextDouble() * 7;
      }
      out.add(WifiApReading(
        ssid: _ssids[e.key]!,
        bssid: e.key,
        rssiDbm: rssi,
        isConnected: first,
      ));
      first = false;
    }
    if (_disturbLeft > 0) _disturbLeft--;
    return out;
  }

  @override
  Future<List<WifiApReading>> pollSurvey() async => pollFast();
}

/// A known AP with the time its reading was last refreshed.
class _ApEntry {
  _ApEntry(this.reading, this.lastSeen);

  WifiApReading reading;
  DateTime lastSeen;
}

/// Owns polling, per-AP baselines, and disturbance flags.
class WifiVisionService {
  WifiRssiSource _sourceFor(bool simulate) {
    if (simulate) return SimulatedWifiSource();
    if (Platform.isWindows) return NetshWifiSource();
    // Android/iOS/macOS/Linux: no verified source yet — simulate
    // rather than silently returning nothing.
    return SimulatedWifiSource();
  }

  WifiRssiSource? _source;
  Timer? _timer;
  int _tick = 0;

  /// Latest reading per known AP — merged across polls, not replaced,
  /// so the field view stays populated between 20 s neighbor surveys.
  final List<WifiApReading> readings = [];
  final Map<String, _WifiBaseline> _baselines = {};

  /// BSSIDs currently in a disturbed state. Persistent per-AP: a flag is
  /// only cleared when that AP is re-sampled and reads clean.
  final Set<String> disturbedBssids = {};

  /// Known-AP registry: BSSID -> latest reading + last-seen time.
  /// Fast polls refresh the connected AP every second; surveys merge in
  /// neighbors every ~20 s; entries unseen for [apMaxAge] are dropped.
  final Map<String, _ApEntry> _registry = {};

  /// APs unseen for longer than this are dropped from the registry.
  Duration apMaxAge = const Duration(seconds: 120);

  double _dipThresholdDb = 6.0;

  /// Dip depth (dB below rolling median) that counts as a disturbance.
  /// Changing it re-warms the per-AP baselines.
  double get dipThresholdDb => _dipThresholdDb;
  set dipThresholdDb(double v) {
    if (v != _dipThresholdDb) {
      _dipThresholdDb = v;
      _baselines.clear();
    }
  }
  final List<double> connectedHistory = [];
  String? error;
  bool get running => _timer != null;
  bool get simulated => _source is SimulatedWifiSource;

  /// Disturbance episodes, WiFi tripwire parity with the radio side.
  /// [activeCrossings]: currently disturbed, keyed by BSSID.
  /// [crossings]: closed episodes, most recent first (cap 30).
  final Map<String, WifiCrossingEvent> activeCrossings = {};
  final List<WifiCrossingEvent> crossings = [];

  /// Defensive threat detection: rogue AP (evil twin) suspicion and
  /// disconnect-burst (deauth-pattern) recognition. Detect-only —
  /// nothing here transmits.
  final WifiThreatDetector threats = WifiThreatDetector();

  /// Alert-first state for the banner: true while any AP is disturbed.
  bool get wifiDetected => activeCrossings.isNotEmpty;

  /// Rough attribution by elimination — the closest honest "where":
  /// a lone disturbed AP puts the disturbance somewhere on that link
  /// path (bearing unknown); simultaneous disturbances on 2+ APs share
  /// only one common element — this device's receiver — so the
  /// disturbance is near this device.
  String? get disturbanceAttribution {
    if (activeCrossings.isEmpty) return null;
    if (activeCrossings.length == 1) {
      final e = activeCrossings.values.first;
      return 'LINK PATH — THIS DEVICE ↔ ${e.ssid}';
    }
    return
        'NEAR THIS DEVICE (${activeCrossings.length} APS DISTURBED)';
  }

  /// BLE witness correlation: if the last manual BLE scan ran inside
  /// this crossing's time window and saw a VERY CLOSE (≥ −60 dBm)
  /// broadcaster, name it. Two sensors agreeing beats one guessing;
  /// null means no witness, not "nothing there".
  String? bleCorrelationFor(WifiCrossingEvent e) {
    final at = ble.scannedAt;
    if (at == null) return null;
    final end = e.endTime ?? DateTime.now();
    if (at.isBefore(e.startTime) || at.isAfter(end)) return null;
    BleNearbyDevice? best;
    for (final d in ble.devices) {
      if (d.rssiDbm >= -60 &&
          (best == null || d.rssiDbm > best.rssiDbm)) {
        best = d;
      }
    }
    return best?.name;
  }

  /// Nearby wireless (BLE) device discovery. Manual — tap SCAN.
  /// Passive scan only; never connects to anything.
  final BleScanService ble = BleScanService();

  /// LAN device sweep (ARP scan of the local subnet). Manual — tap SCAN.
  /// This shows devices on the local network, not per-AP associations:
  /// a stock adapter cannot see which AP a device uses.
  final List<LanDevice> lanDevices = [];
  bool lanScanning = false;
  String? lanError;
  String? lanSubnet;
  DateTime? lanScannedAt;

  Future<void> scanLan() async {
    if (lanScanning) return;
    lanScanning = true;
    lanError = null;
    onUpdate?.call();
    try {
      if (simulated) {
        // Demo data so the panel isn't dead in simulated mode.
        await Future<void>.delayed(const Duration(seconds: 1));
        lanDevices
          ..clear()
          ..addAll(LanScanner.simulatedDevices());
        lanSubnet = '192.168.1.0/24 (simulated)';
      } else {
        final result = await LanScanner.scan();
        lanDevices
          ..clear()
          ..addAll(result.devices);
        lanSubnet = result.subnet;
      }
      lanScannedAt = DateTime.now();
    } on LanScanException catch (e) {
      lanError = e.message;
    } catch (e) {
      lanError = 'SCAN FAILED: $e';
    } finally {
      lanScanning = false;
      onUpdate?.call();
    }
  }

  /// Called after each poll so the UI can refresh.
  void Function()? onUpdate;

  void start({required bool simulate, WifiRssiSource? sourceOverride}) {
    stop();
    _source = sourceOverride ?? _sourceFor(simulate);
    ble.onUpdate = onUpdate;
    threats.onChanged = () => onUpdate?.call();
    // ignore: unawaited_futures — trust registry merges in when ready.
    threats.load();
    error = null;
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    readings.clear();
    disturbedBssids.clear();
    _registry.clear();
    connectedHistory.clear();
    activeCrossings.clear();
    crossings.clear();
    _baselines.clear();
    lanDevices.clear();
    lanSubnet = null;
    lanScannedAt = null;
    lanError = null;
    lanScanning = false;
    ble.clear();
    threats.reset();
  }

  Future<void> _poll() async {
    final src = _source;
    if (src == null) return;
    try {
      _tick++;
      final isSurvey = _tick % 20 == 1 && _tick > 1;
      List<WifiApReading> fresh;
      if (isSurvey) {
        // Slow neighbor survey every ~20 s.
        fresh = await src.pollSurvey();
      } else {
        fresh = await src.pollFast();
      }
      ingest(fresh, survey: isSurvey);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    onUpdate?.call();
  }

  /// Feed one batch of readings through baselines and crossing tracking.
  /// Split out from [_poll] so tests can drive it without the timer.
  /// [survey] marks slow-cadence (~20 s) neighbor-survey batches so the
  /// baseline can confirm a solid single sample instead of waiting for a
  /// streak that would take 40 s to form.
  void ingest(List<WifiApReading> fresh, {bool survey = false}) {
    final now = DateTime.now();
    for (final r in fresh) {
      _registry[r.bssid] = _ApEntry(r, now);
    }
    _registry.removeWhere(
        (k, v) => now.difference(v.lastSeen) > apMaxAge);
    // An AP that vanished while flagged (powered off, out of range) can
    // never be re-sampled "clean", so close its episode here instead of
    // leaving the DETECTED state stuck on forever.
    for (final k in activeCrossings.keys
        .where((k) => !_registry.containsKey(k))
        .toList()) {
      final done = activeCrossings.remove(k);
      disturbedBssids.remove(k);
      if (done != null) {
        done.endTime = now;
        crossings.insert(0, done);
        if (crossings.length > 30) crossings.removeLast();
      }
    }
    disturbedBssids.removeWhere((k) => !_registry.containsKey(k));
    readings
      ..clear()
      ..addAll(_registry.values.map((e) => e.reading));
    String? connectedBssid;
    for (final r in fresh) {
      if (r.isConnected) {
        connectedBssid = r.bssid;
        break;
      }
    }
    threats.ingest(fresh,
        survey: survey, connectedBssid: connectedBssid, now: now);
    for (final r in fresh) {
      final b = _baselines.putIfAbsent(
          r.bssid, () => _WifiBaseline(dipThresholdDb: dipThresholdDb));
      final was = b.disturbed;
      b.add(r.rssiDbm, survey: survey);
      if (b.disturbed) {
        disturbedBssids.add(r.bssid);
        final open = activeCrossings[r.bssid];
        if (open == null) {
          activeCrossings[r.bssid] = WifiCrossingEvent(
            bssid: r.bssid,
            ssid: r.ssid,
            startTime: DateTime.now(),
            peakDipDb: b.lastDepthDb,
          );
        } else {
          open.peakDipDb =
              math.max(open.peakDipDb, b.lastDepthDb);
        }
      } else if (was) {
        // Re-sampled and clean: clear the flag (it was never removed
        // before, so an AP stayed "hot" in the UI for the whole session).
        disturbedBssids.remove(r.bssid);
        final done = activeCrossings.remove(r.bssid);
        if (done != null) {
          done.endTime = DateTime.now();
          crossings.insert(0, done);
          if (crossings.length > 30) crossings.removeLast();
        }
      }
      if (r.isConnected) {
        connectedHistory.add(r.rssiDbm);
        if (connectedHistory.length > 90) {
          connectedHistory.removeAt(0);
        }
      }
    }
  }
}
