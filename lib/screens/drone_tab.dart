/// Drone tab (Skydio P3): friendly-airframe video + telemetry.
///
/// A VIEWER, nothing more. EO and thermal are separate simultaneous
/// RTSP streams from the aircraft; the segmented switch picks which
/// one this screen watches. That is stream SELECTION — no command of
/// any kind reaches the aircraft: there is no flight, gimbal, or
/// focal control anywhere in this tab (wide/tele is the pilot's
/// choice inside the single EO stream, which is why the EO view is
/// labeled PILOT'S FOCAL VIEW).
///
/// Telemetry overlay comes from the Class B CoT feed Shepherd already
/// ingests — NOT from the video stream. MISB 0601 KLV extraction
/// through the player (media_kit/libmpv) is not practical: libmpv
/// does not surface demuxed KLV metadata for RTSP inputs through
/// media_kit's API. The overlay therefore shows the telemetry track,
/// captioned as such, rather than pretending to parse KLV.
///
/// Stream health is shown honestly (NO SIGNAL / CONNECTING / LIVE /
/// FROZEN from real player signals). No latency figure is shown:
/// the platform publishes none and glass-to-glass can't be measured
/// from here, so inventing one would be fiction.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/airframe_identity.dart';
import '../services/drone_stream.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// media_kit-backed [DronePlayer]. Owns the libmpv player and its
/// video controller; the tab reaches the controller only to render.
class MediaKitDronePlayer implements DronePlayer {
  MediaKitDronePlayer() {
    _subs.add(_player.stream.playing.listen((v) => _playing = v));
    _subs.add(_player.stream.position.listen((v) => _position = v));
    _subs.add(_player.stream.error.listen((_) => _error = true));
    _subs.add(_player.stream.width.listen((v) => _width = v ?? 0));
    _subs.add(_player.stream.height.listen((v) => _height = v ?? 0));
  }

  final Player _player = Player();
  late final VideoController controller = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _opened = false;
  bool _playing = false;
  bool _error = false;
  Duration _position = Duration.zero;
  int _width = 0;
  int _height = 0;

  @override
  Future<void> open(String url) async {
    _error = false;
    _opened = true;
    try {
      await _player.open(Media(url), play: true);
    } catch (_) {
      _error = true;
    }
  }

  @override
  Future<void> stop() async {
    _opened = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  bool get isOpen => _opened;
  @override
  bool get isPlaying => _playing;
  @override
  bool get hasError => _error;
  @override
  Duration get position => _position;
  @override
  int get videoWidth => _width;
  @override
  int get videoHeight => _height;

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _player.dispose();
  }
}

class DroneTab extends StatefulWidget {
  const DroneTab({
    super.key,
    required this.state,
    this.playerFactory,
    this.retryInterval = const Duration(seconds: 10),
  });

  final AppState state;

  /// Test seam: substitute a fake player (no native media_kit).
  final DronePlayer Function()? playerFactory;

  /// How often a stream stuck in the error state is re-opened
  /// (bounded automatic recovery — see DroneStreamRetryPolicy).
  final Duration retryInterval;

  @override
  State<DroneTab> createState() => _DroneTabState();
}

class _DroneTabState extends State<DroneTab> {
  DronePlayer? _player;
  DroneStreamKind _kind = DroneStreamKind.eo;
  final DroneStreamHealthTracker _health = DroneStreamHealthTracker();
  late final DroneStreamRetryPolicy _retry;
  DroneStreamHealth _healthNow = DroneStreamHealth.noSignal;
  bool _errorSeen = false;
  Timer? _healthTimer;
  String? _selectedKey;

  /// URL the player was last told to open; the health tick re-opens
  /// when the configured endpoint changes under the open tab
  /// (settings edit, local/cloud switch).
  String _openedUrl = '';

  DroneStreamConfig get _config {
    final s = widget.state.settings;
    if (s.droneStreamSource == 'cloud' &&
        (s.droneCloudEoUrl.isNotEmpty || s.droneCloudIrUrl.isNotEmpty)) {
      return DroneStreamConfig(
        eoUrl: s.droneCloudEoUrl.isNotEmpty ? s.droneCloudEoUrl : s.droneEoUrl,
        irUrl: s.droneCloudIrUrl.isNotEmpty ? s.droneCloudIrUrl : s.droneIrUrl,
        sourceLabel: 'CLOUD',
      );
    }
    return DroneStreamConfig(
      eoUrl: s.droneEoUrl,
      irUrl: s.droneIrUrl,
      sourceLabel: 'LOCAL LINK',
    );
  }

