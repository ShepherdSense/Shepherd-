import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

import '../models/link_sample.dart';
import '../models/tracking.dart';
import '../services/discovery.dart';
import '../services/gps_positioning.dart';
import '../services/health.dart';
import '../services/tracker.dart';
import '../services/tripwire.dart';
import '../services/field_activity.dart';
import '../services/radio_driver.dart';
import '../services/ai_classifier.dart';
import '../services/track_stitcher.dart';
import '../utils/node_ids.dart';
import '../services/wifi_aware.dart';
import '../services/wifi_rtt.dart';
import '../services/wifi_sense.dart';

/// Short display ID: strips the driver namespace (`silvus:90550` → `90550`).
/// (Moved to utils/node_ids.dart; re-exported here for existing callers.)
export '../utils/node_ids.dart';

/// Map color per radio driver for the unified map.
Color driverColor(String driverId) {
  switch (driverId) {
    case 'silvus':
      return SentryColors.blue;
    case 'sim':
      return SentryColors.green;
    case 'mpu5':
      return SentryColors.purple;
    case 'harris':
      return SentryColors.orange;
    case 'sdr':
      return SentryColors.purple;
    default:
      return SentryColors.muted;
  }
}

/// Editable connection + detector settings.
class AppSettings {
  AppSettings({
    this.radioIp = '172.17.97.182',
    this.subnet = '172.17.97.0/24',
    this.pollInterval = 0.25,
    this.dipThreshold = 6.0,
    this.confirmPolls = 2,
    this.baselineWindow = 120,
    this.simulatedMode = true,
    this.wifiDipThresholdDb = 6.0,
  });

  String radioIp;
  String subnet;
  double pollInterval;
  double dipThreshold;
  int confirmPolls;
  int baselineWindow;
  bool simulatedMode;

  /// WiFi dip depth (dB below rolling median) that counts as a disturbance.
  double wifiDipThresholdDb;

  TripwireConfig get tripwireConfig => TripwireConfig(
        baselineWindow: baselineWindow,
        dipThreshold: dipThreshold,
        confirmPolls: confirmPolls,
      );
}

/// Central state: polling loop, tripwire processing, tracking fusion,
/// chart history, events, node layout, and persistence.
class AppState extends ChangeNotifier {
  AppState() {
    _loadLayout();
    _loadGpsOrigin();
    _radiosReady = _loadRadios();
    // Fire-and-forget: events simply carry no AI label until it lands.
    DisturbanceClassifier.load().then((c) => _classifier = c);
    TrackStitcher.load().then((s) => _stitcher = s);
  }

  /// Completes when the saved radio list has been read. START waits for
  /// it: otherwise a quick START on a cold launch saw an empty list,
  /// "migrated" the legacy single radio, and overwrote the saved radios.
  late final Future<void> _radiosReady;
  bool _radiosLoaded = false;
  bool _startPending = false;
  bool _disposed = false;

  /// Last timestamp processed per link. A driver may re-report its latest
  /// reading on every poll (the sweeping SDR does); feeding that replay
  /// to the tripwire would let ONE reading satisfy "N confirming polls"
  /// and would stuff the baseline with duplicates.
  final Map<String, DateTime> _lastSampleTs = {};

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Embedded disturbance classifier (tiny trained net). Null until the
  /// bundled model asset loads — or if the asset is missing.
  DisturbanceClassifier? _classifier;

  /// Track-stitching specialist (tiny trained net). Starts model-less;
  /// swapped for the loaded one when the asset arrives. Without a model
  /// it simply never reports a stitch.
  TrackStitcher _stitcher = TrackStitcher.withoutModel();

  AppSettings settings = AppSettings();

  Tripwire _tripwire = Tripwire();
  final Tracker _tracker = Tracker();

  /// One live poller per configured radio. Each driver polls on its own
  /// timer (an SNMP Harris radio won't keep up with a 4 Hz Silvus), and
  /// node IDs are driver-namespaced so link keys can never collide
  /// across vendors — per-link tripwire baselines stay independent.
  final List<_DriverPoller> _pollers = [];

