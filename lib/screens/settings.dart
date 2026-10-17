import 'package:flutter/material.dart';

import '../services/discovery.dart';
import '../services/radio_driver.dart';
import '../services/recorder.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Settings: radio manager (multi-driver), detector tuning, Wi-Fi
/// sensing, mode toggles, and LAN radio discovery. Dark mode only.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _subnet;
  late final TextEditingController _interval;
  late final TextEditingController _threshold;
  late final TextEditingController _wifiThreshold;
  late final TextEditingController _confirm;
  late final TextEditingController _window;
  late final TextEditingController _newAddress;
  late final TextEditingController _newLabel;
  late final TextEditingController _zmetaHost;
  late final TextEditingController _zmetaPort;
  late final TextEditingController _zmetaPlatform;
  late bool _simulated;
  late bool _wifiVision;
  late bool _zmetaEnabled;
  late bool _zmetaSecured;
  late bool _camera;
  String _newDriverId = 'silvus';

  bool _scanning = false;
  double _scanProgress = 0;
  List<DiscoveredRadio> _found = [];
  String? _scanError;

  /// True for loopback targets, where no wire is involved.
  static bool _isLocalHost(String h) =>
      h == '127.0.0.1' || h == '::1' || h.toLowerCase() == 'localhost';

  @override
  void initState() {
    super.initState();
    final s = widget.state.settings;
    _subnet = TextEditingController(text: s.subnet);
    _interval = TextEditingController(text: s.pollInterval.toString());
    _threshold = TextEditingController(text: s.dipThreshold.toString());
    _wifiThreshold =
        TextEditingController(text: s.wifiDipThresholdDb.toString());
    _confirm = TextEditingController(text: s.confirmPolls.toString());
    _window = TextEditingController(text: s.baselineWindow.toString());
    _newAddress = TextEditingController();
    _newLabel = TextEditingController();
    _zmetaHost = TextEditingController(text: s.zmetaHost);
    _zmetaPort = TextEditingController(text: s.zmetaPort.toString());
    _zmetaPlatform = TextEditingController(text: s.zmetaPlatformId);
    _simulated = s.simulatedMode;
    _zmetaEnabled = s.zmetaEnabled;
    _zmetaSecured = s.zmetaSecured;
    _camera = widget.state.cameraConfirmationEnabled;
    _wifiVision = widget.state.wifiVisionEnabled;
  }

  @override
  void dispose() {
    _subnet.dispose();
    _interval.dispose();
    _threshold.dispose();
    _wifiThreshold.dispose();
    _confirm.dispose();
    _window.dispose();
    _newAddress.dispose();
    _newLabel.dispose();
    _zmetaHost.dispose();
    _zmetaPort.dispose();
    _zmetaPlatform.dispose();
    super.dispose();
  }

  void _save() {
    final s = AppSettings(
      subnet: _subnet.text.trim(),
      pollInterval:
          (double.tryParse(_interval.text.trim()) ?? 0.25).clamp(0.1, 60.0),
      dipThreshold:
          double.tryParse(_threshold.text.trim()) ?? widget.state.settings.dipThreshold,
      wifiDipThresholdDb:
          (double.tryParse(_wifiThreshold.text.trim()) ??
                  widget.state.settings.wifiDipThresholdDb)
              .clamp(3.0, 12.0),
      confirmPolls:
          (int.tryParse(_confirm.text.trim()) ?? widget.state.settings.confirmPolls)
              .clamp(1, 5),
      baselineWindow:
          int.tryParse(_window.text.trim()) ?? widget.state.settings.baselineWindow,
      simulatedMode: _simulated,
      zmetaEnabled: _zmetaEnabled,
      zmetaHost: _zmetaHost.text.trim().isEmpty
          ? '127.0.0.1'
          : _zmetaHost.text.trim(),
      zmetaPort:
          (int.tryParse(_zmetaPort.text.trim()) ?? 5555).clamp(1, 65535),
      zmetaPlatformId: _zmetaPlatform.text.trim().isEmpty
          ? 'shepherd-mesh-1'
          : _zmetaPlatform.text.trim(),
      zmetaSecured: _zmetaSecured,
    );
    widget.state.applySettings(s);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings applied')),
    );
  }

  Future<void> _addRadio() async {
    final type = driverTypes.firstWhere((t) => t.id == _newDriverId);
    if (!type.implemented) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${type.label} telemetry not yet implemented')),
      );
      return;
    }
    final address = _newAddress.text.trim();
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the radio address (IP)')),
      );
      return;
    }
    await widget.state.addRadio(RadioConfig(
      driverId: _newDriverId,
      address: address,
      label: _newLabel.text.trim(),
      pollInterval:
          (double.tryParse(_interval.text.trim()) ?? 0.25).clamp(0.1, 60.0),
    ));
    _newAddress.clear();
    _newLabel.clear();
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _found = [];
      _scanError = null;
    });
    try {
      final found = await RadioDiscovery.scanSubnet(
        _subnet.text.trim(),
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _scanProgress = total == 0 ? 0 : done / total);
          }
        },
      );
      if (mounted) setState(() => _found = found);
    } catch (e) {
      if (mounted) setState(() => _scanError = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _section('Radios', [
          Text(
            'EACH RADIO IS POLLED INDEPENDENTLY ON ITS OWN TIMER. '
            'NODE IDS ARE NAMESPACED PER DRIVER, SO MESHES NEVER COLLIDE. '
            'IN SIMULATED MODE THIS LIST IS IGNORED.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          for (int i = 0;
              i < widget.state.radioConfigs.length;
              i++)
            _radioRow(i),
          if (widget.state.radioConfigs.isEmpty)
            Text('NO RADIOS CONFIGURED.',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.muted)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _newDriverId,
                  dropdownColor: SentryColors.surface2,
                  style: SentryType.rowValue(SentryColors.onDark),
                  decoration: const InputDecoration(
                      labelText: 'DRIVER'),
                  items: [
                    for (final t in driverTypes)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text(
                            '${t.label}${t.implemented ? '' : ' (SOON)'}'),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _newDriverId = v ?? 'silvus';
                    // The SDR bridge talks to this app on UDP; prefill
                    // the listen endpoint so it is one tap, not a guess.
                    if (_newDriverId == 'sdr' &&
                        _newAddress.text.trim().isEmpty) {
                      _newAddress.text = '127.0.0.1:49161';
                    }
                    // KrakenSDR web UI default.
                    if (_newDriverId == 'kraken' &&
                        _newAddress.text.trim().isEmpty) {
                      _newAddress.text = '127.0.0.1:8081';
                    }
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _field(
                    _newAddress, 'Address (IP)', 'e.g. 172.17.97.182'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _field(
                    _newLabel, 'Label (optional)', 'e.g. North ridge'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _addRadio,
                  child: const Text('Add radio'),
                ),
              ),
            ],
          ),
        ]),
        _section('Detector', [
          _field(_interval, 'Poll interval, seconds (sim + default for new radios)', 'e.g. 0.25',
              numeric: true),
          const SizedBox(height: 10),
          _field(_threshold, 'Dip threshold (radio units, est.)', 'e.g. 6.0',
              numeric: true),
          const SizedBox(height: 10),
          _field(_confirm, 'Confirm polls — lower is faster, higher is calmer (1–5)',
              'e.g. 2',
              numeric: true),
          const SizedBox(height: 10),
          _field(_window, 'Baseline window (polls)', 'e.g. 60', numeric: true),
        ]),
        _section('Wi-Fi sensing', [
          _field(
              _wifiThreshold,
              'Dip threshold (dB, 3–12 — lower is more sensitive, higher is calmer)',
              'e.g. 6.0',
              numeric: true),
        ]),
        _section('Mode', [
          SwitchListTile(
            title: Text('SIMULATED MODE', style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'GENERATE SYNTHETIC LINK DATA — NO HARDWARE NEEDED. '
              'CLEARLY LABELED ON THE DASHBOARD.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _simulated,
            onChanged: (v) => setState(() => _simulated = v),
          ),
          SwitchListTile(
            title: Text('WI-FI VISION', style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'USE THIS DEVICE\'S WI-FI ADAPTER AS AN AMBIENT DISTURBANCE SENSOR. '
              'COARSE RSSI SENSING — DETECTS DISTURBANCES, CANNOT IMAGE OBJECTS.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _wifiVision,
            onChanged: (v) {
              setState(() => _wifiVision = v);
              widget.state.toggleWifiVision(v);
            },
          ),
          SwitchListTile(
            title: Text('CAMERA CONFIRMATION (UPGRADE)',
                style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'STUB — NO CAMERA CODE SHIPS YET. WHEN WIRED, CAMERA '
              'EVIDENCE MAY UPGRADE DISPLAYED CONFIDENCE BUT MUST '
              'NEVER VETO OR SUPPRESS A DETECTION.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _camera,
            onChanged: (v) {
              setState(() => _camera = v);
              widget.state.toggleCameraConfirmation(v);
            },
          ),
        ]),
        _section('Record & replay', [
          _recordRow(),
          const SizedBox(height: 10),
          _replayList(),
        ]),
        _section('ZMeta export', [
          SwitchListTile(
            title: Text('EMIT ZMETA EVENTS',
                style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'SEND EACH DETECTION TO A ZMETA GATEWAY AS OBSERVATION / INFERENCE EVENTS (UDP, EMIT-ONLY). '
              'ONE MESH = ONE PLATFORM ID — THE GATEWAY FUSES ACROSS MESHES.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _zmetaEnabled,
            onChanged: (v) => setState(() => _zmetaEnabled = v),
          ),
          if (_zmetaEnabled) ...[
            const SizedBox(height: 10),
            _field(_zmetaHost, 'Gateway host', 'e.g. 127.0.0.1'),
            const SizedBox(height: 10),
            _field(_zmetaPort, 'Gateway UDP port', 'e.g. 5555',
                numeric: true),
            const SizedBox(height: 10),
            _field(_zmetaPlatform, 'Platform ID (this mesh)',
                'e.g. shepherd-mesh-1'),
            const SizedBox(height: 10),
            SwitchListTile(
              title: Text('LINK SECURED (WIREGUARD)',
                  style: SentryType.rowValue(SentryColors.onDark)),
              subtitle: Text(
                'CONFIRM THE WIREGUARD TUNNEL TO THE GATEWAY IS ACTIVE. '
                'THE APP CANNOT VERIFY THIS ITSELF.',
                style: SentryType.section(10).copyWith(height: 1.6),
              ),
              value: _zmetaSecured,
              onChanged: (v) => setState(() => _zmetaSecured = v),
            ),
            if (_zmetaHost.text.trim().isNotEmpty &&
                !_isLocalHost(_zmetaHost.text.trim()) &&
                !_zmetaSecured)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'WARNING: EXPORTING DETECTIONS TO A NON-LOCAL HOST WITHOUT '
                  'A SECURED LINK. ACTIVATE THE WIREGUARD TUNNEL '
                  '(SEE zmeta_secure/) OR EXPECT INTERCEPTION AND SPOOFING.',
                  style: SentryType.section(10).copyWith(
                      height: 1.6, color: SentryColors.red),
                ),
              ),
          ],
        ]),
        _section('Find radios on LAN', [
          _field(_subnet, 'Discovery subnet (CIDR)', 'e.g. 172.17.97.0/24'),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _scanning ? null : _scan,
            child: Text(_scanning ? 'Scanning…' : 'Scan subnet'),
          ),
          if (_scanning) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _scanProgress),
          ],
          if (_scanError != null) ...[
            const SizedBox(height: 8),
            Text(_scanError!,
                style: const TextStyle(color: SentryColors.red)),
          ],
          for (final r in _found)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.router, color: SentryColors.blue),
              title: Text(r.label, style: SentryType.rowValue(SentryColors.onDark)),
              subtitle: Text('TAP TO ADD AS SILVUS RADIO',
                  style: SentryType.section(10)),
              onTap: () async {
                await widget.state.addRadio(RadioConfig(
                  driverId: 'silvus',
                  address: r.ip,
                  label: r.label,
                  pollInterval: (double.tryParse(_interval.text.trim()) ?? 0.25)
                      .clamp(0.1, 60.0),
                ));
                if (mounted) setState(() {});
              },
            ),
          if (!_scanning && _found.isEmpty && _scanError == null)
            Text(
              'NO SCAN YET. RADIOS MUST BE ON THIS SUBNET AND REACHABLE OVER HTTP.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
        ]),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: _save, child: const Text('Save settings')),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _radioRow(int i) {
    final c = widget.state.radioConfigs[i];
    final st = widget.state.statusFor(c);
    final type = driverTypes.firstWhere((t) => t.id == c.driverId,
        orElse: () => (id: c.driverId, label: c.driverId.toUpperCase(), implemented: true));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: driverColor(c.driverId),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.displayLabel,
                  style: SentryType.rowValue(SentryColors.onDark)
                      .copyWith(fontSize: 12),
                ),
                Text(
                  st?.error ??
                      (st?.lastPoll == null
                          ? 'NOT POLLING'
                          : '${st!.linkCount} LINKS'),
                  style: SentryType.section(10).copyWith(
                      color: st?.error != null
                          ? SentryColors.red
                          : SentryColors.muted),
                ),
              ],
            ),
          ),
          if (!type.implemented)
            Text('SOON',
                style: SentryType.section(10)
                    .copyWith(color: SentryColors.orange))
          else
            Switch(
              value: c.enabled,
              activeThumbColor: SentryColors.green,
              onChanged: (v) async {
                await widget.state.setRadioEnabled(i, v);
                if (mounted) setState(() {});
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: SentryColors.muted, size: 20),
            onPressed: () async {
              await widget.state.removeRadioAt(i);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _recordRow() {
    final st = widget.state;
    final recording = st.isRecording;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SESSION RECORDING',
                  style: SentryType.rowValue(SentryColors.onDark)),
              Text(
                recording
                    ? 'RECORDING RAW LINK DATA…'
                    : 'CAPTURE RAW SAMPLES TO CSV FOR LATER REPLAY.',
                style: SentryType.section(10).copyWith(height: 1.6),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () async {
            if (recording) {
              final summary = await st.stopRecording();
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(summary)));
                setState(() {});
              }
            } else {
              await st.startRecording();
              if (mounted) setState(() {});
            }
          },
          child: Text(recording ? 'STOP' : 'RECORD',
              style: const TextStyle(color: SentryColors.purple)),
        ),
      ],
    );
  }

  Widget _replayList() {
    final st = widget.state;
    return FutureBuilder(
      future: RecordingService.listRecordings(),
      builder: (context, snap) {
        final files = snap.data ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('REPLAY A RECORDING',
                    style: SentryType.rowValue(SentryColors.onDark)),
                const Spacer(),
                if (st.replaying)
                  TextButton(
                    onPressed: () {
                      st.stopReplay();
                      setState(() {});
                    },
                    child: const Text('STOP REPLAY',
                        style: TextStyle(color: SentryColors.red)),
                  ),
              ],
            ),
            Text(
              'RUNS THE RECORDING THROUGH THE LIVE DETECTOR — TUNE '
              'THRESHOLDS, THEN REPLAY TO SEE WHAT THE NEW SETTINGS '
              'WOULD HAVE CAUGHT.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            const SizedBox(height: 6),
            if (files.isEmpty)
              Text('NO RECORDINGS YET',
                  style: SentryType.rowLabel()),
            for (final f in files.take(10))
              InkWell(
                onTap: st.replaying
                    ? null
                    : () async {
                        await st.startReplay(f.path);
                        if (mounted) setState(() {});
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.play_arrow,
                          color: SentryColors.purple, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.path.split('/').last,
                          style: SentryType.rowValue(SentryColors.onDark)
                              .copyWith(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return SentryPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: SentryType.section()),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint,
      {bool numeric = false}) {
    return TextField(
      controller: c,
      style: SentryType.rowValue(SentryColors.onDark),
      decoration:
          InputDecoration(labelText: label.toUpperCase(), hintText: hint),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
    );
  }
}
