/// Defensive WiFi threat detection: rogue AP (evil twin) suspicion and
/// disconnect-burst (deauth-pattern) recognition.
///
/// This is the defensive side only. Nothing here transmits anything.
///
/// Honest limits, stated in the UI where these surface:
/// * Stock WiFi adapters cannot capture raw 802.11 management frames, so
///   deauth *frames* are never observed — only the disconnect *pattern*
///   they (and roaming, sleep, or walking out of range) produce.
/// * Dual-band and mesh APs legitimately use several BSSIDs per SSID, so a
///   new BSSID alone is never an alert — suspicion needs persistence plus
///   a stronger signal or a security mismatch, and the user can trust it.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'wifi_sense.dart';

/// A suspected rogue / evil-twin access point: a BSSID broadcasting an
/// SSID we have previously connected to (so we know what "legit" looks
/// like), that is not trusted, and that earned suspicion.
class RogueApEvent {
  RogueApEvent({
    required this.ssid,
    required this.suspectBssid,
    required this.reasons,
    required this.time,
  });

  final String ssid;
  final String suspectBssid;

  /// Human-readable reasons, e.g. 'STRONGER SIGNAL', 'SECURITY MISMATCH'.
  final List<String> reasons;
  final DateTime time;

  String get clockLabel {
    final t = time;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}

/// A burst of rapid connect/disconnect transitions on this device's own
/// WiFi — the observable *pattern* of a deauth flood (among other
/// causes: roaming, sleep/wake, walking out of range).
class DisconnectBurstEvent {
  DisconnectBurstEvent({required this.time, required this.flapCount});

  final DateTime time;
  final int flapCount;

  String get clockLabel {
    final t = time;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}

class WifiThreatDetector {
  static const _prefsKey = 'rf_sentry_wifi_trusted_v1';
  static const _authPrefsKey = 'rf_sentry_wifi_trusted_auth_v1';

  /// SSID -> BSSIDs the user (or auto-learn) trusts. Persisted.
  final Map<String, Set<String>> trusted = {};

  /// SSID -> "auth/cipher" string of the trusted BSSID(s). Persisted.
  final Map<String, String> trustedAuth = {};

  /// Active rogue-AP suspicions (cleared by trust()).
  final List<RogueApEvent> rogueEvents = [];

  /// Recent disconnect bursts, most recent first (cap 20).
  final List<DisconnectBurstEvent> bursts = [];

  /// Fired when events change so the UI refreshes.
  void Function()? onChanged;

  // -- internal tracking --
  final Map<String, Map<String, int>> _sightings = {};
  final Map<String, Map<String, double>> _rssiEma = {};
  final Set<String> _evented = {};
  bool _wasConnected = false;
  bool _connectionSeen = false;
  final List<DateTime> _flaps = [];
  DateTime? _lastBurstAt;

  bool get threatSuspected => rogueEvents.isNotEmpty || bursts.isNotEmpty;