  SimulatedDriver? _simDriver;

  /// Configured radios (persisted). In simulated mode these are ignored
  /// and a single simulated mesh runs instead.
  final List<RadioConfig> radioConfigs = [];

  /// Latest batch per poller index, for cross-driver track fusion.
  final Map<int, List<LinkSample>> _latestByPoller = {};

  bool polling = false;
  String? error;
  String connectionLabel = 'Idle — press Start';

  /// Audible + haptic alerts on confirmed detections and on loss of
  /// coverage. Deliberately NOT persisted: every launch starts armed, so
  /// a mute can't be forgotten across sessions.
  bool alertsEnabled = true;

  void toggleAlerts() {
    alertsEnabled = !alertsEnabled;
    notifyListeners();
  }

  DateTime _startedAt = DateTime.now();
  Timer? _watchdog;
  Coverage? _lastCoverage;
  final Map<AlertKind, DateTime> _lastAlertAt = {};

  /// How far a CLEAR verdict can be trusted right now. Recomputed on
  /// demand from radio status, link freshness and baseline resets.
  HealthReport get health {
    final now = DateTime.now();
    return assessHealth(
      now: now,
      startedAt: _startedAt,
      drivers: [
        for (final p in _pollers)
          DriverHealthInput(
            driverId: p.config.driverId,
            label: p.status.label,
            pollIntervalSecs: p.config.pollInterval,
            lastPoll: p.status.lastPoll,
            error: p.status.error,
          ),
      ],
      lastByLink: {
        for (final e in history.entries)
          if (e.value.isNotEmpty) e.key: e.value.last,
      },
      staleAfter: _staleAfter,
      rebaselines: _tripwire.rebaselinedAt,
    );
  }

  /// Dashboard radio card data, rebuilt on every poll cycle.
  List<DriverStatus> get driverStatuses =>
      [for (final p in _pollers) p.status];

  /// Status for one configured radio, or null when it has no live poller
  /// (disabled, unimplemented, or simulated mode ignoring it).
  DriverStatus? statusFor(RadioConfig c) {
    for (final p in _pollers) {
      if (identical(p.config, c)) return p.status;
    }
    return null;
  }

  /// Ambient WiFi sensing via the host device's own adapter.
  final WifiVisionService wifi = WifiVisionService();

  /// Fused field-activity level (WiFi crossings + BLE sightings).
  final FieldActivityService fieldActivity = const FieldActivityService();

  /// 802.11mc RTT ranging (Android only; graceful elsewhere).
  final WifiRttService wifiRtt = WifiRttService();

  /// Wi-Fi Aware discovery (Android only; experimental/unverified).
  final WifiAwareService wifiAware = WifiAwareService();

  /// Public refresh for screens driving manual services (RTT, Aware).
  void refresh() => notifyListeners();
  bool wifiVisionEnabled = false;

  /// Toggle the device-adapter WiFi sensor. Simulates when the app is in
  /// simulated mode; uses netsh on live Windows.
  void toggleWifiVision(bool on) {
    wifiVisionEnabled = on;
    if (on) {
      wifi.onUpdate = () => notifyListeners();
      wifi.dipThresholdDb = settings.wifiDipThresholdDb;
      wifi.start(simulate: settings.simulatedMode);
    } else {
      wifi.stop();
    }
    notifyListeners();
  }

  /// linkKey -> recent enriched samples (for charts).
  final Map<String, List<LinkSample>> history = {};
  static const maxHistory = 120;

  final List<CrossingEvent> events = [];

  /// Live-mode node layout, field-local meters. Auto-grows with the mesh;
  /// no node-count limit. Persisted across restarts.
  final Map<String, NodePosition> nodePositions = {};

  /// Defended point, field-local meters. Persisted across restarts.
  DefendedPoint defended = DefendedPoint(x: 0, y: 0);

  /// Latest fused track; null when nothing is currently disturbed.
  TrackEstimate? track;