  @override
  void initState() {
    super.initState();
    _retry = DroneStreamRetryPolicy(interval: widget.retryInterval);
    _player = widget.playerFactory?.call() ?? MediaKitDronePlayer();
    _healthTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _openCurrent());
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _player?.dispose();
    super.dispose();
  }

  void _openCurrent() {
    final p = _player;
    if (p == null) return;
    final url = _config.urlFor(_kind);
    if (url.isEmpty) return;
    // A fresh open (operator switch, settings change, retry) resets
    // the retry schedule; the error path re-arms it if this open
    // also fails.
    _retry.clear();
    _openedUrl = url;
    _health.beginOpen(DateTime.now());
    unawaited(p.open(url));
  }

  void _switchKind(DroneStreamKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    _openCurrent();
  }

  void _tick() {
    final p = _player;
    if (p == null || !mounted) return;
    final want = _config.urlFor(_kind);
    if (want.isNotEmpty && want != _openedUrl) {
      _openCurrent();
      return;
    }
    final now = DateTime.now();
    if (p.hasError != _errorSeen) {
      // Rebuild on the error edge even when the health label itself
      // doesn't change (e.g. it already read NO SIGNAL), so the
      // tap-to-retry affordance appears/disappears with the state.
      _errorSeen = p.hasError;
      setState(() {});
    }
    if (p.hasError) {
      _health.markError();
      // Bounded automatic recovery: a latched player error — the
      // normal field sequence is the tab opened before the aircraft
      // starts streaming — re-opens on the retry policy's cadence
      // instead of sitting at NO SIGNAL until the operator happens
      // to toggle a stream or edit a setting.
      _retry.noteError(now);
      if (_retry.due(now)) {
        _retry.noteAttempt(now);
        _openCurrent();
        return;
      }
    } else {
      _retry.clear();
    }
    final h = _health.snapshot(
      isOpen: p.isOpen,
      playing: p.isPlaying,
      position: p.position,
      at: now,
    );
    if (h != _healthNow) setState(() => _healthNow = h);
  }

  /// Manual recovery alongside the automatic retry: tapping the
  /// video surface while the feed reads NO SIGNAL or FROZEN
  /// re-opens the current stream immediately.
  bool get _tapRetryArmed =>
      _openedUrl.isNotEmpty &&
      (_healthNow == DroneStreamHealth.noSignal ||
          _healthNow == DroneStreamHealth.frozen);

  Color get _healthColor => switch (_healthNow) {
        DroneStreamHealth.live => SentryColors.green,
        DroneStreamHealth.connecting => SentryColors.amber,
        DroneStreamHealth.frozen => SentryColors.orange,
        DroneStreamHealth.noSignal => SentryColors.red,
      };

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cfg = _config;
    final platforms = [
      for (final r in state.airframeRecords)
        if (r.klass != AirframeClass.c) r,
    ];
    AirframeRecord? selected;
    for (final r in platforms) {
      if (r.key == _selectedKey) {
        selected = r;
        break;
      }
    }
    selected ??= platforms.isEmpty ? null : platforms.first;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Text('DRONE', style: SentryType.readout(18, SentryColors.onDark)),
          const SizedBox(width: 12),
          SentryChip(label: cfg.sourceLabel, color: SentryColors.blue),
          const Spacer(),
          SentryChip(
              label: _healthNow.label, color: _healthColor, icon: Icons.circle),
        ]),
        const SizedBox(height: 12),
        // ---- Video surface -------------------------------------
        // Tapping a dead (NO SIGNAL) or stalled (FROZEN) feed
        // re-opens it immediately — the manual companion to the
        // bounded automatic retry in _tick.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tapRetryArmed ? _openCurrent : null,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: SentryColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(children: [
                Positioned.fill(child: _videoSurface(cfg)),
                Positioned(
                  left: 10,
                  top: 10,
                  child: SentryChip(
                      label: _kind.label, color: SentryColors.purple),
                ),
                if (selected != null)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: SentryChip(
                        label: selected.displayName,
                        color: SentryColors.green),
                  ),
                if (_tapRetryArmed)
                  const Center(
                    child: SentryChip(
                        label: 'TAP TO RETRY', color: SentryColors.amber),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // ---- Stream selection (viewer-side only) ----------------
        SegmentedButton<DroneStreamKind>(
          segments: const [
            ButtonSegment(
                value: DroneStreamKind.eo,
                icon: Icon(Icons.videocam),
                label: Text('EO')),
            ButtonSegment(
                value: DroneStreamKind.thermal,
                icon: Icon(Icons.thermostat),
                label: Text('THERMAL')),
          ],
          selected: {_kind},
          onSelectionChanged: (sel) => _switchKind(sel.first),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? SentryColors.purple.withAlpha(60)
                  : SentryColors.surface2,
            ),
            foregroundColor: const WidgetStatePropertyAll(SentryColors.onDark),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _kind == DroneStreamKind.eo
              ? "EO IS THE PILOT'S FOCAL VIEW — WIDE/TELE IS SELECTED "
                  'BY THE PILOT IN THE AIRCRAFT, NOT HERE.'
              : 'THERMAL IS ITS OWN SIMULTANEOUS STREAM — SWITCHING '
                  'ONLY CHANGES WHAT THIS SCREEN WATCHES.',
          style: SentryType.section(10).copyWith(height: 1.6),
        ),
        const SizedBox(height: 12),
        // ---- Per-airframe selector + telemetry ------------------
        SentryPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AIRFRAME', style: SentryType.section(11)),
              const SizedBox(height: 8),
              if (platforms.isEmpty)
                Text(
                  'NO FRIENDLY AIRFRAMES OBSERVED. AIRCRAFT APPEAR HERE '
                  'WHEN THE CONTROLLER COT FEED OR THE MESH REPORTS THEM '
                  '(SETTINGS → COT LISTENER + DRONES).',
                  style: SentryType.section(10).copyWith(height: 1.6),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in platforms)
                      ChoiceChip(
                        label: Text(r.displayName),
                        selected: selected?.key == r.key,
                        onSelected: (_) => setState(() => _selectedKey = r.key),
                        selectedColor: SentryColors.purple.withAlpha(70),
                        backgroundColor: SentryColors.surface2,
                        labelStyle: SentryType.rowValue(SentryColors.onDark),
                      ),
                  ],
                ),
              if (selected != null) ...[
                const SizedBox(height: 12),
                _telemetryGrid(selected),
                const SizedBox(height: 8),
                Text(
                  'TELEMETRY VIA THE COT FEED — NOT EXTRACTED FROM THE '
                  'VIDEO STREAM (NO KLV PARSE). STREAM ENDPOINTS ARE '
                  'THE SETTINGS URLS: ONE AIRCRAFT LINK AT A TIME.',
                  style: SentryType.section(10).copyWith(height: 1.6),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'VIEWER ONLY — SHEPHERD SENDS NOTHING TO THE AIRCRAFT. NO '
          'FLIGHT, GIMBAL, OR CAMERA CONTROL EXISTS IN THIS TAB.',
          style: SentryType.section(10).copyWith(height: 1.6),
        ),
      ],
    );
  }

  Widget _videoSurface(DroneStreamConfig cfg) {
    final p = _player;
    if (!cfg.hasAnyEndpoint) {
      return _surfaceMessage(
          'NO STREAM ENDPOINTS CONFIGURED — SET THEM IN SETTINGS → DRONES');
    }
    if (cfg.urlFor(_kind).isEmpty) {
      return _surfaceMessage(
          'NO ${_kind.name.toUpperCase()} ENDPOINT CONFIGURED');
    }
    if (p is MediaKitDronePlayer) {
      return Video(
        controller: p.controller,
        controls: NoVideoControls,
        fit: BoxFit.contain,
      );
    }
    // Non-media_kit player (tests / future backends): status surface.
    return _surfaceMessage(_healthNow == DroneStreamHealth.live
        ? 'STREAM LIVE (EXTERNAL PLAYER)'
        : _healthNow.label);
  }

  Widget _surfaceMessage(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text,
            textAlign: TextAlign.center,
            style: SentryType.section(11).copyWith(height: 1.6)),
      ),
    );
  }

  Widget _telemetryGrid(AirframeRecord r) {
    String fmt(double? v, String unit, {int dp = 1}) =>
        v == null ? '—' : '${v.toStringAsFixed(dp)}$unit';
    final age = r.lastSeen == null
        ? '—'
        : '${DateTime.now().difference(r.lastSeen!).inSeconds}s AGO';
    final rows = <(String, String)>[
      ('AFFILIATION', r.affiliationLabel),
      ('CLASS', r.classLabel),
      ('LAT', fmt(r.lat, '', dp: 6)),
      ('LON', fmt(r.lon, '', dp: 6)),
      ('ALT (MSL)', fmt(r.altM, ' m')),
      ('COURSE', fmt(r.courseDeg, '°', dp: 0)),
      ('SPEED', fmt(r.speedMps, ' m/s')),
      ('BATTERY', r.batteryPct == null ? '—' : '${r.batteryPct!.round()}%'),
      ('UPDATED', age),
    ];
    return Wrap(
      spacing: 24,
      runSpacing: 10,
      children: [
        for (final (label, value) in rows)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: SentryType.section(9)),
              Text(value, style: SentryType.rowValue(SentryColors.onDark)),
            ],
          ),
      ],
    );
  }
}
