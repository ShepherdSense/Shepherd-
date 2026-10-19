import 'dart:async';
import 'dart:io';

import 'silvus_api.dart';

/// A device a watcher validated with its family's real protocol
/// handshake. Only validated candidates ever become radio configs —
/// an unvalidated candidate is invisible, exactly like an unvalidated
/// LAN-scan hit.
class AutoConnectCandidate {
  const AutoConnectCandidate({
    required this.familyId,
    required this.address,
    required this.label,
  });

  /// Matches RadioConfig.driverId ('silvus' | 'mpu5' | ...).
  final String familyId;

  /// Transport address for RadioConfig.address (IP for Silvus).
  final String address;
  final String label;
}

/// One device family. Each watcher owns its detection mechanism and
/// its validation handshake; the coordinator owns the timer and the
/// dedupe/add policy. Watchers never transmit beyond the family's own
/// handshake — detection is RX-only.
abstract class DeviceWatcher {
  String get familyId;

  /// One poll tick. Returns validated candidates only.
  Future<List<AutoConnectCandidate>> poll();
}

/// Silvus USB watcher.
///
/// A Silvus radio plugged in over USB-C presents as a host network
/// interface in 172.17.97.0/24 (the radio answers at 172.17.97.182).
/// The watcher polls the interface list and, only when that subnet is
/// present, validates the radio with a real `streamscape_data`
/// handshake before reporting it. No subnet is ever scanned.
class SilvusUsbWatcher extends DeviceWatcher {
  SilvusUsbWatcher({
    Future<List<String>> Function()? listInterfaceAddresses,
    Future<bool> Function(String ip)? validate,
    Set<String> Function()? knownAddresses,
  })  : _listAddrs = listInterfaceAddresses ?? _defaultListAddrs,
        _validate = validate ?? _defaultValidate,
        _knownAddresses = knownAddresses ?? _noKnown;

  /// Silvus USB-CDC subnet (field setup: Radio 1 @ .182).
  static const usbSubnetPrefix = '172.17.97.';

  /// Well-known Silvus USB address. Probed only when the USB subnet
  /// is present on this host — never a blind scan.
  static const usbDefaultIp = '172.17.97.182';

  /// Test seam: interface addresses on this host.
  final Future<List<String>> Function() _listAddrs;

  /// Test seam: the real handshake is a streamscape_data probe.
  final Future<bool> Function(String ip) _validate;

  /// Addresses already configured (dedupe). Skips the handshake for
  /// known radios — re-validating a radio that is already being
  /// polled every 250 ms would be a needless handshake every 5 s.
  /// Replug needs no re-validation: the config is never deleted, so
  /// the existing poller resumes on its own.
  final Set<String> Function() _knownAddresses;
  static Set<String> _noKnown() => const {};

  /// Default seam: flatten NetworkInterface.list() to addresses.
  static Future<List<String>> _defaultListAddrs() async {
    final ifs = await NetworkInterface.list();
    return [for (final i in ifs) for (final a in i.addresses) a.address];
  }

  /// Real validation: the host answers like a Silvus radio.
  static Future<bool> _defaultValidate(String ip) {
    final api = SilvusApi(ip: ip, timeout: const Duration(seconds: 4));
    return api.probe().then((ok) {
      api.close();
      return ok;
    }).catchError((Object _) {
      api.close();
      return false;
    });
  }

  @override
  String get familyId => 'silvus';

  /// Pure function, unit-tested: interface addresses -> USB link present?
  static bool hasUsbLink(Iterable<String> ifAddrs) =>
      ifAddrs.any((a) => a.startsWith(usbSubnetPrefix));

  @override
  Future<List<AutoConnectCandidate>> poll() async {
    late final List<String> addrs;
    try {
      addrs = await _listAddrs();
    } catch (_) {
      return const [];
    }
    if (!hasUsbLink(addrs)) return const [];
    // Already configured: skip the handshake. The existing poller
    // owns this radio; re-validating every 5 s would be noise.
    if (_knownAddresses().contains(usbDefaultIp)) return const [];
    // Validate with the real handshake before claiming anything.
    final ok = await _validate(usbDefaultIp);
    if (!ok) return const [];
    return const [
      AutoConnectCandidate(
        familyId: 'silvus',
        address: usbDefaultIp,
        label: 'Silvus USB (auto)',
      ),
    ];
  }
}

/// Coordinator: one timer, all enabled family watchers, dedupe-by-address
/// add policy.
///
/// - Never removes configs: unplug marks the driver offline through its
///   normal poll errors; the config survives for replug.
/// - Never overlaps a slow probe: a tick that is still running skips
///   the next one.
/// - Families with no watcher yet (MPU5 — driver is a stub pending
///   Draco's SNMP walk data) simply have no entry here until their
///   driver + watcher land together.
class DeviceAutoConnect {
  DeviceAutoConnect({
    required this.watchers,
    this.pollInterval = const Duration(seconds: 5),
    required this.onCandidate,
    required this.isKnown,
  });

  final List<DeviceWatcher> watchers;
  final Duration pollInterval;

  /// Called with each validated, not-yet-known candidate.
  final Future<void> Function(AutoConnectCandidate candidate) onCandidate;

  /// True when a config already exists for familyId+address (dedupe).
  final bool Function(String familyId, String address) isKnown;

  Timer? _timer;
  bool _ticking = false;

  void start() {
    stop();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      for (final w in watchers) {
        List<AutoConnectCandidate> found;
        try {
          found = await w.poll();
        } catch (_) {
          continue;
        }
        for (final c in found) {
          if (isKnown(c.familyId, c.address)) continue;
          await onCandidate(c);
        }
      }
    } finally {
      _ticking = false;
    }
  }
}