  /// Latest shadow (attenuation) grid for the tracking map.
  List<ShadowCell> shadow = [];

  /// Nodes the tracker actually uses: the sim's canonical layout in
  /// simulated mode, the user's own layout in live mode.
  Map<String, NodePosition> get effectiveNodes =>
      (settings.simulatedMode && _simDriver != null)
          ? _simDriver!.nodeLayout
          : nodePositions;

  /// Link keys whose latest sample is currently disturbed
  /// (dip at/above threshold). Drives the DETECTED banner.
  List<String> get disturbedLinks {
    final out = <String>[];
    final now = DateTime.now();
    history.forEach((key, h) {
      if (h.isNotEmpty &&
          _isLive(h.last, now) &&
          h.last.isDisturbed(settings.dipThreshold)) {
        out.add(key);
      }
    });
    return out;
  }

  /// Undirected node pairs currently disturbed, as "idA|idB".
  /// Used to highlight links on the tracking map.
  Set<String> get disturbedPairs {
    final out = <String>{};
    final now = DateTime.now();
    history.forEach((_, h) {
      if (h.isNotEmpty &&
          _isLive(h.last, now) &&
          h.last.isDisturbed(settings.dipThreshold)) {
        final ids = [h.last.fromNode, h.last.toNode]..sort();
        out.add('${ids[0]}|${ids[1]}');
      }
    });
    return out;
  }

  void applySettings(AppSettings s) {
    final wasPolling = polling;
    final wasWifi = wifiVisionEnabled;
    stop();
    settings = s;
    _tripwire = Tripwire(config: s.tripwireConfig);
    _tracker.reset();
    track = null;
    history.clear();
    events.clear();
    error = null;
    connectionLabel = 'Idle — press Start';
    if (wasWifi) {
      wifi.stop();
      wifi.dipThresholdDb = settings.wifiDipThresholdDb;
      wifi.start(simulate: settings.simulatedMode);
    }
    notifyListeners();
    if (wasPolling) start();
  }

