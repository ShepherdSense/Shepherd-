import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/wifi_sense.dart';
import '../services/ble_scan.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// WiFi Vision: ambient disturbance sensing using the host device's own
/// wireless adapter (Windows: netsh; simulated otherwise).
///
/// Honest scope, stated in the UI: stock OS WiFi APIs expose only coarse
/// RSSI — no CSI — so this detects *disturbances* in the ambient WiFi
/// field. It cannot image objects, measure shapes, or fix positions.
/// The 3D view shows the sensed field (device + APs), not objects.
class WifiVisionScreen extends StatefulWidget {
  const WifiVisionScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WifiVisionScreen> createState() => _WifiVisionScreenState();
}

class _WifiVisionScreenState extends State<WifiVisionScreen> {
  /// Fullscreen WiFi field view: the 3D view fills the tab area.
  bool _fieldFullscreen = false;

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final wifi = state.wifi;
        if (_fieldFullscreen && state.wifiVisionEnabled) {
          return Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _WifiFieldView(wifi: wifi),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: _exitFullscreenChip(),
              ),
            ],
          );
        }
        if (!state.wifiVisionEnabled) {
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              SentryPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WIFI VISION', style: SentryType.section()),
                    const SizedBox(height: 8),
                    Text(
                      'AMBIENT DISTURBANCE SENSING VIA THIS DEVICE\'S OWN WI-FI ADAPTER. '
                      'ENABLE IT IN SETTINGS.',
                      style: SentryType.section(10)
                          .copyWith(height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        WifiApReading? connected;
        try {
          connected = wifi.readings
              .firstWhere((r) => r.isConnected);
        } catch (_) {
          connected = null;
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _wifiAlertPanel(wifi),
            const SizedBox(height: 12),
            _threatsCard(wifi),
            const SizedBox(height: 12),
            _activityCard(),
            const SizedBox(height: 12),
            _statusCard(wifi, connected),
            const SizedBox(height: 12),
            _traceCard(wifi, connected),
            const SizedBox(height: 12),
            _fieldCard(wifi),
            const SizedBox(height: 12),
            _apListCard(wifi),
            const SizedBox(height: 12),
            _rttCard(),
            const SizedBox(height: 12),
            _awareCard(),
            const SizedBox(height: 12),
            _lanCard(wifi),
            const SizedBox(height: 12),
            _bleCard(wifi),
            const SizedBox(height: 12),
            _crossingsCard(wifi),
            const SizedBox(height: 12),
            const _WifiScopeNote(),
          ],
        );
      },
    );
  }

  /// Alert-first banner: CLEAR vs DETECTED, mirroring the radio
  /// dashboard's observatory style. Same sensing function as the
  /// Silvus tripwire, applied to the ambient WiFi field.
  Widget _wifiAlertPanel(WifiVisionService wifi) {
    final detected = wifi.wifiDetected;
    final color =
        detected ? SentryColors.amber : SentryColors.green;
    final icon = detected
        ? Icons.warning_amber_rounded
        : Icons.shield_outlined;
    final title = detected ? 'DETECTED' : 'CLEAR';
    final n = wifi.readings.length;
    final attribution = wifi.disturbanceAttribution;
    final subtitle = detected
        ? '${wifi.activeCrossings.length} AP(S) DISTURBED'
            '${attribution == null ? '' : '\n$attribution'}'
        : n == 0
            ? 'WAITING FOR WI-FI DATA'
            : 'MONITORING $n AP(S)';
    final live = !wifi.simulated;
    return SentryPanel(
      glow: color,
      padding:
          const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Expanded: with the LIVE/SIM chip beside it, the plain
              // title could overflow narrow cards under wider font
              // metrics (14 px at 360 px in tests) — the chip keeps
              // its size, the title ellipsizes instead.
              Expanded(
                child: Text('WI-FI FIELD STATUS',
                    style: SentryType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: SentryColors.border),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: live
                            ? SentryColors.green
                            : SentryColors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      live ? 'LIVE' : 'SIM',
                      style: SentryType.chip(
                        live
                            ? SentryColors.green
                            : SentryColors.orange,
                      ).copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(icon, color: color, size: 52),
              const SizedBox(width: 16),
              Expanded(
                // FittedBox scale-down: the status word must never
                // wrap mid-word on narrow screens — at 40 pt
                // 'DETECTED' overflowed the card and broke as
                // 'DETECTE/D' (field report 2026-10-21). 28 pt fits
                // at 360 px; the box is the guarantee, not the size.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    softWrap: false,
                    style: SentryType.readout(28, color)
                        .copyWith(letterSpacing: 4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: SentryType.section(11)),
          if (detected) ...[
            const SizedBox(height: 8),
            Text(
              wifi.activeCrossings.values
                  .map((e) => e.ssid)
                  .join('  ·  '),
              style: SentryType.rowValue(SentryColors.amber)
                  .copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  /// Defensive air-threat panel: rogue AP (evil twin) suspicion and
  /// disconnect-burst (deauth-pattern) recognition. Detect-only.
  /// Honest scope is stated inline: stock adapters can't see raw
  /// 802.11 management frames, and multi-BSSID APs are normal.
  Widget _threatsCard(WifiVisionService wifi) {
    final threats = wifi.threats;
    final suspect =
        threats.rogueEvents.isNotEmpty || threats.bursts.isNotEmpty;
    final color =
        suspect ? SentryColors.red : SentryColors.green;
    return SentryPanel(
      glow: suspect ? color : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('AIR THREATS', style: SentryType.section()),
              const Spacer(),
              SentryChip(
                  label:
                      suspect ? 'THREAT SUSPECTED' : 'NO THREATS',
                  color: color),
            ],
          ),
          const SizedBox(height: 8),
          if (threats.rogueEvents.isEmpty &&
              threats.bursts.isEmpty)
            Text(
              'WATCHING FOR ROGUE ACCESS POINTS AND DEAUTH PATTERNS. '
              'NOTHING SUSPICIOUS SEEN.',
              style:
                  SentryType.section(10).copyWith(height: 1.6),
            ),
          for (final e in threats.rogueEvents) ...[
            _KVRow('ROGUE AP SUSPECT', e.ssid),
            _KVRow('SUSPECT BSSID', e.suspectBssid),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in e.reasons)
                  SentryChip(label: r, color: SentryColors.red),
                SentryChip(
                    label: e.clockLabel,
                    color: SentryColors.muted),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  threats.trust(e.ssid, e.suspectBssid);
                },
                child: Text('TRUST THIS AP',
                    style: SentryType.section(11)
                        .copyWith(color: SentryColors.purple)),
              ),
            ),
            const SizedBox(height: 4),
          ],
          for (final b in threats.bursts) ...[
            Row(
              children: [
                Text('DISCONNECT BURST',
                    style: SentryType.section(11)
                        .copyWith(color: SentryColors.red)),
                const Spacer(),
                Text('${b.flapCount} FLAPS · ${b.clockLabel}',
                    style: SentryType.section(10)
                        .copyWith(color: SentryColors.muted)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'RAPID CONNECT/DISCONNECT PATTERN — CONSISTENT WITH A DEAUTH FLOOD.',
              style:
                  SentryType.section(10).copyWith(height: 1.6),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 4),
          Text(
            'DETECT-ONLY: SHEPHERD NEVER TRANSMITS. STOCK ADAPTERS CANNOT SEE '
            'RAW 802.11 MANAGEMENT FRAMES, SO DEAUTH IS READ FROM THE '
            'DISCONNECT PATTERN (ROAMING OR SLEEP CAN CAUSE FLAPS TOO). '
            'DUAL-BAND AND MESH APS LEGITIMATELY USE SEVERAL BSSIDS — '
            'TRUST THEM WHEN PROMPTED.',
            style: SentryType.section(9)
                .copyWith(height: 1.6, color: SentryColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(WifiVisionService wifi, WifiApReading? connected) {
    final srcLabel =
        wifi.simulated ? 'SIMULATED FIELD' : 'DEVICE ADAPTER';
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('WIFI VISION', style: SentryType.section()),
              const Spacer(),
              SentryChip(
                  label: connected != null ? 'SENSING' : 'NO SIGNAL',
                  color: connected != null
                      ? SentryColors.green
                      : SentryColors.muted),
            ],
          ),
          const SizedBox(height: 8),
          _KVRow('SOURCE', srcLabel),
          if (connected != null) ...[
            _KVRow('CONNECTED TO', connected.ssid),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  connected.rssiDbm.toStringAsFixed(0),
                  style: SentryType.readout(
                      44, SentryColors.blue),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 6),
                  child: Text('dBm',
                      style: SentryType.section(11)),
                ),
                const Spacer(),
                if (wifi.disturbedBssids
                    .contains(connected.bssid))
                  const SentryChip(
                      label: 'DISTURBANCE',
                      color: SentryColors.amber),
              ],
            ),
          ] else ...[
            Text('NOT CONNECTED TO WI-FI — JOIN A NETWORK TO SENSE.',
                style:
                    SentryType.section(10).copyWith(height: 1.6)),
          ],
          if (wifi.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(wifi.error!,
                  style: SentryType.section(10)
                      .copyWith(color: SentryColors.red)),
            ),
        ],
      ),
    );
  }

  Widget _traceCard(
      WifiVisionService wifi, WifiApReading? connected) {
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LIVE RSSI — CONNECTED AP',
              style: SentryType.section()),
          const SizedBox(height: 4),
          Text('90-SECOND WINDOW. DIPS = FIELD DISTURBANCE.',
              style: SentryType.section(10)),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: CustomPaint(
              painter: _RssiTracePainter(
                  wifi.connectedHistory, wifi.simulated),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldCard(WifiVisionService wifi) {
    return SentryPanel(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                Text('FIELD VIEW',
                    style: SentryType.section()),
                const Spacer(),
                IconButton(
                  tooltip: 'FULLSCREEN',
                  icon: const Icon(Icons.fullscreen,
                      color: SentryColors.muted, size: 20),
                  onPressed: () =>
                      setState(() => _fieldFullscreen = true),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              'DEVICE AT CENTER. AP BEARINGS UNKNOWN — PLACED BY ESTIMATED DISTANCE ONLY. '
              'AMBER = DISTURBED. DRAG TO ORBIT · SCROLL / PINCH TO ZOOM.',
              style: SentryType.section(10)
                  .copyWith(height: 1.6),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 300,
            child: _WifiFieldView(wifi: wifi),
          ),
        ],
      ),
    );
  }

  /// Floating exit-fullscreen chip shown over the fullscreen view.
  Widget _exitFullscreenChip() {
    return Material(
      color: SentryColors.surface2.withAlpha(220),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _fieldFullscreen = false),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fullscreen_exit,
                  color: SentryColors.onDark, size: 16),
              const SizedBox(width: 6),
              Text('EXIT FULLSCREEN',
                  style: SentryType.section(10)
                      .copyWith(color: SentryColors.onDark)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _apListCard(WifiVisionService wifi) {
    final aps = wifi.readings.toList()
      ..sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm));
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ACCESS POINTS', style: SentryType.section()),
          const SizedBox(height: 8),
          if (aps.isEmpty)
            Text('NO READINGS YET.',
                style: SentryType.section(10)),
          for (final ap in aps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${ap.ssid}  ·  ${ap.bssid.substring(ap.bssid.length - 5)}',
                          style: SentryType.rowValue(
                                  SentryColors.onDark)
                              .copyWith(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (wifi.disturbedBssids
                          .contains(ap.bssid))
                        const SentryChip(
                            label: 'DISTURBED',
                            color: SentryColors.amber),
                      const SizedBox(width: 8),
                      Text(
                          '${ap.rssiDbm.toStringAsFixed(0)} dBm',
                          style: SentryType.rowLabel()),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: ((ap.rssiDbm + 100) / 70)
                          .clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: SentryColors.surface2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(
                        wifi.disturbedBssids
                                .contains(ap.bssid)
                            ? SentryColors.amber
                            : SentryColors.blue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// LAN devices from the ARP subnet sweep. Shows devices on the local
  /// network — not per-AP associations, which a stock adapter cannot see.
  Widget _lanCard(WifiVisionService wifi) {
    final devices = wifi.lanDevices;
    String? scannedLabel;
    final at = wifi.lanScannedAt;
    if (at != null) {
      scannedLabel =
          '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    }
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('NETWORK DEVICES', style: SentryType.section()),
              const Spacer(),
              if (wifi.lanScanning)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child:
                      CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: wifi.scanLan,
                  style: TextButton.styleFrom(
                    foregroundColor: SentryColors.purple,
                    backgroundColor:
                        SentryColors.purple.withAlpha(28),
                  ),
                  child: const Text('SCAN'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'ARP SWEEP OF THE LOCAL SUBNET — EVERY DEVICE THIS PC CAN REACH. '
            'NOT PER-AP: A STOCK ADAPTER CANNOT SEE WHICH ACCESS POINT A DEVICE USES.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          if (wifi.lanScanning)
            Text('SWEEPING SUBNET…',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.blue))
          else if (wifi.lanError != null)
            Text(wifi.lanError!,
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.red))
          else if (devices.isEmpty)
            Text('NO SCAN YET — TAP SCAN.',
                style: SentryType.section(10))
          else ...[
            Text(
              '${wifi.lanSubnet ?? ''} · ${devices.length} DEVICE${devices.length == 1 ? '' : 'S'}'
              '${scannedLabel == null ? '' : ' · $scannedLabel'}',
              style: SentryType.section(10)
                  .copyWith(color: SentryColors.muted),
            ),
            const SizedBox(height: 6),
            for (final d in devices)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 108,
                      child: Text(d.ip,
                          style: SentryType.rowValue(
                                  SentryColors.onDark)
                              .copyWith(fontSize: 12)),
                    ),
                    Expanded(
                      child: Text(d.mac,
                          style: SentryType.rowValue(
                                  SentryColors.muted)
                              .copyWith(fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (d.isSelf)
                      const SentryChip(
                          label: 'THIS DEVICE',
                          color: SentryColors.blue),
                    if (d.isGateway)
                      const SentryChip(
                          label: 'GATEWAY',
                          color: SentryColors.green),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Nearby wireless devices via passive BLE scan. Never connects.
  /// Manual — tap SCAN. Fails soft when Bluetooth is off/absent.
  /// Fused field activity: WiFi disturbance episodes + BLE sighting
  /// history in one level. Combined sensor activity — not a person
  /// count; phone MACs randomize so BLE counts are approximate.
  Widget _activityCard() {
    final report =
        state.fieldActivity.report(state.wifi, state.wifi.ble);
    final color = report.level == 'ACTIVE'
        ? SentryColors.red
        : report.level == 'STIRRING'
            ? SentryColors.amber
            : SentryColors.green;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Expanded + ellipsis: with the level chip at ACTIVE
              // the plain title Row overflowed by 12 px at 360 px
              // (found by the DETECTED-state regression test,
              // 2026-10-21) — same fix pattern as the other headers
              // on this screen.
              Expanded(
                child: Text('FIELD ACTIVITY',
                    style: SentryType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              SentryChip(label: report.level, color: color),
            ],
          ),
          const SizedBox(height: 6),
          Text(report.detail,
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            'FUSED WI-FI DISTURBANCES + BLE SIGHTINGS. ACTIVITY LEVEL IS '
            'COMBINED SENSOR AGITATION — NOT A PERSON COUNT. PHONE MACS '
            'RANDOMIZE, SO ONE PHONE CAN LOOK LIKE SEVERAL ADVERTISERS.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  /// 802.11mc RTT ranging (Android only): true round-trip distance to
  /// responder APs, far more accurate than RSSI estimates.
  Widget _rttCard() {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final rtt = state.wifiRtt;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('WI-FI RANGING (802.11mc)',
                  style: SentryType.section()),
              const Spacer(),
              if (rtt.ranging)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child:
                      CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: () => _runRtt(),
                  style: TextButton.styleFrom(
                    foregroundColor: SentryColors.purple,
                    backgroundColor:
                        SentryColors.purple.withAlpha(28),
                  ),
                  child: const Text('RANGE'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'TRUE ROUND-TRIP-TIME DISTANCE TO RESPONDER ACCESS POINTS — '
            'NOT AN RSSI GUESS. NEEDS ANDROID 9+, RTT HARDWARE, AND APS '
            'THAT ANSWER FTM REQUESTS.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          if (rtt.supported == null)
            Text('NOT CHECKED — TAP RANGE.',
                style: SentryType.section(10))
          else if (rtt.supported == false)
            Text('NOT SUPPORTED ON THIS DEVICE.',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.muted))
          else if (rtt.error != null)
            Text(rtt.error!,
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.red))
          else if (rtt.readings.isEmpty)
            Text('NO RANGINGS YET — TAP RANGE.',
                style: SentryType.section(10))
          else
            for (final e in rtt.readings.entries)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.key,
                        style: SentryType.rowValue(
                                SentryColors.onDark)
                            .copyWith(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${e.value.meters.toStringAsFixed(1)} m '
                      '±${e.value.stddevMeters.toStringAsFixed(1)}'
                      '${e.value.is80211az ? ' · 11az' : ''}',
                      style: SentryType.rowLabel().copyWith(
                          color: SentryColors.blue),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _runRtt() async {
    final rtt = state.wifiRtt;
    rtt.onUpdate = () => state.refresh();
    await rtt.checkSupport();
    if (rtt.supported != true) return;
    final bssids = state.wifi.readings
        .map((r) => r.bssid)
        .toSet()
        .toList();
    await rtt.rangeBssids(bssids);
  }

  /// Wi-Fi Aware peer discovery (Android only) — EXPERIMENTAL.
  /// Cooperative discovery only: sees devices publishing the same
  /// service name, not strangers' phones. BLE remains the passive
  /// nearby-device sensor.
  Widget _awareCard() {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final aware = state.wifiAware;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('NEARBY WI-FI (AWARE)',
                  style: SentryType.section()),
              const SizedBox(width: 8),
              const SentryChip(
                  label: 'EXPERIMENTAL',
                  color: SentryColors.orange),
              const Spacer(),
              if (aware.discovering)
                TextButton(
                  onPressed: () => _stopAware(),
                  child: const Text('STOP'),
                )
              else
                TextButton(
                  onPressed: () => _startAware(),
                  style: TextButton.styleFrom(
                    foregroundColor: SentryColors.purple,
                    backgroundColor:
                        SentryColors.purple.withAlpha(28),
                  ),
                  child: const Text('DISCOVER'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'WI-FI AWARE PEER DISCOVERY. COOPERATIVE ONLY — SEES DEVICES '
            'RUNNING THE SAME SERVICE, NOT PASSIVE STRANGERS. NATIVE '
            'CODE UNVERIFIED: IF THE APP MISBEHAVES, STOP DISCOVERY.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          if (aware.available == false)
            Text('NOT SUPPORTED ON THIS DEVICE.',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.muted))
          else if (aware.error != null)
            Text(aware.error!,
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.red))
          else if (aware.peers.isEmpty)
            Text(
                aware.discovering
                    ? 'DISCOVERING…'
                    : 'NO PEERS — TAP DISCOVER.',
                style: SentryType.section(10))
          else
            Text(
              '${aware.peers.length} PEER${aware.peers.length == 1 ? '' : 'S'} '
              'ON SERVICE "shepherd"',
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontSize: 12),
            ),
        ],
      ),
    );
  }

  Future<void> _startAware() async {
    final aware = state.wifiAware;
    aware.onUpdate = () => state.refresh();
    await aware.checkAvailable();
    if (aware.available == true) {
      await aware.startDiscovery();
    }
  }

  Future<void> _stopAware() => state.wifiAware.stopDiscovery();

  /// Compact action-button style for the BLE card's Wrap row.
  static ButtonStyle _bleBtnStyle(Color c) => TextButton.styleFrom(
        foregroundColor: c,
        backgroundColor: c.withAlpha(28),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  Widget _bleCard(WifiVisionService wifi) {
    final ble = wifi.ble;
    final devices = ble.devices;
    final activeDips = ble.activeBleDips;
    String? scannedLabel;
    final at = ble.scannedAt;
    if (at != null) {
      scannedLabel =
          '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    }
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row alone, actions in a Wrap below: title + MONITOR +
          // SCAN in one Row overflowed a phone-width card by ~190 px
          // (field report 2026-10-20 — SCAN landed entirely off-screen).
          Row(
            children: [
              Expanded(
                child: Text('NEARBY WIRELESS (BLE)',
                    style: SentryType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              if (ble.scanning)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (ble.monitoring)
                TextButton(
                  onPressed: () => ble.stopMonitoring(),
                  style: _bleBtnStyle(SentryColors.red),
                  child: const Text('STOP'),
                )
              else
                TextButton(
                  onPressed: ble.scanning
                      ? null
                      : () => ble.startMonitoring(
                          simulate: wifi.simulated),
                  style: _bleBtnStyle(SentryColors.purple),
                  child: const Text('MONITOR'),
                ),
              if (!ble.monitoring && !ble.scanning)
                TextButton(
                  onPressed: () =>
                      ble.scan(simulate: wifi.simulated),
                  style: _bleBtnStyle(SentryColors.purple),
                  child: const Text('SCAN'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'PASSIVE SCAN — PHONES, EARBUDS, BEACONS AND WEARABLES THAT BROADCAST, '
            'ROUGHLY 10–30 M. NEVER CONNECTS TO ANYTHING. '
            'NOT BLUETOOTH CLASSIC: PAIRED HEADPHONES AND MICE WILL NOT APPEAR.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 6),
          Text(
            'MONITOR RUNS A PER-DEVICE TRIPWIRE: THIS PHONE/PC IS THE HOME NODE, '
            'EACH ADVERTISER A REMOTE NODE, AND A SUSTAINED RSSI DIP ON THE PATH '
            'BETWEEN YOU IS A DISTURBANCE. A DIP MEANS THE SIGNAL WEAKENED — THE '
            'DEVICE MOVED, SOMETHING PASSED BETWEEN YOU, OR AN OBSTRUCTION '
            'APPEARED. RSSI CANNOT TELL THOSE APART. ESTIMATES ONLY.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          if (ble.monitoring) ...[
            _bleMonitorBanner(activeDips.isNotEmpty),
            const SizedBox(height: 8),
          ],
          if (ble.scanning)
            Text('SCANNING…',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.blue))
          else if (ble.error != null)
            Text(ble.error!,
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.red))
          else if (devices.isEmpty && !ble.monitoring)
            Text('NO SCAN YET — TAP SCAN, OR MONITOR FOR THE TRIPWIRE.',
                style: SentryType.section(10))
          else ...[
            Text(
              '${devices.length} DEVICE${devices.length == 1 ? '' : 'S'}'
              '${scannedLabel == null ? '' : ' · $scannedLabel'}'
              '${ble.simulated ? ' · SIMULATED' : ''}',
              style: SentryType.section(10)
                  .copyWith(color: SentryColors.muted),
            ),
            const SizedBox(height: 6),
            for (final d in devices)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${d.name}  ·  ${d.id.length > 5 ? d.id.substring(d.id.length - 5) : d.id}',
                            style: SentryType.rowValue(
                                    SentryColors.onDark)
                                .copyWith(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SentryChip(
                            label: d.proximityLabel,
                            color: SentryColors.blue),
                        const SizedBox(width: 8),
                        Text(
                            '${d.rssiDbm.toStringAsFixed(0)} dBm',
                            style: SentryType.rowLabel()),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d.decoded.summary,
                      style: SentryType.section(10).copyWith(
                          color: SentryColors.purple),
                    ),
                    if (d.decoded.serviceLabels.isNotEmpty)
                      Text(
                        d.decoded.serviceLabels.join(' · '),
                        style: SentryType.section(9).copyWith(
                            color: SentryColors.muted),
                      ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: ((d.rssiDbm + 100) / 70)
                            .clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor:
                            SentryColors.surface2,
                        valueColor:
                            const AlwaysStoppedAnimation<
                                    Color>(
                                SentryColors.blue),
                      ),
                    ),
                  ],
                ),
              ),
            if (ble.monitoring || ble.bleEvents.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('BLE DISTURBANCE LOG',
                  style: SentryType.section()),
              const SizedBox(height: 6),
              if (activeDips.isEmpty && ble.bleEvents.isEmpty)
                Text('MONITORING — NO DIPS YET.',
                    style: SentryType.section(10)
                        .copyWith(color: SentryColors.muted))
              else ...[
                for (final e in activeDips)
                  _bleEventRow(e, true),
                for (final e in ble.bleEvents.take(8))
                  _bleEventRow(e, false),
              ],
            ],
          ],
        ],
      ),
    );
  }

  /// CLEAR / DETECTED banner for the BLE tripwire, mirroring the
  /// radio dashboard's observatory style.
  Widget _bleMonitorBanner(bool detected) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: detected
              ? SentryColors.amber
              : SentryColors.green,
          width: 1.5,
        ),
        color: (detected
                ? SentryColors.amber
                : SentryColors.green)
            .withAlpha(18),
      ),
      child: Row(
        children: [
          Icon(
            detected ? Icons.warning_amber : Icons.shield_outlined,
            color: detected
                ? SentryColors.amber
                : SentryColors.green,
            size: 28,
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detected ? 'DETECTED' : 'CLEAR',
                style: SentryType.rowValue(
                  detected
                      ? SentryColors.amber
                      : SentryColors.green,
                ).copyWith(
                    fontSize: 20, fontWeight: FontWeight.w800),
              ),
              Text(
                detected
                    ? 'BLE SIGNAL DIP IN PROGRESS (EST.)'
                    : 'MONITORING BLE SIGNALS',
                style: SentryType.section(10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bleEventRow(BleCrossingEvent e, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? SentryColors.amber
                  : SentryColors.green,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${e.deviceName} · DIP -${e.peakDipDb.toStringAsFixed(0)} dB EST · ${e.durationLabel}',
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(active ? 'DIPPING' : 'CLOSED',
              style: SentryType.section(10).copyWith(
                  color: active
                      ? SentryColors.amber
                      : SentryColors.muted)),
        ],
      ),
    );
  }

  /// WiFi tripwire log: ongoing disturbances first, then closed
  /// episodes with duration and peak dip — parity with the radio
  /// crossing log. Magnitude is dip depth in dB, not object size.
  Widget _crossingsCard(WifiVisionService wifi) {
    final active = wifi.activeCrossings.values.toList();
    final closed = wifi.crossings;
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DISTURBANCE LOG',
              style: SentryType.section()),
          const SizedBox(height: 8),
          if (active.isEmpty && closed.isEmpty)
            Text('NO DISTURBANCES RECORDED.',
                style: SentryType.section(10)),
          for (final e in active)
            _crossingRow(e,
                ongoing: true,
                witness: wifi.bleCorrelationFor(e)),
          for (final e in closed.take(10))
            _crossingRow(e,
                ongoing: false,
                witness: wifi.bleCorrelationFor(e)),
        ],
      ),
    );
  }

  Widget _crossingRow(WifiCrossingEvent e,
      {required bool ongoing, String? witness}) {
    final color =
        ongoing ? SentryColors.amber : SentryColors.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.ssid,
                  style: SentryType.rowValue(
                          SentryColors.onDark)
                      .copyWith(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  e.characterLabel,
                  style: SentryType.rowLabel()
                      .copyWith(
                          fontSize: 11, color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  ongoing
                      ? 'ONGOING · ${e.durationSecs.toStringAsFixed(0)}s SO FAR'
                      : 'LASTED ${e.durationSecs.toStringAsFixed(0)}s · ${e.clockLabel}',
                  style: SentryType.rowLabel()
                      .copyWith(fontSize: 11),
                ),
                if (witness != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'BLE WITNESS: $witness VERY CLOSE DURING EVENT',
                    style: SentryType.rowLabel().copyWith(
                        fontSize: 11,
                        color: SentryColors.blue),
                  ),
                ],
              ],
            ),
          ),
          if (ongoing)
            const SentryChip(
                label: 'DISTURBED',
                color: SentryColors.amber),
          const SizedBox(width: 8),
          Text(
            '−${e.peakDipDb.toStringAsFixed(0)} dB',
            style: SentryType.readout(13, color),
          ),
        ],
      ),
    );
  }
}

