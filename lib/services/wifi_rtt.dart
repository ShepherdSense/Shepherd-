/// 802.11mc / 802.11az WiFi RTT ranging (Android only).
///
/// Uses the maintained `wifi_ftm` plugin. Measures true round-trip-time
/// distance to responder-capable access points — far more accurate than
/// RSSI-estimated distance. Requires Android 9+, a device with RTT
/// hardware, and APs that answer FTM requests.
///
/// Everything degrades gracefully: non-Android -> unsupported, plugin
/// errors -> error string, per-AP failures -> that AP is skipped.
library;

import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:wifi_ftm/wifi_ftm.dart';

/// Picks the BSSIDs to actually range from [requested] against the
/// fresh system [scan].
///
/// The wifi_ftm plugin resolves ranging targets against the scan
/// results cached by its own scanAccessPoints call, keyed by the
/// exact BSSID string Android returned — so the strings handed back
/// to startRanging must be the scan's own, not the app's registry
/// copies (which are lowercased and merged across ~20 s surveys, so
/// entries can be stale or case-mismatched). Matching here is
/// case-insensitive; the returned strings are the scan's verbatim.
/// Responder-flagged APs (802.11mc/az) sort first, then strongest
/// signal; the list is capped at [maxTargets] because Android
/// rejects oversized RTT requests.
List<String> selectRttTargets(
  List<String> requested,
  List<APScanResult> scan, {
  int maxTargets = 10,
}) {
  final wanted = requested.map((b) => b.trim().toLowerCase()).toSet();
  final hits = <APScanResult>[];
  final seen = <String>{};
  for (final ap in scan) {
    final key = ap.bssid.toLowerCase();
    if (wanted.contains(key) && seen.add(key)) hits.add(ap);
  }
  hits.sort((a, b) {
    final ra = (a.is80211mcResponder || a.is80211azResponder) ? 0 : 1;
    final rb = (b.is80211mcResponder || b.is80211azResponder) ? 0 : 1;
    if (ra != rb) return ra - rb;
    return b.level.compareTo(a.level);
  });
  return [for (final ap in hits.take(maxTargets)) ap.bssid];
}

/// Operator-readable text for a ranging/scan failure. The raw
/// exception string ("PlatformException(CODE, msg, null, null)")
/// is never shown in the UI.
String rttErrorText(Object e) {
  if (e is PlatformException) {
    switch (e.code) {
      case 'NO_MATCHING_AP':
        return 'No listed AP was in the latest Wi-Fi scan — '
            'try again in a few seconds.';
      case 'PERMISSION_DENIED':
        return 'Ranging needs location / nearby-Wi-Fi permission.';
      case 'UNSUPPORTED':
        return 'Wi-Fi RTT is not supported on this device.';
      case 'SCAN_ERROR':
        return 'Wi-Fi scan failed — try again in a few seconds.';
      default:
        return 'Ranging failed (${e.code}).';
    }
  }
  // Non-platform errors (MissingPluginException and friends) carry
  // long raw toString() forms — never interpolate them into the UI.
  return 'Ranging failed — unexpected error.';
}

class RttReading {
  const RttReading({
    required this.meters,
    required this.stddevMeters,
    required this.at,
    required this.is80211az,
  });

  final double meters;
  final double stddevMeters;
  final DateTime at;
  final bool is80211az;
}

class WifiRttService {
  final WifiFtm _ftm = WifiFtm();

  /// null = not checked yet.
  bool? supported;
  String? error;
  bool ranging = false;

  /// BSSID (lowercase) -> latest successful reading.
  final Map<String, RttReading> readings = {};

  void Function()? onUpdate;

  Future<void> checkSupport() async {
    if (!Platform.isAndroid) {
      supported = false;
      return;
    }
    try {
      supported = await _ftm.isSupported();
      final ok = await _ftm.hasPermissions();
      if (supported == true && !ok) {
        error = 'RTT hardware present but location/nearby-device '
            'permission not granted.';
      }
    } catch (e) {
      supported = false;
      error = 'RTT check failed: ${rttErrorText(e)}';
    }
    onUpdate?.call();
  }

  /// Range a batch of BSSIDs. Only successful measurements are kept.
  ///
  /// The plugin matches targets against the scan cached by its own
  /// scanAccessPoints call — ranging without scanning first always
  /// failed with NO_MATCHING_AP (field report 2026-10-21: the raw
  /// PlatformException was the card's error text). So: scan first,
  /// then range only what the fresh scan actually contains.
  Future<void> rangeBssids(List<String> bssids) async {
    if (supported != true || ranging) return;
    ranging = true;
    error = null;
    onUpdate?.call();
    try {
      final scan = await _ftm.scanAccessPoints();
      if (scan.isEmpty) {
        error = 'No Wi-Fi scan available yet — wait for the next '
            'survey and try again.';
        return;
      }
      final targets = selectRttTargets(bssids, scan);
      if (targets.isEmpty) {
        error = 'None of the listed APs are in the latest Wi-Fi '
            'scan — the list may be stale. Try again in a few seconds.';
        return;
      }
      final results = await _ftm.startRanging(targets);
      final now = DateTime.now();
      for (final r in results) {
        if (r.status == RangingStatus.success && r.distanceMm > 0) {
          readings[r.macAddress.toLowerCase()] = RttReading(
            meters: r.distanceMeters,
            stddevMeters: r.distanceStdDevMm / 1000.0,
            at: now,
            is80211az: r.is80211azResult,
          );
        }
      }
      if (readings.isEmpty) {
        error = 'No AP answered RTT — the access points may not '
            'support 802.11mc FTM.';
      }
    } catch (e) {
      error = rttErrorText(e);
    } finally {
      ranging = false;
      onUpdate?.call();
    }
  }

  void clear() {
    readings.clear();
    error = null;
  }
}