  void start() {
    stop();
    if (!settings.simulatedMode && !_radiosLoaded) {
      _startPending = true;
      connectionLabel = 'Loading saved radios…';
      notifyListeners();
      _radiosReady.then((_) {
        if (_startPending && !_disposed) {
          _startPending = false;
          start();
        }
      });
      return;
    }
    // START always begins a fresh session: new baselines, new link set.
    // (Establish the baseline with the area clear: whatever is standing
    // in a link when its baseline is learned is invisible until it moves.)
    _tracker.reset();
    track = null;
    history.clear();
    _tripwire = Tripwire(config: settings.tripwireConfig);
    _latestByPoller.clear();
    _lastSampleTs.clear();
    _lastFuse = null;
    _startedAt = DateTime.now();
    _lastCoverage = null;
    _lastAlertAt.clear();
    polling = true;
    error = null;
    if (settings.simulatedMode) {
      _simDriver = SimulatedDriver(pollInterval: settings.pollInterval);
      _addPoller(
        RadioConfig(
          driverId: 'sim',
          address: '',
          label: 'SIMULATED MESH',
          pollInterval: settings.pollInterval,
        ),
        _simDriver!,
      );
      connectionLabel = 'Starting simulation…';
    } else {
      if (radioConfigs.isEmpty) {
        // First run after the multi-driver upgrade: migrate the legacy
        // single-radio setting.
        radioConfigs.add(RadioConfig(
          driverId: 'silvus',
          address: settings.radioIp,
          pollInterval: settings.pollInterval,
        ));
        _saveRadios();
      }
      for (final c in radioConfigs.where((c) => c.enabled)) {
        try {
          final d = driverFor(c);
          if (d.isImplemented) _addPoller(c, d);
        } catch (_) {
          // Unknown driver id: skip it rather than killing the loop.
        }
      }
      connectionLabel = _pollers.isEmpty
          ? 'No radios enabled — add one in Settings'
          : 'Connecting…';
    }
    notifyListeners();
    for (final p in _pollers) {
      _tickPoller(p);
      p.timer = Timer.periodic(
        Duration(milliseconds: (p.config.pollInterval * 1000).round()),
        (_) => _tickPoller(p),
      );
    }
    // Dead-man check: runs even if every poll hangs, so the banner can't
    // freeze on its last (possibly CLEAR) state.
    _watchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _watchdogTick(),
    );
  }

  void _watchdogTick() {
    if (!polling) return;
    final level = health.level;
    final prev = _lastCoverage;
    _lastCoverage = level;
    if ((level == Coverage.blind || level == Coverage.degraded) &&
        level != prev) {
      unawaited(_alert(AlertKind.fault));
    }
    notifyListeners();
  }

  /// Beep + buzz. Rate-limited per kind so a flapping link can't turn the
  /// device into a siren. Uses only Flutter's built-in platform sound and
  /// haptics; on a platform without them this is a silent no-op.
  Future<void> _alert(AlertKind kind) async {
    if (!alertsEnabled) return;
    final now = DateTime.now();
    final last = _lastAlertAt[kind];
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastAlertAt[kind] = now;
    try {
      final pulses = kind == AlertKind.detection ? 3 : 2;
      for (var i = 0; i < pulses; i++) {
        await SystemSound.play(SystemSoundType.alert);
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (_) {}
  }

  void _addPoller(RadioConfig config, RadioDriver driver) {
    _pollers.add(_DriverPoller(config: config, driver: driver));
  }

  void stop() {
    _startPending = false;
    for (final p in _pollers) {
      p.timer?.cancel();
      try {
        p.driver.dispose();
      } catch (_) {}
    }
    _pollers.clear();
    _latestByPoller.clear();
    _watchdog?.cancel();
    _watchdog = null;
    _simDriver = null;
    polling = false;
    notifyListeners();
  }

  /// One driver's poll cycle. Each driver runs on its own timer so a
  /// slow SNMP radio can't stall a fast Silvus poll.
  Future<void> _tickPoller(_DriverPoller p) async {
    if (p.busy || !polling) return;
    p.busy = true;
    try {
      final raw = await p.driver.poll();
      // The poller may have been stopped or replaced (settings change,
      // restart) while this poll was in flight. Its samples belong to a
      // session that no longer exists; don't let them into the new one.
      if (!polling || !_pollers.contains(p)) return;
      p.status.lastPoll = DateTime.now();
      p.status.linkCount = raw.length;
      p.status.error = raw.isEmpty ? p.driver.emptyHint : null;

      final enrichedAll = <LinkSample>[];
      for (final r in raw) {
        final prevTs = _lastSampleTs[r.linkKey];
        if (prevTs != null && r.timestamp.isAtSameMomentAs(prevTs)) {
          // Replay of a reading already processed: keep it as current
          // evidence but don't run it through the tripwire again.
          final hist = history[r.linkKey];
          if (hist != null && hist.isNotEmpty) enrichedAll.add(hist.last);
          continue;
        }
        _lastSampleTs[r.linkKey] = r.timestamp;
        final enriched = _tripwire.process(r);
        enrichedAll.add(enriched);
        final h = history.putIfAbsent(enriched.linkKey, () => []);
        h.add(enriched);
        while (h.length > maxHistory) {
          h.removeAt(0);
        }
      }
      _latestByPoller[_pollers.indexOf(p)] = enrichedAll;
      final fresh = _tripwire.drainEvents();
      final classified = [
        for (final e in fresh) _classifyEvent(e, p.config.pollInterval),
      ];
      if (classified.isNotEmpty) unawaited(_alert(AlertKind.detection));
      events.insertAll(0, classified);
      if (events.length > 200) {
        events.removeRange(200, events.length);
      }
      if (!settings.simulatedMode) _ensureNodes(raw);
      _updateFusedTrack();
      _refreshConnectionLabel();
      error = null;
    } catch (e) {
      if (!_pollers.contains(p)) return;
      p.status.error = 'Poll error: $e';
      // A failed radio must not keep feeding its last batch into the
      // fusion: drop it and re-solve without it.
      _latestByPoller.remove(_pollers.indexOf(p));
      try {
        _updateFusedTrack(force: true);
      } catch (_) {}
      _refreshConnectionLabel();
    } finally {
      p.busy = false;
      notifyListeners();
    }
  }

  /// Deterministic cross-driver fusion: the tracker's grid search runs
  /// on the latest batch from EVERY driver, in one shared coordinate
  /// frame. Dips are baseline-relative per link, so band differences
  /// don't corrupt the geometry — a dip is a dip wherever it happens.
  /// Data association across drivers falls out of the tracker's
  /// continuity logic: detections close in time and space join the
  /// same track.
  void _updateFusedTrack({bool force = false}) {
    final now = DateTime.now();
    // Every radio ticks on its own timer; don't re-solve the whole
    // field once per radio per cycle.
    final last = _lastFuse;
    if (!force && last != null && now.difference(last) < _minFuseGap) {
      return;
    }
    _lastFuse = now;
    // Only samples fresh enough to still be evidence take part. A radio
    // that stops answering ages out here even if nothing clears its batch.
    final all = [
      for (final batch in _latestByPoller.values)
        for (final s in batch)
          if (_isLive(s, now)) s,
    ];
    // Spectrum-band virtual links (SDR energy watch) feed the tripwire
    // and alerts like any link, but they carry no geometry -- a hot band
    // is not a position. Keep them out of the position solver, the
    // shadow grid, and the stitcher so they can't drag the track.
    final geo = [
      for (final s in all)
        if (driverOf(s.fromNode) != 'sdr') s,
    ];
    track = _tracker.update(
      now: now,
      samples: geo,
      nodes: effectiveNodes,
      dipThreshold: settings.dipThreshold,
      defended: defended,
    );
    shadow = _tracker.shadowGrid(
      samples: geo,
      nodes: effectiveNodes,
      dipThreshold: settings.dipThreshold,
    );
    // Track stitching: the deterministic tracker fuses whatever is
    // disturbed right now; the stitcher watches for handoffs — a new
    // detection on one driver that continues a recently-quiet one on
    // another — and scores P(same mover).
    _stitcher.observe(
      now: now,
      samples: geo,
      nodes: effectiveNodes,
      dipThreshold: settings.dipThreshold,
    );
    if (track != null) {
      final activeDrivers = <String>{};
      for (final s in geo) {
        if (s.isDisturbed(settings.dipThreshold)) {
          activeDrivers.add(driverOf(s.fromNode));
        }
      }
      String? bestLabel;
      double bestConf = 0.0;
      for (final d in activeDrivers) {
        final h = _stitcher.checkHandoff(now: now, activeDriver: d);
        if (h != null && h.confidence > bestConf) {
          bestConf = h.confidence;
          bestLabel =
              '${h.fromDriver.toUpperCase()} → ${d.toUpperCase()}';
        }
      }
      if (bestLabel != null) {
        track = track!.copyWith(
          stitchLabel: bestLabel,
          stitchConfidence: bestConf,
        );
      }
    }
  }

  DateTime? _lastFuse;
  static const _minFuseGap = Duration(milliseconds: 100);

  /// How long a sample from [driverId] stays valid: four poll intervals
  /// of that driver's slowest radio, but never under 2 s (or whatever the
  /// driver itself declares via [RadioDriver.sampleMaxAge]).
  Duration _staleAfter(String driverId) {
    var secs = 2.0;
    for (final p in _pollers) {
      if (p.config.driverId == driverId) {
        secs = math.max(secs, p.config.pollInterval * 4);
        final m = p.driver.sampleMaxAge;
        if (m != null) secs = math.max(secs, m.inMilliseconds / 1000.0);
      }
    }
    return Duration(milliseconds: (secs * 1000).round());
  }

  bool _isLive(LinkSample s, DateTime now) =>
      now.difference(s.timestamp) <= _staleAfter(driverOf(s.fromNode));

  void _refreshConnectionLabel() {
    if (settings.simulatedMode) {
      connectionLabel = 'SIMULATED LINK DATA';
      return;
    }
    final links =
        _pollers.fold<int>(0, (a, p) => a + p.status.linkCount);
    connectionLabel =
        'Live · ${_pollers.length} radio(s), $links link direction(s)';
  }

  /// Run the embedded classifier over a freshly closed crossing event.
  /// The tripwire stays the detector — this only attaches a heuristic
  /// label (with confidence) describing the disturbance shape.
  CrossingEvent _classifyEvent(CrossingEvent e, double pollInterval) {
    final clf = _classifier;
    if (clf == null) return e;
    // The model was trained on mesh-link dips. A spectrum band's energy
    // rise is a different physical thing; a PASSING/LINGERING label on
    // it would be a confident-looking guess about the wrong signal.
    if (driverOf(e.linkKey) == 'sdr') return e;
    try {
      final h = history[e.linkKey];
      if (h == null || h.length < 4) return e;
      final n =
          (e.durationSecs / pollInterval).round().clamp(4, h.length);
      final dips =
          h.sublist(h.length - n).map((s) => s.dip).toList();
      final now = DateTime.now();
      final activeDrivers = <String>{};
      var simulLinks = 0;
      history.forEach((key, samples) {
        if (samples.isEmpty || driverOf(key) == 'sdr') return;
        final last = samples.last;
        if (last.isDisturbed(settings.dipThreshold) &&
            now.difference(last.timestamp).inSeconds < 5) {
          simulLinks++;
          activeDrivers.add(driverOf(last.linkKey));
        }
      });
      final features = extractDisturbanceFeatures(
        dips: dips,
        threshold: h.last.effectiveThreshold(settings.dipThreshold),
        durationSecs: e.durationSecs,
        simulLinks: simulLinks,
        crossDriver: activeDrivers.length > 1,
        meshLinks: history.keys.where((k) => driverOf(k) != 'sdr').length,
      );
      final (label, conf) = clf.classify(features);
      if (conf <= 0) return e; // model had no answer: attach no label
      return e.copyWith(aiLabel: label, aiConfidence: conf);
    } catch (_) {
      return e;
    }
  }

  // ---- Radio manager (persisted) ----

  static const _radiosKey = 'rf_sentry_radios_v1';

  Future<void> _loadRadios() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_radiosKey);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      radioConfigs
        ..clear()
        ..addAll(list.map(RadioConfig.fromJson));
    } catch (_) {
    } finally {
      _radiosLoaded = true;
    }
  }

  Future<void> _saveRadios() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _radiosKey,
        jsonEncode([for (final c in radioConfigs) c.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> addRadio(RadioConfig c) async {
    radioConfigs.add(c);
    await _saveRadios();
    if (polling && !settings.simulatedMode) start();
    notifyListeners();
  }

  Future<void> removeRadioAt(int i) async {
    if (i < 0 || i >= radioConfigs.length) return;
    radioConfigs.removeAt(i);
    await _saveRadios();
    if (polling && !settings.simulatedMode) start();
    notifyListeners();
  }

  Future<void> setRadioEnabled(int i, bool on) async {
    if (i < 0 || i >= radioConfigs.length) return;
    radioConfigs[i].enabled = on;
    await _saveRadios();
    if (polling && !settings.simulatedMode) start();
    notifyListeners();
  }
  Future<List<DiscoveredRadio>> scan() =>
      RadioDiscovery.scanSubnet(settings.subnet);

  // ---- Node layout & defended point (persisted) ----

  static const _prefsKey = 'rf_sentry_layout_v1';

  /// Auto-place newly seen live nodes on a golden-angle spiral so any
  /// node count gets a sane, non-overlapping starting layout. The user
  /// then drags nodes to their real positions on the tracking map.
  void _ensureNodes(List<LinkSample> samples) {
    var changed = false;
    for (final s in samples) {
      for (final id in [s.fromNode, s.toNode]) {
        // Spectrum "nodes" (sdr:rtlsdr0 / sdr:band-433) are not places in
        // the field; they must not appear on the map or in the layout.
        if (driverOf(id) == 'sdr') continue;
        if (!nodePositions.containsKey(id)) {
          final i = nodePositions.length;
          final r = 25.0 + 6.0 * i;
          final a = i * 2.399963; // golden angle
          nodePositions[id] = NodePosition(
            nodeId: id,
            x: r * math.cos(a),
            y: r * math.sin(a),
          );
          changed = true;
        }
      }
    }
    if (changed) {
      _saveLayout();
      notifyListeners();
    }
  }

  void moveNode(String id, double x, double y) {
    final n = nodePositions[id];
    if (n == null) return;
    n.x = x;
    n.y = y;
    _saveLayout();
    notifyListeners();
  }

  void setNodeHeight(String id, double h) {
    final n = nodePositions[id];
    if (n == null) return;
    n.height = h.clamp(0.0, 500.0);
    _saveLayout();
    notifyListeners();
  }

  /// 'whip' or 'panel' — drives the idealized lobe in the 3D beam view.
  void setNodeAntenna(String id, String antenna) {
    final n = nodePositions[id];
    if (n == null) return;
    n.antenna = antenna == 'panel' ? 'panel' : 'whip';
    _saveLayout();
    notifyListeners();
  }

  void moveDefended(double x, double y) {
    defended.x = x;
    defended.y = y;
    _saveLayout();
    notifyListeners();
  }

  void resetLayout() {
    nodePositions.clear();
    defended = DefendedPoint(x: 0, y: 0);
    _saveLayout();
    notifyListeners();
  }

  // ---- GPS positioning (persisted origin + per-node capture) ----

  static const _originKey = 'rf_sentry_gps_origin_v1';

  /// WGS84 origin all field-local meters are relative to. Null until set.
  GpsOrigin? gpsOrigin;

  /// True while a GPS fix is being acquired.
  bool gpsBusy = false;

  /// Last GPS status/result line for the UI. Null when nothing to report.
  String? gpsMessage;

  Future<void> _loadGpsOrigin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_originKey);
      if (raw == null) return;
      gpsOrigin =
          GpsOrigin.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveGpsOrigin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final o = gpsOrigin;
      if (o == null) {
        await prefs.remove(_originKey);
      } else {
        await prefs.setString(_originKey, jsonEncode(o.toJson()));
      }
    } catch (_) {}
  }

  String _accuracyNote(double accuracyM) {
    final acc = '±${accuracyM.toStringAsFixed(0)} M';
    if (accuracyM > 15) {
      return '$acc — COARSE FIX. FOR METER-LEVEL PLACEMENT, CAPTURE FROM THE ANDROID PHONE AT THE NODE.';
    }
    return acc;
  }

  /// Set the field origin to the device's current GPS position.
  Future<void> setGpsOriginHere() async {
    gpsBusy = true;
    gpsMessage = 'ACQUIRING GPS FIX…';
    notifyListeners();
    try {
      final fix = await GpsPositioning.currentFix();
      gpsOrigin = GpsOrigin(lat: fix.lat, lon: fix.lon);
      await _saveGpsOrigin();
      gpsMessage = 'ORIGIN SET — ${_accuracyNote(fix.accuracyM)}';
    } on GpsException catch (e) {
      gpsMessage = e.message;
    } catch (e) {
      gpsMessage = 'GPS ERROR: $e';
    } finally {
      gpsBusy = false;
      notifyListeners();
    }
  }

  /// Walk to the node, tap capture: the node's X/Y is set from the GPS
  /// fix, meters east/north of the origin. The first capture also sets
  /// the origin (node lands at 0,0).
  Future<void> captureNodeGps(String nodeId) async {
    final n = nodePositions[nodeId];
    if (n == null) return;
    gpsBusy = true;
    gpsMessage = 'ACQUIRING GPS FIX FOR $nodeId…';
    notifyListeners();
    try {
      final fix = await GpsPositioning.currentFix();
      var origin = gpsOrigin;
      var originWasSet = false;
      if (origin == null) {
        origin = GpsOrigin(lat: fix.lat, lon: fix.lon);
        gpsOrigin = origin;
        await _saveGpsOrigin();
        originWasSet = true;
      }
      final m = latLonToMeters(fix.lat, fix.lon, origin.lat, origin.lon);
      n.x = m.x;
      n.y = m.y;
      n.lat = fix.lat;
      n.lon = fix.lon;
      _saveLayout();
      final placed =
          '${m.x.toStringAsFixed(1)}, ${m.y.toStringAsFixed(1)} M';
      gpsMessage = originWasSet
          ? 'ORIGIN SET HERE — $nodeId AT 0,0 — ${_accuracyNote(fix.accuracyM)}'
          : '$nodeId PLACED AT $placed — ${_accuracyNote(fix.accuracyM)}';
    } on GpsException catch (e) {
      gpsMessage = e.message;
    } catch (e) {
      gpsMessage = 'GPS ERROR: $e';
    } finally {
      gpsBusy = false;
      notifyListeners();
    }
  }

  /// Place the defended point at the device's current GPS position.
  Future<void> captureDefendedGps() async {
    gpsBusy = true;
    gpsMessage = 'ACQUIRING GPS FIX FOR DEFENDED POINT…';
    notifyListeners();
    try {
      final fix = await GpsPositioning.currentFix();
      var origin = gpsOrigin;
      if (origin == null) {
        origin = GpsOrigin(lat: fix.lat, lon: fix.lon);
        gpsOrigin = origin;
        await _saveGpsOrigin();
      }
      final m = latLonToMeters(fix.lat, fix.lon, origin.lat, origin.lon);
      defended.x = m.x;
      defended.y = m.y;
      _saveLayout();
      gpsMessage =
          'DEFENDED POINT PLACED AT ${m.x.toStringAsFixed(1)}, ${m.y.toStringAsFixed(1)} M — ${_accuracyNote(fix.accuracyM)}';
    } on GpsException catch (e) {
      gpsMessage = e.message;
    } catch (e) {
      gpsMessage = 'GPS ERROR: $e';
    } finally {
      gpsBusy = false;
      notifyListeners();
    }
  }

  Future<void> _loadLayout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      nodePositions.clear();
      for (final n in (j['nodes'] as List).cast<Map<String, dynamic>>()) {
        var p = NodePosition.fromJson(n);
        // v0.11 migration: node IDs are now driver-namespaced
        // (`silvus:90550`). Legacy entries predate namespaces.
        if (!p.nodeId.contains(':')) {
          p = NodePosition(
            nodeId: 'silvus:${p.nodeId}',
            x: p.x,
            y: p.y,
            height: p.height,
            antenna: p.antenna,
            lat: p.lat,
            lon: p.lon,
          );
        }
        nodePositions[p.nodeId] = p;
      }
      defended =
          DefendedPoint.fromJson(j['defended'] as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {
      // Corrupt prefs: start with a fresh layout.
    }
  }

  Future<void> _saveLayout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'nodes': [
            for (final n in nodePositions.values) n.toJson()
          ],
          'defended': defended.toJson(),
        }),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    for (final p in _pollers) {
      p.timer?.cancel();
      try {
        p.driver.dispose();
      } catch (_) {}
    }
    _pollers.clear();
    wifi.stop();
    super.dispose();
  }
}

/// One driver's poll loop state.
class _DriverPoller {
  _DriverPoller({required this.config, required this.driver})
      : status = DriverStatus(
          driverId: driver.driverId,
          label: config.displayLabel,
          enabled: config.enabled,
        );

  final RadioConfig config;
  final RadioDriver driver;
  final DriverStatus status;
  Timer? timer;
  bool busy = false;
}