class _KVRow extends StatelessWidget {
  const _KVRow(this.k, this.v);

  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 128,
              child: Text(k, style: SentryType.rowLabel())),
          Expanded(
            child: Text(v,
                style: SentryType.rowValue(SentryColors.onDark),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _WifiScopeNote extends StatelessWidget {
  const _WifiScopeNote();

  @override
  Widget build(BuildContext context) {
    return SentryPanel(
      child: Text(
        'SCOPE — STOCK WI-FI ADAPTERS EXPOSE ONLY COARSE RSSI (NO CSI), SO THIS DETECTS '
        'DISTURBANCES IN THE AMBIENT WI-FI FIELD. IT CANNOT IMAGE OBJECTS, MEASURE SHAPES, '
        'OR FIX POSITIONS. DISTANCES ARE ROUGH RSSI ESTIMATES; BEARINGS ARE UNKNOWN. '
        'WI-FI CROSSING MAGNITUDE IS DIP DEPTH IN DB — NOT AN OBJECT-SIZE ESTIMATE. '
        'CONNECTED AP SENSED EVERY SECOND; NEIGHBOR SURVEY REFRESHES ~20 S. '
        'STRONG DIPS ALERT IMMEDIATELY; A SOLID SURVEY SAMPLE COUNTS ON ITS OWN. '
        'THRESHOLD IS ADJUSTABLE IN SETTINGS (3–12 DB). '
        'ATTRIBUTION IS ELIMINATION, NOT TRIANGULATION: A LONE DISTURBED AP PUTS THE '
        'DISTURBANCE SOMEWHERE ON THAT LINK PATH; SIMULTANEOUS MULTI-AP DISTURBANCE '
        'PUTS IT NEAR THIS DEVICE. SIGNAL WORDS (BRIEF/LINGERING, SHALLOW/DEEP) '
        'DESCRIBE THE DIP, NEVER THE OBJECT. '
        'NEARBY WIRELESS SEES BLE ADVERTISERS ONLY: NOT BLUETOOTH CLASSIC, NOT AN IMAGE. '
        'TRUE 3D WI-FI IMAGING NEEDS CSI-CAPABLE HARDWARE SUCH AS AN ESP32.',
        style: SentryType.section(10).copyWith(height: 1.7),
      ),
    );
  }
}

/// Compact live RSSI trace with a -6 dB disturbance band hint.
class _RssiTracePainter extends CustomPainter {
  _RssiTracePainter(this.history, this.simulated);

  final List<double> history;
  final bool simulated;

  @override
  void paint(Canvas canvas, Size size) {
    const minDb = -95.0;
    const maxDb = -30.0;
    double y(double db) =>
        size.height -
        ((db - minDb) / (maxDb - minDb)) * size.height;

    // Gridlines every 10 dB.
    final grid = Paint()
      ..color = SentryColors.border.withAlpha(120)
      ..strokeWidth = 1;
    for (var db = -90.0; db <= -40; db += 10) {
      final yy = y(db);
      canvas.drawLine(
          Offset(0, yy), Offset(size.width, yy), grid);
    }
    if (history.length < 2) return;

    final path = Path();
    for (var i = 0; i < history.length; i++) {
      final x = i / 89 * size.width;
      final yy = y(history[i].clamp(minDb, maxDb));
      if (i == 0) {
        path.moveTo(x, yy);
      } else {
        path.lineTo(x, yy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = SentryColors.blue
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);
    // Last-value dot.
    final lx = (history.length - 1) / 89 * size.width;
    canvas.drawCircle(
        Offset(lx, y(history.last.clamp(minDb, maxDb))),
        3,
        Paint()..color = SentryColors.blue);
  }

  @override
  bool shouldRepaint(covariant _RssiTracePainter old) => true;
}

// ---------------------------------------------------------------------------
// 3D field view: device at origin, APs on a ring at estimated distance.
// Bearings are unknown, so angles come from a golden spiral — the view is
// a field map, not a position fix.
// ---------------------------------------------------------------------------

class _WifiFieldView extends StatefulWidget {
  const _WifiFieldView({required this.wifi});

  final WifiVisionService wifi;

  @override
  State<_WifiFieldView> createState() => _WifiFieldViewState();
}

class _WifiFieldViewState extends State<_WifiFieldView> {
  double _azimuth = -0.7;
  double _elevation = 0.55;
  double _zoom = 1.0;
  double _baseZoom = 1.0;

  void _bumpZoom(double f) => setState(() {
        _zoom = (_zoom * f).clamp(0.5, 4.0);
      });

  void _resetView() => setState(() {
        _zoom = 1.0;
        _azimuth = -0.7;
        _elevation = 0.55;
      });

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder + explicit canvas size guarantees the scene fills
    // the panel and stays centered.
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            Listener(
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  _bumpZoom(
                      signal.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12);
                }
              },
              child: GestureDetector(
                // One recognizer drives both: drag orbits, pinch zooms.
                onScaleStart: (_) => _baseZoom = _zoom,
                onScaleUpdate: (d) => setState(() {
                  _zoom = (_baseZoom * d.scale).clamp(0.5, 4.0);
                  _azimuth += d.focalPointDelta.dx * 0.012;
                  _elevation =
                      (_elevation + d.focalPointDelta.dy * 0.012)
                          .clamp(0.08, 1.35);
                }),
                child: CustomPaint(
                  size: size,
                  painter: _WifiFieldPainter(
                    readings: widget.wifi.readings,
                    disturbed: widget.wifi.disturbedBssids,
                    azimuth: _azimuth,
                    elevation: _elevation,
                    zoom: _zoom,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: SentryZoomControls(
                onZoomIn: () => _bumpZoom(1.25),
                onZoomOut: () => _bumpZoom(1 / 1.25),
                onReset: _resetView,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _W3 {
  const _W3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
  _W3 operator -(_W3 o) => _W3(x - o.x, y - o.y, z - o.z);
  double dot(_W3 o) => x * o.x + y * o.y + z * o.z;
  double get len => math.sqrt(x * x + y * y + z * z);
  _W3 get norm {
    final l = len;
    return l < 1e-9 ? this : _W3(x / l, y / l, z / l);
  }
}

class _WifiFieldPainter extends CustomPainter {
  _WifiFieldPainter({
    required this.readings,
    required this.disturbed,
    required this.azimuth,
    required this.elevation,
    required this.zoom,
  });

  final List<WifiApReading> readings;
  final Set<String> disturbed;
  final double azimuth;
  final double elevation;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    // AP positions: ring by estimated distance, golden-spiral angle
    // (bearing unknown).
    const golden = 2.399963;
    final apPos = <WifiApReading, _W3>{};
    var i = 0;
    var maxR = 12.0;
    for (final ap in readings) {
      final r = ap.estimatedDistanceM;
      maxR = math.max(maxR, r);
      final a = i * golden;
      apPos[ap] = _W3(math.cos(a) * r, math.sin(a) * r, 1.5);
      i++;
    }

    const center = _W3(0, 0, 1);
    final dist = maxR * 2.2 + 12;
    final cam = _W3(
      center.x + dist * math.cos(elevation) * math.cos(azimuth),
      center.y + dist * math.cos(elevation) * math.sin(azimuth),
      center.z + dist * math.sin(elevation),
    );
    final fwd = (center - cam).norm;
    // right = fwd × +z ; up = right × fwd
    final right = _W3(fwd.y, -fwd.x, 0).norm;
    final up = _W3(
      right.y * fwd.z - right.z * fwd.y,
      right.z * fwd.x - right.x * fwd.z,
      right.x * fwd.y - right.y * fwd.x,
    );
    final focal = size.height * 1.15 * zoom;

    Offset? project(_W3 p) {
      final rel = p - cam;
      final cz = rel.dot(fwd);
      if (cz < 1.0) return null;
      return Offset(
        // Scene is always centered on the canvas.
        size.width / 2 + rel.dot(right) * focal / cz,
        size.height / 2 - rel.dot(up) * focal / cz,
      );
    }

    // Ground grid.
    final gridPaint = Paint()
      ..color = SentryColors.border.withAlpha(100)
      ..strokeWidth = 1;
    final g = (maxR / 10).ceil() * 10.0;
    for (var gx = -g; gx <= g; gx += 10) {
      final a = project(_W3(gx, -g, 0));
      final b = project(_W3(gx, g, 0));
      if (a != null && b != null) {
        canvas.drawLine(a, b, gridPaint);
      }
      final c = project(_W3(-g, gx, 0));
      final d = project(_W3(g, gx, 0));
      if (c != null && d != null) {
        canvas.drawLine(c, d, gridPaint);
      }
    }

    // Device marker at origin.
    final dev = project(const _W3(0, 0, 1));
    if (dev != null) {
      canvas.drawCircle(
          dev, 11, Paint()..color = SentryColors.blue.withAlpha(60));
      canvas.drawCircle(
          dev, 6, Paint()..color = SentryColors.blue);
      _label(canvas, dev, 'THIS DEVICE', SentryColors.blue);
    }

    // Disturbance halo: something is moving in the WiFi field.
    // Bearing is unknown from RSSI alone — labeled as such.
    if (dev != null && disturbed.isNotEmpty) {
      for (final rr in [20.0, 34.0, 50.0]) {
        canvas.drawCircle(
            dev,
            rr,
            Paint()
              ..color = SentryColors.amber.withAlpha(70)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      _label(canvas, dev + const Offset(0, 56),
          'DISTURBANCE — BEARING UNKNOWN', SentryColors.amber);
    }

    // APs: link line device→AP, dot, label.
    for (final entry in apPos.entries) {
      final ap = entry.key;
      final p = entry.value;
      final hot = disturbed.contains(ap.bssid);
      final s = project(p);
      if (s == null) continue;
      if (dev != null) {
        canvas.drawLine(
            dev,
            s,
            Paint()
              ..color = (hot
                      ? SentryColors.amber
                      : SentryColors.border)
                  .withAlpha(hot ? 220 : 130)
              ..strokeWidth = hot ? 2.5 : 1);
        if (hot) {
          // Disturbance glow on the link path, radio-shadow style:
          // concentric pulses at the link midpoint mark *where* the
          // field is disturbed. Bearing is still unknown — this is the
          // device↔AP path, not a position fix.
          final mid = Offset((dev.dx + s.dx) / 2, (dev.dy + s.dy) / 2);
          for (final rr in [16.0, 28.0, 42.0]) {
            canvas.drawCircle(
                mid,
                rr,
                Paint()
                  ..color = SentryColors.amber.withAlpha(70)
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2);
          }
        }
      }
      final c = hot ? SentryColors.amber : SentryColors.muted;
      canvas.drawCircle(
          s, hot ? 9 : 6, Paint()..color = c.withAlpha(50));
      canvas.drawCircle(s, hot ? 5 : 3.5, Paint()..color = c);
      _label(
          canvas,
          s,
          '${ap.ssid} ${ap.rssiDbm.toStringAsFixed(0)}dBm'
          '${hot ? ' — DISTURBED' : ''}',
          c);
    }
  }

  void _label(Canvas canvas, Offset at, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontFamily: SentryType.mono,
            letterSpacing: 1.0,
          )),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at + const Offset(10, -18));
  }

  @override
  bool shouldRepaint(covariant _WifiFieldPainter old) => true;
}