  /// Load persisted trust state. Fire-and-forget safe.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          trusted[e.key] =
              (e.value as List).map((v) => v.toString()).toSet();
        }
      }
      final authRaw = prefs.getString(_authPrefsKey);
      if (authRaw != null) {
        final map = jsonDecode(authRaw) as Map<String, dynamic>;
        for (final e in map.entries) {
          trustedAuth[e.key] = e.value.toString();
        }
      }
    } catch (_) {
      // Corrupt prefs: start clean rather than crash.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey,
          jsonEncode(
              trusted.map((k, v) => MapEntry(k, v.toList()))));
      await prefs.setString(
          _authPrefsKey, jsonEncode(trustedAuth));
    } catch (_) {}
  }

  /// Trust a BSSID for an SSID: clears any suspicion, persists.
  Future<void> trust(String ssid, String bssid) async {
    trusted.putIfAbsent(ssid, () => <String>{}).add(bssid);
    rogueEvents.removeWhere(
        (e) => e.ssid == ssid && e.suspectBssid == bssid);
    _evented.remove('$ssid|$bssid');
    await _persist();
    onChanged?.call();
  }

  /// Feed one batch of readings. [connectedBssid] is this device's own
  /// associated AP (null when disconnected). [survey] marks the slow
  /// neighbor-survey cadence, the only batch used for rogue evaluation.
  void ingest(
    List<WifiApReading> fresh, {
    required bool survey,
    required String? connectedBssid,
    required DateTime now,
  }) {
    _ingestConnection(connectedBssid != null, now);
    if (survey) _ingestSurvey(fresh, connectedBssid, now);
  }

  void _ingestConnection(bool connected, DateTime now) {
    if (!_connectionSeen) {
      // First observation is a starting state, not a transition: counting
      // it made the very first connect a "flap" and left a burst one
      // transition short of firing.
      _connectionSeen = true;
      _wasConnected = connected;
      return;
    }
    if (connected != _wasConnected) {
      _flaps.add(now);
      _wasConnected = connected;
    }
    _flaps.removeWhere(
        (t) => now.difference(t) > const Duration(seconds: 120));
    // 4 transitions (2 full disconnect/reconnect cycles) inside 2 min.
    if (_flaps.length >= 4 &&
        (_lastBurstAt == null ||
            now.difference(_lastBurstAt!) >
                const Duration(minutes: 5))) {
      _lastBurstAt = now;
      bursts.insert(
          0,
          DisconnectBurstEvent(
              time: now, flapCount: _flaps.length));
      if (bursts.length > 20) bursts.removeLast();
      onChanged?.call();
    }
  }

  void _ingestSurvey(
      List<WifiApReading> fresh, String? connectedBssid, DateTime now) {
    // Per-SSID sighting counts and RSSI EMAs for this survey.
    final present = <String, Set<String>>{};
    for (final r in fresh) {
      final ssid = r.ssid;
      if (ssid.isEmpty || ssid == '(hidden)') continue;
      present.putIfAbsent(ssid, () => <String>{}).add(r.bssid);
      _authSeen['$ssid|${r.bssid}'] = _authLabel(r);
      final ema = _rssiEma.putIfAbsent(ssid, () => <String, double>{});
      ema[r.bssid] = ema.containsKey(r.bssid)
          ? ema[r.bssid]! * 0.7 + r.rssiDbm * 0.3
          : r.rssiDbm;
      // The AP we chose to associate with is, by definition, the one we
      // trust for this SSID. Auto-learn it.
      if (connectedBssid != null && r.bssid == connectedBssid) {
        final t = trusted.putIfAbsent(ssid, () => <String>{});
        if (t.add(r.bssid)) {
          trustedAuth[ssid] = _authLabel(r);
          _persist();
        }
      }
    }
    // Decay sightings for BSSIDs absent from this survey.
    for (final ssid in _sightings.keys.toList()) {
      final seen = present[ssid] ?? const <String>{};
      for (final bssid in _sightings[ssid]!.keys.toList()) {
        // Present ones are counted once below with the rest of this
        // survey (they used to be counted twice per survey).
        if (!seen.contains(bssid)) {
          _sightings[ssid]!.remove(bssid);
        }
      }
    }
    for (final e in present.entries) {
      final counts =
          _sightings.putIfAbsent(e.key, () => <String, int>{});
      for (final bssid in e.value) {
        counts[bssid] = (counts[bssid] ?? 0) + 1;
      }
    }
    _evaluateRogues(now);
  }

  void _evaluateRogues(DateTime now) {
    for (final ssid in trusted.keys) {
      final known = trusted[ssid]!;
      if (known.isEmpty) continue;
      final counts = _sightings[ssid];
      final emas = _rssiEma[ssid];
      if (counts == null || emas == null) continue;
      // Strongest trusted BSSID is the "legit" reference.
      double refRssi = -1000;
      for (final b in known) {
        final e = emas[b];
        if (e != null && e > refRssi) refRssi = e;
      }
      final refAuth = trustedAuth[ssid];
      for (final bssid in counts.keys) {
        if (known.contains(bssid)) continue;
        if (_evented.contains('$ssid|$bssid')) continue;
        // Persistence first: seen in 2+ consecutive surveys, so this is
        // not a one-off scan glitch.
        if (counts[bssid]! < 2) continue;
        final reasons = <String>[];
        final ema = emas[bssid];
        if (ema != null && refRssi > -1000 && ema - refRssi >= 12) {
          reasons.add('STRONGER SIGNAL');
        }
        if (refAuth != null) {
          final suspectAuth = _authOf(ssid, bssid);
          if (suspectAuth != null && suspectAuth != refAuth) {
            reasons.add('SECURITY MISMATCH');
          }
        }
        if (reasons.isNotEmpty) {
          _evented.add('$ssid|$bssid');
          rogueEvents.add(RogueApEvent(
            ssid: ssid,
            suspectBssid: bssid,
            reasons: reasons,
            time: now,
          ));
          onChanged?.call();
        }
      }
    }
  }

  String _authLabel(WifiApReading r) =>
      '${r.auth}/${r.cipher}'.toLowerCase();

  /// Last-seen auth label for a suspect BSSID (kept simple: derived from
  /// the most recent survey sighting via the EMA table's sibling state).
  /// Stored alongside sightings to avoid re-scanning.
  final Map<String, String> _authSeen = {};

  String? _authOf(String ssid, String bssid) =>
      _authSeen['$ssid|$bssid'];

  /// Reset volatile state (events, tracking). Trust registry persists.
  void reset() {
    rogueEvents.clear();
    bursts.clear();
    _sightings.clear();
    _rssiEma.clear();
    _authSeen.clear();
    _evented.clear();
    _flaps.clear();
    _wasConnected = false;
    _connectionSeen = false;
    _lastBurstAt = null;
  }
}
