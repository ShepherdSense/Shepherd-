import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/discovery.dart';
import '../services/adaptive_baseline.dart';
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
  late final TextEditingController _zmetaHeartbeatInterval;
  late final TextEditingController _camPort;
  late final TextEditingController _camOnvif;
  late final TextEditingController _camSnap;
  late final TextEditingController _sdrStationLat;
  late final TextEditingController _sdrStationLon;
  late final TextEditingController _sdrEnbLat;
  late final TextEditingController _sdrEnbLon;
  late final TextEditingController _sdrEnbMhz;
  late final TextEditingController _cotTakHost;
  late final TextEditingController _cotTakPort;
  late final TextEditingController _cotStaleSeconds;
  late final TextEditingController _cotPublishFloor;
  late final TextEditingController _cotCallsignPrefix;
  late final TextEditingController _cotAirTypeThreshold;
  late final TextEditingController _cotEmitterPrefix;
  late final TextEditingController _cotCoincidenceRadius;
  late final TextEditingController _cotListenMulticastGroup;
  late final TextEditingController _cotListenMulticastPort;
  late final TextEditingController _cotListenWindowSeconds;
  late bool _simulated;
  late bool _wifiVision;
  late bool _zmetaEnabled;
  late bool _zmetaSecured;
  late bool _zmetaHeartbeatEnabled;
  late bool _cotEmitEnabled;
  late bool _cotEmitUseMulticast;
  late bool _cotListenEnabled;
  late bool _camera;
  late bool _autoConnectSilvusUsb;
  late bool _calibDegraded;
  String _newDriverId = 'silvus';

  /// Last-seen calibration state: AppState notifies on every poll, so
  /// the listener only rebuilds when the calibration state actually
  /// changes.
  CalibrationState? _seenCalibState;
  String? _seenCalibNote;

  void _onAppStateChanged() {
    final st = widget.state;
    if (st.calibrationState != _seenCalibState ||
        st.calibrationNote != _seenCalibNote) {
      _seenCalibState = st.calibrationState;
      _seenCalibNote = st.calibrationNote;
      if (mounted) setState(() {});
    }
  }

  bool _scanning = false;
  double _scanProgress = 0;
  List<DiscoveredRadio> _found = [];
  String? _scanError;

  /// Cached replay listing: creating the Future in build() refires the
  /// disk scan on every rebuild. Refreshed when recordings change.
  late Future<List<File>> _replayFuture;

  void _refreshReplayList() {
    _replayFuture = RecordingService.listRecordings();
  }

  /// True for loopback targets, where no wire is involved.
  /// Canonical definition is [zmetaIsLocalHost] (services/zmeta_adapter.dart,
  /// imported via state/app_state.dart) — shared with the fail-closed
  /// emit path so the UI warning and the enforcement gate can never drift.
  static bool _isLocalHost(String h) => zmetaIsLocalHost(h);

  /// Separator-aware basename: recordings live under the documents dir,
  /// whose path uses '\' on Windows.
  static String _fileName(String p) {
    final i = p.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? p : p.substring(i + 1);
  }

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
    _zmetaHeartbeatInterval = TextEditingController(
        text: s.zmetaHeartbeatIntervalSec.toString());
    _simulated = s.simulatedMode;
    _zmetaEnabled = s.zmetaEnabled;
    _zmetaSecured = s.zmetaSecured;
    _zmetaHeartbeatEnabled = s.zmetaHeartbeatEnabled;
    _cotEmitEnabled = s.cotEmitEnabled;
    _cotEmitUseMulticast = s.cotEmitUseMulticast;
    _cotListenEnabled = s.cotListenEnabled;
    _autoConnectSilvusUsb = s.autoConnectSilvusUsb;
    _cotTakHost = TextEditingController(text: s.cotTakHost);
    _cotTakPort = TextEditingController(text: s.cotTakPort.toString());
    _cotStaleSeconds =
        TextEditingController(text: s.cotStaleSeconds.toString());
    _cotPublishFloor =
        TextEditingController(text: s.cotPublishFloor.toString());
    _cotCallsignPrefix =
        TextEditingController(text: s.cotCallsignPrefix);
    _cotAirTypeThreshold =
        TextEditingController(text: s.cotAirTypeThreshold.toString());
    _cotEmitterPrefix = TextEditingController(text: s.cotEmitterPrefix);
    _cotCoincidenceRadius =
        TextEditingController(text: s.cotCoincidenceRadiusM.toString());
    _cotListenMulticastGroup =
        TextEditingController(text: s.cotListenMulticastGroup);
    _cotListenMulticastPort =
        TextEditingController(text: s.cotListenMulticastPort.toString());
    _cotListenWindowSeconds =
        TextEditingController(text: s.cotListenWindowSeconds.toString());
    _camera = widget.state.cameraConfirmationEnabled;
    _wifiVision = widget.state.wifiVisionEnabled;
    _calibDegraded = false;
    final cam = widget.state.cameraSettings;
    _camPort = TextEditingController(text: cam.webhookPort.toString());
    _camOnvif = TextEditingController(text: cam.onvifAddress);
    _camSnap = TextEditingController(text: cam.snapshotUrlTemplate);
    final ss = widget.state.settings;
    String lat(double? v) => v == null ? '' : v.toStringAsFixed(6);
    _sdrStationLat = TextEditingController(text: lat(ss.sdrStationLat));
    _sdrStationLon = TextEditingController(text: lat(ss.sdrStationLon));
    _sdrEnbLat = TextEditingController(text: lat(ss.sdrEnbLat));
    _sdrEnbLon = TextEditingController(text: lat(ss.sdrEnbLon));
    _sdrEnbMhz = TextEditingController(
        text: ss.sdrEnbCenterMhz == null
            ? ''
            : ss.sdrEnbCenterMhz!.toStringAsFixed(1));
    _seenCalibState = widget.state.calibrationState;
    _seenCalibNote = widget.state.calibrationNote;
    widget.state.addListener(_onAppStateChanged);
    _refreshReplayList();
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
    _zmetaHeartbeatInterval.dispose();
    _camPort.dispose();
    _camOnvif.dispose();
    _camSnap.dispose();
    _sdrStationLat.dispose();
    _sdrStationLon.dispose();
    _sdrEnbLat.dispose();
    _sdrEnbLon.dispose();
    _sdrEnbMhz.dispose();
    _cotTakHost.dispose();
    _cotTakPort.dispose();
    _cotStaleSeconds.dispose();
    _cotPublishFloor.dispose();
    _cotCallsignPrefix.dispose();
    _cotAirTypeThreshold.dispose();
    _cotEmitterPrefix.dispose();
    _cotCoincidenceRadius.dispose();
    _cotListenMulticastGroup.dispose();
    _cotListenMulticastPort.dispose();
    _cotListenWindowSeconds.dispose();
    widget.state.removeListener(_onAppStateChanged);
    super.dispose();
  }

  /// Parse the SDR station / eNB fields. All four coordinates blank =
  /// unconfigured (fine); otherwise all four must parse and be in
  /// range. Returns null when the fields are invalid.
  ({double slat, double slon, double elat, double elon, double? mhz})?
      _parseSdrStation() {
    final raw = [
      _sdrStationLat.text.trim(),
      _sdrStationLon.text.trim(),
      _sdrEnbLat.text.trim(),
      _sdrEnbLon.text.trim(),
    ];
    if (raw.every((v) => v.isEmpty)) {
      final mhzRaw = _sdrEnbMhz.text.trim();
      if (mhzRaw.isNotEmpty) return null; // MHz without geometry: invalid
      return null; // unconfigured — not an error
    }
    if (raw.any((v) => v.isEmpty)) return null;
    final slat = double.tryParse(raw[0]);
    final slon = double.tryParse(raw[1]);
    final elat = double.tryParse(raw[2]);
    final elon = double.tryParse(raw[3]);
    if (slat == null ||
        slon == null ||
        elat == null ||
        elon == null ||
        slat < -90 ||
        slat > 90 ||
        elat < -90 ||
        elat > 90 ||
        slon < -180 ||
        slon > 180 ||
        elon < -180 ||
        elon > 180) {
      return null;
    }
    double? mhz;
    final mhzRaw = _sdrEnbMhz.text.trim();
    if (mhzRaw.isNotEmpty) {
      mhz = double.tryParse(mhzRaw);
      if (mhz == null || mhz <= 0) return null;
    }
    return (slat: slat, slon: slon, elat: elat, elon: elon, mhz: mhz);
  }

  bool _sdrStationFieldsTouched() =>
      _sdrStationLat.text.trim().isNotEmpty ||
      _sdrStationLon.text.trim().isNotEmpty ||
      _sdrEnbLat.text.trim().isNotEmpty ||
      _sdrEnbLon.text.trim().isNotEmpty ||
      _sdrEnbMhz.text.trim().isNotEmpty;

  void _save() {
    final station = _parseSdrStation();
    if (station == null && _sdrStationFieldsTouched()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('STATION / eNB COORDINATES INCOMPLETE OR INVALID '
                '— FILL ALL FOUR (LAT −90..90, LON −180..180) OR LEAVE BLANK')),
      );
      return;
    }
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
      autoConnectSilvusUsb: _autoConnectSilvusUsb,
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
      zmetaHeartbeatEnabled: _zmetaHeartbeatEnabled,
      zmetaHeartbeatIntervalSec:
          (int.tryParse(_zmetaHeartbeatInterval.text.trim()) ?? 60)
              .clamp(15, 600),
      cotEmitEnabled: _cotEmitEnabled,
      cotEmitUseMulticast: _cotEmitUseMulticast,
      cotTakHost: _cotTakHost.text.trim(),
      cotTakPort:
          (int.tryParse(_cotTakPort.text.trim()) ?? 8087).clamp(1, 65535),
      cotStaleSeconds:
          (int.tryParse(_cotStaleSeconds.text.trim()) ?? 30).clamp(5, 300),
      cotPublishFloor: (double.tryParse(_cotPublishFloor.text.trim()) ??
              0.3)
          .clamp(0.0, 1.0),
      // Emit callsign prefix: non-empty, no whitespace — invalid
      // input falls back to the SHEPHERD- default.
      cotCallsignPrefix: () {
        final v = _cotCallsignPrefix.text.trim();
        return (v.isEmpty || RegExp(r'\s').hasMatch(v)) ? 'SHEPHERD-' : v;
      }(),
      cotAirTypeThreshold:
          (double.tryParse(_cotAirTypeThreshold.text.trim()) ?? 0.5)
              .clamp(0.0, 1.0),
      cotListenEnabled: _cotListenEnabled,
      cotListenMulticastGroup: _cotListenMulticastGroup.text.trim().isEmpty
          ? '239.2.3.1'
          : _cotListenMulticastGroup.text.trim(),
      cotListenMulticastPort:
          (int.tryParse(_cotListenMulticastPort.text.trim()) ?? 6969)
              .clamp(1, 65535),
      cotListenWindowSeconds:
          (int.tryParse(_cotListenWindowSeconds.text.trim()) ?? 60)
              .clamp(10, 600),
      cotEmitterPrefix: _cotEmitterPrefix.text.trim().isEmpty
          ? 'PREDATOR-'
          : _cotEmitterPrefix.text.trim(),
      cotCoincidenceRadiusM: (double.tryParse(
                  _cotCoincidenceRadius.text.trim()) ??
              50.0)
          .clamp(5.0, 500.0),
      sdrStationLat: station?.slat,
      sdrStationLon: station?.slon,
      sdrEnbLat: station?.elat,
      sdrEnbLon: station?.elon,
      sdrEnbCenterMhz: station?.mhz,
    );
    widget.state.applySettings(s);
    final cam = widget.state.cameraSettings;
    cam.webhookPort =
        (int.tryParse(_camPort.text.trim()) ?? 49162).clamp(1024, 65535);
    cam.onvifAddress = _camOnvif.text.trim();
    cam.snapshotUrlTemplate = _camSnap.text.trim();
    unawaited(widget.state.saveCameraSettings(cam));
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
      final silvus = await RadioDiscovery.scanSubnet(
        _subnet.text.trim(),
        onProgress: (done, total) {
          if (mounted) {
            // First half of the bar: Silvus HTTP scan.
            setState(() => _scanProgress =
                total == 0 ? 0 : (done / total) * 0.5);
          }
        },
      );
      final mesh = await RadioDiscovery.scanMeshtastic(
        _subnet.text.trim(),
        onProgress: (done, total) {
          if (mounted) {
            // Second half: Meshtastic TCP-4403 scan.
            setState(() => _scanProgress =
                0.5 + (total == 0 ? 0 : (done / total) * 0.5));
          }
        },
      );
      if (mounted) setState(() => _found = [...silvus, ...mesh]);
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
        _section('Mesh calibration', _calibrationBody()),
        _section('SDR station', _sdrStationBody()),
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
              'MOTION WEBHOOK (POST /motion) OR ONVIF EVENTS. CAMERA '
              'EVIDENCE MAY UPGRADE DISPLAYED CONFIDENCE BUT NEVER '
              'VETOES OR SUPPRESSES A DETECTION.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _camera,
            onChanged: (v) {
              setState(() => _camera = v);
              widget.state.toggleCameraConfirmation(v);
            },
          ),
          if (_camera) ...[
            const SizedBox(height: 10),
            _field(_camPort, 'Motion webhook port', 'e.g. 49162',
                numeric: true),
            const SizedBox(height: 10),
            _field(_camOnvif, 'ONVIF address (optional)',
                'e.g. 192.168.1.50:80'),
            const SizedBox(height: 10),
            _field(_camSnap, 'Snapshot URL template (optional)',
                'e.g. http://192.168.1.50/shot.jpg'),
          ],
        ]),
        _section('Record & replay', [
          _recordRow(),
          const SizedBox(height: 10),
          _replayList(),
        ]),
        _section('Output — CoT', [
          SwitchListTile(
            title: Text('EMIT COT TRACKS',
                style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'PUBLISH THE FUSED TRACK AS CURSOR-ON-TARGET EVENTS. '
              'EMIT-ONLY, DEFENSIVE-ONLY — THE ONLY BYTES SENT ARE '
              'THIS MESH\'S OWN TRACK EVENTS, AND AFFILIATION IS ALWAYS '
              'UNKNOWN. DEFAULT OFF.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _cotEmitEnabled,
            onChanged: (v) {
              setState(() => _cotEmitEnabled = v);
              unawaited(widget.state.setCotEmitEnabled(v));
            },
          ),
          if (_cotEmitEnabled) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<bool>(
              initialValue: _cotEmitUseMulticast,
              dropdownColor: SentryColors.surface2,
              style: SentryType.rowValue(SentryColors.onDark),
              decoration:
                  const InputDecoration(labelText: 'DESTINATION'),
              items: [
                DropdownMenuItem(
                    value: true,
                    child: Text(
                        'MULTICAST ${widget.state.settings.cotMulticastGroup}:'
                        '${widget.state.settings.cotMulticastPort}')),
                const DropdownMenuItem(
                    value: false, child: Text('TAK SERVER')),
              ],
              onChanged: (v) {
                setState(() => _cotEmitUseMulticast = v ?? true);
                unawaited(
                    widget.state.setCotEmitUseMulticast(v ?? true));
              },
            ),
            if (!_cotEmitUseMulticast) ...[
              const SizedBox(height: 10),
              _field(_cotTakHost, 'TAK server host', 'e.g. 192.168.1.10'),
              const SizedBox(height: 10),
              _field(_cotTakPort, 'TAK server port', 'e.g. 8087 (plaintext TCP; 8089 is TLS)',
                  numeric: true),
            ],
            const SizedBox(height: 10),
            _field(_cotStaleSeconds, 'Stale window (seconds)',
                'e.g. 30 (5–300)',
                numeric: true),
            const SizedBox(height: 10),
            _field(_cotPublishFloor, 'Publish floor (0–1 confidence)',
                'e.g. 0.3',
                numeric: true),
            const SizedBox(height: 10),
            _field(_cotCallsignPrefix, 'Track callsign prefix',
                'e.g. SHEPHERD- (no spaces)'),
            const SizedBox(height: 10),
            _field(_cotAirTypeThreshold, 'Air type threshold (0–1)',
                'e.g. 0.5 — air-type guess ≥ this → a-u-A',
                numeric: true),
          ],
          SwitchListTile(
            title: Text('LISTEN FOR EMITTER TRACKS',
                style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'INGEST COT TRACKS WHOSE CALLSIGN MATCHES THE EMITTER '
              'PREFIX (RX-ONLY). SPATIAL COINCIDENCES WITH THE SHEPHERD '
              'TRACK UPGRADE CONFIDENCE ONLY — NEVER SUBTRACT, NEVER '
              'ORIGINATE A TRACK. DEFAULT OFF.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _cotListenEnabled,
            onChanged: (v) {
              setState(() => _cotListenEnabled = v);
              unawaited(widget.state.setCotListenEnabled(v));
            },
          ),
          if (_cotListenEnabled) ...[
            const SizedBox(height: 10),
            Text(
              'RX-ONLY — LISTENS ON '
              '${widget.state.settings.cotListenMulticastGroup}:'
              '${widget.state.settings.cotListenMulticastPort}',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            const SizedBox(height: 10),
            _field(_cotListenMulticastGroup, 'Listen multicast group',
                'e.g. 239.2.3.1'),
            const SizedBox(height: 10),
            _field(_cotListenMulticastPort, 'Listen multicast port',
                'e.g. 6969',
                numeric: true),
            const SizedBox(height: 10),
            _field(_cotListenWindowSeconds, 'Observation window (seconds)',
                'e.g. 60 (10–600)',
                numeric: true),
            const SizedBox(height: 10),
            _field(_cotEmitterPrefix, 'Emitter callsign prefix',
                'e.g. PREDATOR-'),
            const SizedBox(height: 10),
            _field(_cotCoincidenceRadius, 'Coincidence radius (meters)',
                'e.g. 50 (5–500)',
                numeric: true),
          ],
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
            _field(_zmetaHost, 'Gateway host', 'e.g. 127.0.0.1',
                onChanged: (_) => setState(() {})),
            const SizedBox(height: 10),
            _field(_zmetaPort, 'Gateway UDP port', 'e.g. 5555',
                numeric: true, onChanged: (_) => setState(() {})),
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
            const SizedBox(height: 10),
            SwitchListTile(
              title: Text('MESH HEARTBEAT (PLATFORM_STATUS)',
                  style: SentryType.rowValue(SentryColors.onDark)),
              subtitle: Text(
                'PERIODIC "ALIVE, HERE IS THE PLATFORM" TO THE GATEWAY '
                '(SYSTEM_EVENT). FOR TEAMS ON THE MOVE. DEFAULT OFF.',
                style: SentryType.section(10).copyWith(height: 1.6),
              ),
              value: _zmetaHeartbeatEnabled,
              onChanged: (v) => setState(() => _zmetaHeartbeatEnabled = v),
            ),
            if (_zmetaHeartbeatEnabled) ...[
              const SizedBox(height: 10),
              _field(_zmetaHeartbeatInterval, 'Heartbeat interval (seconds)',
                  'e.g. 60 (15–600)', numeric: true),
            ],
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
              subtitle: Text(
                  'TAP TO ADD AS ${r.driverId.toUpperCase()} RADIO',
                  style: SentryType.section(10)),
              onTap: () async {
                await widget.state.addRadio(RadioConfig(
                  driverId: r.driverId,
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
        _section('Auto-connect', [
          SwitchListTile(
            title: Text('AUTO-CONNECT SILVUS USB',
                style: SentryType.rowValue(SentryColors.onDark)),
            subtitle: Text(
              'WHEN A SILVUS RADIO APPEARS ON USB (172.17.97.X), '
              'VALIDATE IT AND ADD IT AUTOMATICALLY. UNPLUGGING NEVER '
              'REMOVES THE CONFIG — IT RECONNECTS ON REPLUG.',
              style: SentryType.section(10).copyWith(height: 1.6),
            ),
            value: _autoConnectSilvusUsb,
            onChanged: (v) {
              setState(() => _autoConnectSilvusUsb = v);
              unawaited(
                  widget.state.setAutoConnectSilvusUsb(v));
            },
          ),
        ]),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: _save, child: const Text('Save settings')),
        const SizedBox(height: 16),
      ],
    );
  }

  /// Guided "Dial it in" calibration UI, driven by the existing
  /// AppState methods. Double-click-simple: one button to start, one
  /// to re-measure after nudging the named node, Done to finish.
  List<Widget> _calibrationBody() {
    final st = widget.state;
    final cs = st.calibrationState;
    final body = <Widget>[
      Text(
        'GUIDED "DIAL IT IN" ROUTINE — EMPLACE NODES, KEEP THE AREA '
        'CLEAR 30–60 S, THEN NUDGE THE NAMED WORST NODE UNTIL FADE '
        'LEVELS STOP IMPROVING. SETS THE DRIFT-COMPENSATED REFERENCE '
        'ANCHORS; DETECTION ITSELF STAYS DETERMINISTIC.',
        style: SentryType.section(10).copyWith(height: 1.6),
      ),
      const SizedBox(height: 10),
    ];
    if (cs == CalibrationState.calibrating) {
      body.addAll([
        Text(st.calibrationNote ?? 'CALIBRATING…',
            style: SentryType.rowValue(SentryColors.amber)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: () => st.calibrationNudgeRound(),
                child: const Text('Re-measure'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: () async {
                  await st.finishCalibration();
                  if (mounted) setState(() {});
                },
                child: const Text('Done'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => st.cancelCalibration(),
              child: const Text('Cancel',
                  style: TextStyle(color: SentryColors.red)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'ONE ROUND ≈ 10 S AFTER MOVING THE NAMED NODE. STOP WHEN NO '
          'LINK IMPROVES > 1 DB ACROSS TWO ROUNDS, OR TAP DONE.',
          style: SentryType.section(10).copyWith(height: 1.6),
        ),
      ]);
    } else if (cs == CalibrationState.stable ||
        cs == CalibrationState.degraded) {
      final stable = cs == CalibrationState.stable;
      body.addAll([
        Text(
          stable ? 'FADE LEVELS STABLE' : 'CALIBRATED (DEGRADED MODE)',
          style: SentryType.rowValue(
              stable ? SentryColors.green : SentryColors.amber),
        ),
        if (st.calibrationNote != null) ...[
          const SizedBox(height: 4),
          Text(st.calibrationNote!,
              style: SentryType.section(10).copyWith(height: 1.6)),
        ],
        if (st.calibrationOwnerSummary.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(st.calibrationOwnerSummary.toUpperCase(),
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontSize: 12)),
        ],
        const SizedBox(height: 6),
        for (final l in st.calibrationWorstLinks.take(5)) _calibLinkRow(l),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: () =>
              st.startCalibration(degradedMode: _calibDegraded),
          child: const Text('Re-calibrate'),
        ),
      ]);
    } else {
      body.addAll([
        SwitchListTile(
          title: Text('DEGRADED MODE',
              style: SentryType.rowValue(SentryColors.onDark)),
          subtitle: Text(
            'RUN ON WHATEVER QUIET IS AVAILABLE — FADE LEVELS ARE '
            'PROVISIONAL AND SAY SO.',
            style: SentryType.section(10).copyWith(height: 1.6),
          ),
          value: _calibDegraded,
          onChanged: (v) => setState(() => _calibDegraded = v),
        ),
        const SizedBox(height: 6),
        ElevatedButton(
          onPressed: () =>
              st.startCalibration(degradedMode: _calibDegraded),
          child: const Text('Calibrate'),
        ),
      ]);
    }
    return body;
  }

  /// One ranked worst-link row, naming the owning nodes by their
  /// display names.
  Widget _calibLinkRow(CalibrationLink l) {
    final st = widget.state;
    String name(String id) =>
        st.nodePositions[id]?.displayName ?? id;
    final parts = l.link.split(' → ');
    final label = parts.length == 2
        ? '${name(parts[0])} → ${name(parts[1])}'
        : l.link;
    final deep = l.fadeDb < -3.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: SentryType.rowValue(SentryColors.onDark)
                    .copyWith(fontSize: 12)),
          ),
          Text(
            '${l.fadeDb >= 0 ? '+' : ''}${l.fadeDb.toStringAsFixed(1)} dB',
            style: SentryType.rowValue(
                    deep ? SentryColors.red : SentryColors.muted)
                .copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// SDR station geometry for the passive-Doppler correlator: the SDR
  /// radio's position and the LTE eNB's position (WGS84), converted to
  /// field-local meters at apply time. Without both, the correlator
  /// abstains — silence, never a guess.
  List<Widget> _sdrStationBody() {
    final station = _parseSdrStation();
    final touched = _sdrStationFieldsTouched();
    final status = station != null
        ? 'STATUS: CONFIGURED — DOPPLER CORRELATOR ARMED ON SAVE / START'
        : touched
            ? 'STATUS: INVALID — FILL ALL FOUR COORDINATES OR LEAVE BLANK'
            : 'STATUS: NOT CONFIGURED — THE DOPPLER CORRELATOR ABSTAINS '
                'UNTIL STATION + eNB ARE SET';
    final statusColor = station != null
        ? SentryColors.green
        : touched
            ? SentryColors.red
            : SentryColors.muted;
    return [
      Text(
        'PASSIVE-DOPPLER GEOMETRY. CONVERTED TO FIELD-LOCAL METERS AT '
        'APPLY TIME (GPS FIELD ORIGIN WHEN SET, ELSE RELATIVE TO THE '
        'STATION). PERSISTED WITH THE OTHER SETTINGS.',
        style: SentryType.section(10).copyWith(height: 1.6),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
              child: _field(_sdrStationLat, 'Station latitude',
                  'e.g. 35.123456',
                  numeric: true, onChanged: (_) => setState(() {}))),
          const SizedBox(width: 8),
          Expanded(
              child: _field(_sdrStationLon, 'Station longitude',
                  'e.g. -78.123456',
                  numeric: true, onChanged: (_) => setState(() {}))),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
              child: _field(_sdrEnbLat, 'LTE eNB latitude',
                  'e.g. 35.124000',
                  numeric: true, onChanged: (_) => setState(() {}))),
          const SizedBox(width: 8),
          Expanded(
              child: _field(_sdrEnbLon, 'LTE eNB longitude',
                  'e.g. -78.124000',
                  numeric: true, onChanged: (_) => setState(() {}))),
        ],
      ),
      const SizedBox(height: 10),
      _field(_sdrEnbMhz, 'LTE eNB center (MHz, optional)',
          'e.g. 1865',
          numeric: true, onChanged: (_) => setState(() {})),
      const SizedBox(height: 8),
      Text(status,
          style: SentryType.section(10)
              .copyWith(height: 1.6, color: statusColor)),
    ];
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
              _refreshReplayList();
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(summary)));
                setState(() {});
              }
            } else {
              await st.startRecording();
              if (mounted) {
                final err = st.recorder.lastError;
                if (err != null) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(err)));
                }
                setState(() {});
              }
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
      future: _replayFuture,
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
                          _fileName(f.path),
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
      {bool numeric = false, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      onChanged: onChanged,
      style: SentryType.rowValue(SentryColors.onDark),
      decoration:
          InputDecoration(labelText: label.toUpperCase(), hintText: hint),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
    );
  }
}
