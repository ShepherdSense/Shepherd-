/// Remote ID receive orchestration (Skydio integration P2).
///
/// Two passive receive paths feed one [RemoteIdTracker]:
///  - BLE: the existing [BleScanService] scan/monitor stream, via its
///    advertisement hook — service-data UUID 0xFFFA frames. No second
///    scan session, no connection, receive only.
///  - Wi-Fi Beacon: on Android, the Wi-Fi survey the app already runs
///    carries a `ridBeacon` byte list per BSS when the radio heard an
///    ASTM vendor element (extracted natively in MainActivity.kt —
///    API 30+ information elements; **native side uncompiled in the
///    build sandbox, like all prior Kotlin work**). This service
///    polls the same survey channel while enabled.
///
/// Honest coverage: broadcast-only (compliant civil airframes),
/// short range (BLE/Wi-Fi beacon range), and D-model military
/// airframes may broadcast nothing at all (Part 89 exemption).
/// Nothing in this file transmits anything.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'remote_id.dart';

/// Supplies Wi-Fi survey rows for RID extraction. The real
/// implementation reads the shepherd/wifi_sense channel; tests
/// inject rows directly.
typedef RidWifiSurveySource = Future<List<Map<dynamic, dynamic>>?> Function();

class RemoteIdService {
  RemoteIdService({RemoteIdTracker? tracker, RidWifiSurveySource? wifiSource})
      : tracker = tracker ?? RemoteIdTracker(),
        _wifiSource = wifiSource ?? _channelSurvey;

  final RemoteIdTracker tracker;

  /// Fired after new contact data lands (AppState refresh hook).
  void Function()? onUpdate;

  bool enabled = false;
  Timer? _wifiTimer;
  final RidWifiSurveySource _wifiSource;

  static const MethodChannel _channel = MethodChannel('shepherd/wifi_sense');

  static Future<List<Map<dynamic, dynamic>>?> _channelSurvey() async {
    try {
      return await _channel.invokeListMethod<Map<dynamic, dynamic>>('survey');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// BLE tap entry point — wire to BleScanService.advertisementHook.
  /// Filters to the Remote ID service UUID and ingests the frame.
  void onBleAdvertisement(String deviceId, Map<String, Uint8List> serviceData,
      {DateTime? at}) {
    if (!enabled) return;
    for (final entry in serviceData.entries) {
      if (!isRidServiceUuid(entry.key)) continue;
      tracker.ingestAppData(entry.value,
          sourceKey: 'ble:$deviceId',
          sourceKind: 'BLE',
          at: at ?? DateTime.now());
      onUpdate?.call();
    }
  }

  /// One Wi-Fi survey pass: pull rows, ingest any `ridBeacon`
  /// payloads (bytes begin at the ODID message counter, i.e. the
  /// app-data form the decoder accepts). Returns frames ingested.
  Future<int> pollWifiOnce({DateTime? at}) async {
    if (!enabled) return 0;
    final rows = await _wifiSource();
    if (rows == null) return 0;
    var n = 0;
    for (final row in rows) {
      final raw = row['ridBeacon'];
      if (raw is! List || raw.isEmpty) continue;
      final bytes = raw.map((e) => (e as num).toInt() & 0xFF).toList();
      final bssid = (row['bssid'] as String?) ?? 'unknown';
      tracker.ingestAppData(bytes,
          sourceKey: 'wifi:$bssid',
          sourceKind: 'WIFI',
          at: at ?? DateTime.now());
      n++;
    }
    if (n > 0) onUpdate?.call();
    return n;
  }

  /// Start/stop the Wi-Fi poll loop (BLE needs no loop — it rides
  /// scans the operator already runs). The 4 s cadence matches the
  /// Wi-Fi tab's survey rhythm; RID dynamic messages repeat at 1 Hz
  /// but the survey itself is the rate limiter, and contacts carry
  /// their age honestly.
  void setEnabled(bool on, {bool wifiCapable = true}) {
    enabled = on;
    _wifiTimer?.cancel();
    _wifiTimer = null;
    if (on && wifiCapable) {
      _wifiTimer = Timer.periodic(
          const Duration(seconds: 4), (_) => unawaited(pollWifiOnce()));
      unawaited(pollWifiOnce());
    }
    if (!on) tracker.clear();
  }

  /// Live contacts, freshest first.
  List<RidContact> get contacts => tracker.contacts(DateTime.now());

  void dispose() {
    _wifiTimer?.cancel();
    _wifiTimer = null;
  }
}
