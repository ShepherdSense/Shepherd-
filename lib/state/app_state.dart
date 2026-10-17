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
import '../services/meshtastic_driver.dart';
import '../services/esp32_driver.dart';
import '../services/camera_driver.dart';
import '../services/generic_sensor_driver.dart';
import '../models/sensor_observation.dart';
import '../services/recorder.dart';
import '../services/replay_driver.dart';
import '../services/ai_classifier.dart';
import '../services/track_stitcher.dart';
import '../services/zmeta_adapter.dart';
import '../utils/node_ids.dart';
import '../services/wifi_aware.dart';
import '../services/wifi_rtt.dart';
import '../services/wifi_sense.dart';

/// Short display ID: strips the driver namespace (`silvus:90550` → `90550`).
/// (Moved to utils/node_ids.dart; re-exported here for existing callers.)
export '../utils/node_ids.dart';

/// Loopback test shared by the settings UI warning and the fail-closed
/// ZMeta emit gate (canonical definition in services/zmeta_adapter.dart).
export '../services/zmeta_adapter.dart' show zmetaIsLocalHost;

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
    this.zmetaEnabled = false,
    this.zmetaHost = '127.0.0.1',
    this.zmetaPort = 5555,
    this.zmetaPlatformId = 'shepherd-mesh-1',
    this.zmetaSecured = false,
    this.zmetaHeartbeatEnabled = false,
    this.zmetaHeartbeatIntervalSec = 60,
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

  /// ZMeta export: emit OBSERVATION/INFERENCE events per detection over
  /// UDP to a ZMeta gateway (emit-only). One Shepherd mesh = one ZMeta
  /// platform_id; the gateway fuses across meshes.
  bool zmetaEnabled;
  String zmetaHost;
  int zmetaPort;
  String zmetaPlatformId;

  /// Operator's acknowledgment that the ZMeta link is secured (WireGuard
  /// tunnel). The app can't verify the tunnel itself — this is the
  /// operator's attestation, and the UI warns when export targets a
  /// non-local host without it.
  bool zmetaSecured;

  /// Opt-in mesh heartbeat: periodic SYSTEM_EVENT / PLATFORM_STATUS
  /// ("alive, here is the platform") for teams on the move. Default off.
  bool zmetaHeartbeatEnabled;

  /// Heartbeat cadence in seconds, clamped 15..600 at apply time.
  int zmetaHeartbeatIntervalSec;

  TripwireConfig get tripwireConfig => TripwireConfig(
        baselineWindow: baselineWindow,
        dipThreshold: dipThreshold,
        confirmPolls: confirmPolls,
      );

  /// ZMeta settings block, persisted to SharedPreferences (the only
  /// settings block currently stored — radio configs, node layout and
  /// the GPS origin have their own keys). Missing keys keep defaults.
  Map<String, dynamic> toJson() => {
        'zmetaEnabled': zmetaEnabled,
        'zmetaHost': zmetaHost,
        'zmetaPort': zmetaPort,
        'zmetaPlatformId': zmetaPlatformId,
        'zmetaSecured': zmetaSecured,
        'zmetaHeartbeatEnabled': zmetaHeartbeatEnabled,
        'zmetaHeartbeatIntervalSec': zmetaHeartbeatIntervalSec,
      };

  void applyJson(Map<String, dynamic> j) {
    final e = j['zmetaEnabled'];
    if (e is bool) zmetaEnabled = e;
    final h = j['zmetaHost'];
    if (h is String && h.isNotEmpty) zmetaHost = h;
    final p = j['zmetaPort'];
    if (p is int && p > 0 && p < 65536) zmetaPort = p;
    final id = j['zmetaPlatformId'];
    if (id is String && id.isNotEmpty) zmetaPlatformId = id;
    final s = j['zmetaSecured'];
    if (s is bool) zmetaSecured = s;
    final hb = j['zmetaHeartbeatEnabled'];
    if (hb is bool) zmetaHeartbeatEnabled = hb;
    final hbi = j['zmetaHeartbeatIntervalSec'];
    if (hbi is int) zmetaHeartbeatIntervalSec = hbi.clamp(15, 600);
  }
}

/// Central state: polling loop, tripwire processing, tracking fusion,
/// chart history, events, node layout, and persistence.
/// Per-node link-freshness health for the tracking map overlay.
enum NodeHealthStatus {
  /// Every link touching the node is live.
  ok,
  /// Some touching links are stale.
  degraded,
  /// Links exist but all are stale.
  dead,
  /// No links touch this node yet.
  unknown,
}

/// Result of a camera-confirmation request. Upgrade-only by contract:
/// camera evidence may raise displayed confidence, never suppress a
/// detection.
class CameraConfirmationResult {
  const CameraConfirmationResult(this.status, this.note);

  /// 'NOT_CONFIGURED' until a camera integration ships.
  final String status;
  final String note;
}

class AppState extends ChangeNotifier {
  AppState() {
    _loadLayout();
    _loadGpsOrigin();
    _loadZmetaSettings();
    _initCameraDriver();
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

  /// ZMeta emit-only exporter. Created lazily on first use so a disabled
  /// export path holds no socket.
  ZMetaEmitter? _zmeta;

  /// Serializes ZMeta sends: one flight at a time, so concurrent poll
  /// ticks can't interleave datagrams or churn sockets. Batches that
  /// arrive while a send is in flight queue here instead of being
  /// dropped.
  final List<CrossingEvent> _zmetaQueue = [];
  bool _emitting = false;

  ZMetaEmitter _zmetaEmitter() {
    final cur = _zmeta;
    if (cur != null && cur.host == settings.zmetaHost && cur.port == settings.zmetaPort) {
      return cur;
    }
    cur?.close();
    final next = ZMetaEmitter(host: settings.zmetaHost, port: settings.zmetaPort);
    _zmeta = next;
    return next;
  }

  /// Last known phone position (best-effort cache). Refreshed whenever
  /// the operator captures a node position and periodically while ZMeta
  /// export is on, so per-observation geo and the heartbeat move with a
  /// dismounted team. Null until the first successful fix.
  ({double lat, double lon, double altM, double accuracyM, DateTime at})?
      _lastPhoneFix;

  /// Best-effort phone fix refresh. Never throws; a failure just leaves
  /// the previous fix (or null) in place.
  Future<void> refreshPhoneFix() async {
    try {
      final fix = await GpsPositioning.currentFix();
      _lastPhoneFix = (
        lat: fix.lat,
        lon: fix.lon,
        altM: fix.altitudeM,
        accuracyM: fix.accuracyM,
        at: DateTime.now(),
      );
    } catch (_) {}
  }

  /// Platform-level position: fresh phone fix, else the centroid of all
  /// GPS-positioned nodes, else null. Used by the heartbeat and as the
  /// fallback inside [bestKnownGeoFor].
  ZmetaSensorGeo? _platformGeo() {
    final fix = _lastPhoneFix;
    if (fix != null &&
        DateTime.now().difference(fix.at).inMinutes < 10 &&
        fix.lat.isFinite &&
        fix.lon.isFinite) {
      return ZmetaSensorGeo(
        lat: fix.lat,
        lon: fix.lon,
        altM: fix.altM.isFinite ? fix.altM : null,
        source: 'phone-gps',
        accuracyM: fix.accuracyM.isFinite ? fix.accuracyM : null,
        ageSec: DateTime.now().difference(fix.at).inSeconds,
      );
    }
    double latSum = 0, lonSum = 0;
    var n = 0;
    for (final node in effectiveNodes.values) {
      if (node.lat != null && node.lon != null) {
        latSum += node.lat!;
        lonSum += node.lon!;
        n++;
      }
    }
    if (n > 0) {
      return ZmetaSensorGeo(
        lat: latSum / n,
        lon: lonSum / n,
        source: 'node-centroid',
      );
    }
    return null;
  }

  /// Best-known SENSOR (detector) position for one link's observation,
  /// or null when nothing honest is available.
  ///
  /// Preference order:
  /// 1. Midpoint of the two link endpoints, when both are mesh nodes
  ///    with operator-surveyed GPS positions (static; trusted until
  ///    re-captured).
  /// 2. Platform position ([_platformGeo]): fresh phone fix, else node
  ///    centroid.
  ///
  /// This is the DETECTOR's position, never the target's. Canonical
  /// geo is declared 2-D (ZMeta 21.8); the device-reported altitude
  /// rides in features, flagged as not-verified-HAE.
  ZmetaSensorGeo? bestKnownGeoFor(String linkKey) {
    final parts = linkKey.split(' → ');
    if (parts.length == 2) {
      final a = effectiveNodes[parts[0]];
      final b = effectiveNodes[parts[1]];
      if (a?.lat != null && a?.lon != null && b?.lat != null && b?.lon != null) {
        return ZmetaSensorGeo(
          lat: (a!.lat! + b!.lat!) / 2,
          lon: (a.lon! + b.lon!) / 2,
          source: 'node-midpoint',
        );
      }
    }
    return _platformGeo();
  }

  /// ZMeta background timers: phone-fix refresh while export is on, and
  /// the opt-in heartbeat. Called from applySettings; stop() cancels.
  Timer? _zmetaFixTimer;
  Timer? _zmetaHeartbeatTimer;

  void _configureZmetaTimers() {
    _zmetaFixTimer?.cancel();
    _zmetaHeartbeatTimer?.cancel();
    _zmetaFixTimer = null;
    _zmetaHeartbeatTimer = null;
    if (!settings.zmetaEnabled) return;
    // Keep the phone fix warm so per-observation geo moves with the
    // team. Best-effort; failures are silent by design.
    unawaited(refreshPhoneFix());
    _zmetaFixTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(refreshPhoneFix()),
    );
    if (settings.zmetaHeartbeatEnabled) {
      final interval =
          settings.zmetaHeartbeatIntervalSec.clamp(15, 600);
      _zmetaHeartbeatTimer = Timer.periodic(
        Duration(seconds: interval),
        (_) => unawaited(_emitZmetaHeartbeat()),
      );
    }
  }

  /// One opt-in heartbeat: SYSTEM_EVENT / PLATFORM_STATUS. Same
  /// fail-closed gate as detections (non-local + unsecured = no emit),
  /// never during replay.
  Future<void> _emitZmetaHeartbeat() async {
    if (replaying) return;
    if (!zmetaIsLocalHost(settings.zmetaHost) && !settings.zmetaSecured) {
      return;
    }
    try {
      await refreshPhoneFix();
      final platform = settings.zmetaPlatformId.trim().isEmpty
          ? 'shepherd-mesh-1'
          : settings.zmetaPlatformId.trim();
      final geo = _platformGeo();
      final emitter = _zmetaEmitter();
      await emitter.send(zmetaPlatformStatus(
        platformId: platform,
        ts: DateTime.now(),
        state: 'NOMINAL',
        nodeCount: effectiveNodes.length,
        detectionCount: events.length,
        heartbeatIntervalSec:
            settings.zmetaHeartbeatIntervalSec.clamp(15, 600),
        sensorGeo: geo,
      ));
    } catch (_) {}
  }

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

  // ---- Alert triage ----
  // Operator verdicts on crossing events. Keyed by [triageKeyFor]
  // (`linkKey|timestampISO`); values are [triageAcked] or
  // [triageFalseAlarm]. Triage never deletes or reclassifies an event —
  // it only records the operator's verdict for review and tuning.
  // Entries for evicted events are pruned when the event list is trimmed.
  static const triageAcked = 'acked';
  static const triageFalseAlarm = 'false_alarm';

  final Map<String, String> triage = {};

  /// Stable identity key for one crossing event.
  static String triageKeyFor(CrossingEvent e) =>
      '${e.linkKey}|${e.timestamp.toIso8601String()}';

  /// Record a triage verdict for an event; tapping the same verdict
  /// again clears it.
  void triageEvent(CrossingEvent e, String verdict) {
    final k = triageKeyFor(e);
    if (triage[k] == verdict) {
      triage.remove(k);
    } else {
      triage[k] = verdict;
    }
    notifyListeners();
  }

  /// Counts of {acked, falseAlarm, unreviewed} across the live event list.
  Map<String, int> get triageStats {
    var acked = 0;
    var falseAlarm = 0;
    for (final e in events) {
      final v = triage[triageKeyFor(e)];
      if (v == triageAcked) {
        acked++;
      } else if (v == triageFalseAlarm) {
        falseAlarm++;
      }
    }
    return {
      'acked': acked,
      'falseAlarm': falseAlarm,
      'unreviewed': events.length - acked - falseAlarm,
    };
  }

  /// Fraction of triaged events marked false alarm. Exposed for future
  /// threshold auto-tuning — the app never auto-tunes today; a human
  /// reads this number and adjusts the detector.
  double get falseAlarmRate {
    final s = triageStats;
    final triaged = s['acked']! + s['falseAlarm']!;
    if (triaged == 0) return 0.0;
    return s['falseAlarm']! / triaged;
  }

  void _pruneTriage() {
    final live = {for (final e in events) triageKeyFor(e)};
    triage.removeWhere((k, _) => !live.contains(k));
  }

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

  /// All SDR band readings across live pollers (for the spectrum panel).
  List<SdrBand> get sdrBands {
    final out = <SdrBand>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is SdrDriver) out.addAll(d.latestBands);
    }
    return out;
  }

  /// True when at least one SDR driver is polling.
  bool get hasSdrDriver => _pollers.any((p) => p.driver is SdrDriver);

  /// Per-positioned-node health from link freshness, for the tracking
  /// map's health overlay: ok = every touching link live, degraded =
  /// some stale, dead = links exist but all stale, unknown = no links
  /// touch this node yet.
  Map<String, NodeHealthStatus> get nodeHealthMap {
    final out = <String, NodeHealthStatus>{};
    final now = DateTime.now();
    for (final n in effectiveNodes.values) {
      final id = n.nodeId;
      var total = 0;
      var live = 0;
      history.forEach((key, samples) {
        if (samples.isEmpty) return;
        final parts = key.split(' → ');
        if (parts.length == 2 && (parts[0] == id || parts[1] == id)) {
          total++;
          if (_isLive(samples.last, now)) live++;
        }
      });
      out[id] = total == 0
          ? NodeHealthStatus.unknown
          : live == total
              ? NodeHealthStatus.ok
              : live > 0
                  ? NodeHealthStatus.degraded
                  : NodeHealthStatus.dead;
    }
    return out;
  }

  // ---- Camera confirmation (UPGRADE-ONLY) ----
  // Camera evidence may UPGRADE the displayed confidence of a detection —
  // it must NEVER veto or suppress one. A detection stands on RF evidence
  // alone; the camera can only add context. Absence of motion means
  // nothing (occlusion, night, facing away).
  static const _cameraSettingsKey = 'shepherd_camera_v1';

  CameraSettings cameraSettings = CameraSettings();
  late final CameraDriver _cameraDriver;

  bool get cameraConfirmationEnabled => cameraSettings.enabled;

  void _initCameraDriver() {
    _cameraDriver = CameraDriver(settings: cameraSettings);
    _cameraDriver.onObservation = (obs) {
      // Camera motion joins the shared observation store (bounded) and
      // the ZMeta export path (EO modality).
      sensorObservations.add(obs);
      if (sensorObservations.length > 500) {
        sensorObservations.removeRange(0, sensorObservations.length - 500);
      }
      unawaited(_emitZmetaSensorObs([obs]));
    };
    unawaited(_loadCameraSettings());
  }

  // ---- Universal sensor observations ----
  // Observations from GenericSensorDriver pollers (lidar, acoustic,
  // PIR, …) land here for the map overlay and evidence views. The RF
  // tripwire stays the detection authority; these are corroboration.
  final List<SensorObservation> sensorObservations = [];
  DateTime _lastSensorPull = DateTime.fromMillisecondsSinceEpoch(0);

  void _collectSensorObservations(_DriverPoller p) {
    final d = p.driver;
    if (d is! GenericSensorDriver) return;
    final fresh = d.observationsSince(_lastSensorPull);
    if (fresh.isEmpty) return;
    _lastSensorPull = DateTime.now();
    sensorObservations.addAll(fresh);
    if (sensorObservations.length > 500) {
      sensorObservations.removeRange(0, sensorObservations.length - 500);
    }
    unawaited(_emitZmetaSensorObs(fresh));
  }

  /// Emits acoustic/EO sensor observations to the ZMeta gateway.
  /// Same fail-closed gate as detections: never during replay, never
  /// to a non-local host unless the link is secured. RANGE/BINARY/
  /// ENERGY have no honest ZMeta modality and stay local.
  Future<void> _emitZmetaSensorObs(List<SensorObservation> obs) async {
    if (replaying) return;
    if (!settings.zmetaEnabled) return;
    if (!zmetaIsLocalHost(settings.zmetaHost) && !settings.zmetaSecured) {
      return;
    }
    try {
      final emitter = _zmetaEmitter();
      final platform = settings.zmetaPlatformId.trim().isEmpty
          ? 'shepherd-mesh-1'
          : settings.zmetaPlatformId.trim();
      for (final o in obs) {
        final evt = zmetaSensorObservation(platformId: platform, obs: o);
        if (evt == null) continue; // no honest modality — stays local
        await emitter.send(evt);
      }
    } catch (_) {}
  }

  Future<void> _loadCameraSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cameraSettingsKey);
      if (raw == null) return;
      cameraSettings = CameraSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      _cameraDriver.settings
        ..enabled = cameraSettings.enabled
        ..webhookPort = cameraSettings.webhookPort
        ..onvifAddress = cameraSettings.onvifAddress
        ..onvifUser = cameraSettings.onvifUser
        ..onvifPass = cameraSettings.onvifPass
        ..snapshotUrlTemplate = cameraSettings.snapshotUrlTemplate;
      if (cameraSettings.enabled) unawaited(_cameraDriver.start());
      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveCameraSettings(CameraSettings s) async {
    cameraSettings = s;
    _cameraDriver.settings
      ..enabled = s.enabled
      ..webhookPort = s.webhookPort
      ..onvifAddress = s.onvifAddress
      ..onvifUser = s.onvifUser
      ..onvifPass = s.onvifPass
      ..snapshotUrlTemplate = s.snapshotUrlTemplate;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cameraSettingsKey, jsonEncode(s.toJson()));
    } catch (_) {}
    if (s.enabled) {
      unawaited(_cameraDriver.start());
    } else {
      _cameraDriver.dispose();
    }
    notifyListeners();
  }

  void toggleCameraConfirmation(bool on) {
    cameraSettings.enabled = on;
    unawaited(saveCameraSettings(cameraSettings));
  }

  /// Upgrade-only camera confirmation request. Consults recent camera
  /// motion: CORROBORATED upgrades displayed confidence; anything else
  /// leaves the RF detection standing unchanged.
  CameraConfirmationResult requestCameraConfirmation(CrossingEvent e) {
    if (!cameraSettings.enabled) {
      return const CameraConfirmationResult(
        'NOT_CONFIGURED',
        'No camera integration configured. '
        'Detection stands on RF evidence alone.',
      );
    }
    final motion = _cameraDriver.recentMotion(const Duration(seconds: 30));
    if (motion.isNotEmpty) {
      return CameraConfirmationResult(
        'CORROBORATED',
        '${motion.length} camera motion observation(s) within 30 s of '
        'the detection window. Displayed confidence upgraded; RF '
        'evidence unchanged.',
      );
    }
    return const CameraConfirmationResult(
      'NO_MOTION',
      'Camera configured but no motion in the detection window. '
      'Informational only — detection stands on RF evidence alone.',
    );
  }

  void applySettings(AppSettings s) {
    final wasPolling = polling;
    final wasWifi = wifiVisionEnabled;
    stop();
    settings = s;
    unawaited(_saveZmetaSettings());
    _configureZmetaTimers();
    _tripwire = Tripwire(config: s.tripwireConfig);
    _tracker.reset();
    track = null;
    history.clear();
    events.clear();
    triage.clear();
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

  /// The session recorder. Toggle from Settings; records raw samples.
  final RecordingService recorder = RecordingService();

  bool get isRecording => recorder.isRecording;

  /// True while a recording is being replayed instead of live radios.
  bool replaying = false;

  Future<String> startRecording() async {
    final path = await recorder.start();
    notifyListeners();
    return path;
  }

  Future<String> stopRecording() async {
    final summary = await recorder.stop();
    notifyListeners();
    return summary;
  }

  /// Replay a recording through the live detector pipeline: stops live
  /// pollers, runs the CSV on its own clock with a fresh tripwire.
  Future<void> startReplay(String path, {double speed = 1.0}) async {
    stop();
    // A recording in progress would swallow the replayed samples into
    // its tuning CSV (they flow through _tickPoller). Stop it first —
    // replaying over an active recording is never what the operator
    // meant.
    if (recorder.isRecording) {
      await recorder.stop();
    }
    replaying = true;
    _tripwire = Tripwire(config: settings.tripwireConfig);
    _tracker.reset();
    track = null;
    history.clear();
    events.clear();
    _latestByPoller.clear();
    _lastSampleTs.clear();
    final driver = ReplayDriver(path: path, speed: speed);
    _addPoller(
      RadioConfig(
        driverId: 'replay',
        address: path,
        label: 'REPLAY ${speed}x',
        pollInterval: 0.25,
      ),
      driver,
    );
    polling = true;
    connectionLabel = 'Replaying recording…';
    notifyListeners();
    for (final p in _pollers) {
      _tickPoller(p);
      p.timer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _tickPoller(p),
      );
    }
    // Dead-man check, same as start(): a frozen replay must not leave
    // the banner stuck. stop()/stopReplay() already cancel it.
    _watchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _watchdogTick(),
    );
  }

  void stopReplay() {
    replaying = false;
    stop();
    connectionLabel = 'Idle — press Start';
    notifyListeners();
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
    _zmetaFixTimer?.cancel();
    _zmetaFixTimer = null;
    _zmetaHeartbeatTimer?.cancel();
    _zmetaHeartbeatTimer = null;
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
      _collectSensorObservations(p);
      // The poller may have been stopped or replaced (settings change,
      // restart) while this poll was in flight. Its samples belong to a
      // session that no longer exists; don't let them into the new one.
      if (!polling || !_pollers.contains(p)) return;
      // Replayed samples never enter a recording: the tuning CSV must
      // hold live sensor data only.
      if (recorder.isRecording && !replaying) {
        for (final r in raw) {
          recorder.record(r);
        }
      }
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
      // No audible alert for replayed detections: the operator is
      // rehearsing, not watching a live mesh.
      if (classified.isNotEmpty && !replaying) unawaited(_alert(AlertKind.detection));
      events.insertAll(0, classified);
      // Replay never exports: replayed detections are stale history,
      // and pushing them to the operational gateway would corrupt
      // fusion. (The fail-closed host/secured gate lives in _emitZmeta.)
      if (settings.zmetaEnabled && classified.isNotEmpty && !replaying) {
        // Emit-only ZMeta export: must never disturb detection.
        unawaited(_emitZmeta(classified));
      }
      if (events.length > 200) {
        events.removeRange(200, events.length);
      }
      _pruneTriage();
      if (!settings.simulatedMode) _ensureNodes(raw);
      // Mesh drivers that report GPS: pin nodes to real geometry.
      final drv = p.driver;
      if (drv is MeshtasticDriver) {
        _applyMeshPositions(drv.meshPositions());
      } else if (drv is Esp32Driver) {
        _applyMeshPositions(drv.meshPositions());
        _applyBeaconCallsigns(drv.beaconCallsigns);
      }
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
    // Spectrum-band virtual links (SDR energy watch), KrakenSDR
    // bearings, and sensor-bus virtual links feed the tripwire and alerts
    // like any link, but they carry no geometry -- a hot band is not a
    // position, one bearing is a direction not a fix, and a PIR trip is
    // a point event. Keep them out of the position solver, the
    // shadow grid, and the stitcher so they can't drag the track.
    final geo = [
      for (final s in all)
        if (driverOf(s.fromNode) != 'sdr' &&
            driverOf(s.fromNode) != 'kraken' &&
            driverOf(s.fromNode) != 'esp32' &&
            driverOf(s.fromNode) != 'sensor')
          s,
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

  /// ZMeta export (emit-only): one OBSERVATION_EVENT per crossing, plus
  /// an INFERENCE_EVENT when the embedded classifier labeled it. Never
  /// throws — a down gateway must not disturb detection.
  ///
  /// Two hard gates before anything leaves the device:
  /// - fail-closed security: a non-local gateway without the operator's
  ///   WireGuard attestation ([AppSettings.zmetaSecured]) gets nothing;
  ///   loopback targets ([zmetaIsLocalHost]) need no tunnel;
  /// - replay: replayed detections are stale history and are never
  ///   exported to the operational gateway (also guarded at the call
  ///   site — belt and suspenders).
  Future<void> _emitZmeta(List<CrossingEvent> evts) async {
    if (replaying) return;
    if (!zmetaIsLocalHost(settings.zmetaHost) && !settings.zmetaSecured) {
      return;
    }
    _zmetaQueue.addAll(evts);
    if (_emitting) return; // the in-flight drain picks these up
    _emitting = true;
    try {
      while (_zmetaQueue.isNotEmpty) {
        final batch = _zmetaQueue.toList();
        _zmetaQueue.clear();
        await _sendZmetaBatch(batch);
      }
    } finally {
      _emitting = false;
    }
  }

  /// One serialized batch of ZMeta events over UDP. Never throws.
  Future<void> _sendZmetaBatch(List<CrossingEvent> evts) async {
    try {
      final emitter = _zmetaEmitter();
      final platform = settings.zmetaPlatformId.trim().isEmpty
          ? 'shepherd-mesh-1'
          : settings.zmetaPlatformId.trim();
      for (final e in evts) {
        final rf = _zmetaRf(e.linkKey);
        if (rf == null) continue; // refuse rather than fabricate
        final obs = zmetaObservation(
          platformId: platform,
          sensorId: e.linkKey,
          ts: e.timestamp,
          linkKey: e.linkKey,
          driverId: driverOf(e.linkKey.split(' → ').first),
          dipDepthDb: e.dipDepth,
          direction: e.direction,
          durationSecs: e.durationSecs,
          sizeEstimate: e.sizeEstimate,
          freqHz: rf.freqHz,
          bwHz: rf.bwHz,
          viaVariance: e.viaVariance,
          energyDbfs: rf.energyDbfs,
          doaArrayRelativeDeg: rf.doaDeg,
          sensorGeo: bestKnownGeoFor(e.linkKey),
        );
        await emitter.send(obs);
        if (e.aiLabel != null && e.aiConfidence != null) {
          final obsId = (obs['event'] as Map)['event_id'] as String;
          await emitter.send(zmetaInference(
            platformId: platform,
            observationId: obsId,
            ts: e.timestamp,
            label: e.aiLabel!,
            confidence: e.aiConfidence!,
          ));
        }
      }
    } catch (_) {}
  }

  /// Honest RF parameters for a link key, or null when they can't be
  /// established (the event is then refused, not fabricated).
  _ZmetaRf? _zmetaRf(String linkKey) {
    final parts = linkKey.split(' → ');
    final driver = driverOf(parts.first);
    switch (driver) {
      case 'silvus':
      case 'sim':
        // His Silvus pair: 2440 MHz, 10 MHz channel.
        return const _ZmetaRf(2440000000, 10000000);
      case 'sdr':
        // Virtual link `sdr:<radio> → sdr:band-<label>`: look up the
        // band the bridge last reported.
        if (parts.length < 2) return null;
        final label = parts[1].startsWith('sdr:band-')
            ? parts[1].substring('sdr:band-'.length)
            : parts[1];
        for (final p in _pollers) {
          final d = p.driver;
          if (d is SdrDriver) {
            for (final b in d.latestBands) {
              if (b.band == label) {
                return _ZmetaRf(
                  b.centerMhz * 1e6,
                  b.bwMhz * 1e6,
                  energyDbfs: b.energyDbfs,
                );
              }
            }
          }
        }
        return null;
      case 'kraken':
        // Virtual link `kraken:doa → kraken:<freq>MHz`.
        if (parts.length < 2) return null;
        final m = RegExp(r'([\d.]+)MHz').firstMatch(parts[1]);
        final mhz = m == null ? null : double.tryParse(m.group(1)!);
        if (mhz == null) return null;
        final h = history[linkKey];
        final doa = (h != null && h.isNotEmpty) ? h.last.bearingDeg : null;
        return _ZmetaRf(mhz * 1e6, 0.0, doaDeg: doa);
      default:
        return null;
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

  // ---- ZMeta settings (persisted) ----

  static const _zmetaSettingsKey = 'rf_sentry_zmeta_v1';

  Future<void> _loadZmetaSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_zmetaSettingsKey);
      if (raw == null) return;
      settings.applyJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt prefs: keep defaults.
    }
    notifyListeners();
  }

  Future<void> _saveZmetaSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _zmetaSettingsKey,
        jsonEncode(settings.toJson()),
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

  /// Place mesh nodes from their GPS positions. The driver reports
  /// lat/lon per node; here they become field-local x/y so the tracking
  /// map and the position solver see real geometry. Nodes the user has
  /// already dragged keep their manual position — GPS only fills in
  /// nodes that were auto-placed.
  void _applyMeshPositions(Map<String, ({double lat, double lon})> pos) {
    if (pos.isEmpty) return;
    // Origin: the persisted GPS origin if the user captured one,
    // otherwise the first mesh node with a fix.
    double? lat0 = gpsOrigin?.lat;
    double? lon0 = gpsOrigin?.lon;
    lat0 ??= pos.values.first.lat;
    lon0 ??= pos.values.first.lon;
    var changed = false;
    for (final e in pos.entries) {
      final n = nodePositions[e.key];
      if (n == null) continue; // _ensureNodes creates it next poll
      n.lat = e.value.lat;
      n.lon = e.value.lon;
      if (!n.userPlaced) {
        final m = latLonToMeters(e.value.lat, e.value.lon, lat0, lon0);
        n.x = m.x;
        n.y = m.y;
        changed = true;
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
    n.userPlaced = true;
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

  /// Callsign validation: 1-16 chars, A-Z 0-9 dash/underscore/space.
  /// Returns the cleaned callsign, or null if invalid.
  static String? cleanCallsign(String raw) {
    final c = raw.trim().toUpperCase();
    if (c.isEmpty || c.length > 16) return null;
    if (!RegExp(r'^[A-Z0-9 _-]+$').hasMatch(c)) return null;
    return c;
  }

  /// Operator-set callsign for a node. Empty string clears it (falls
  /// back to a beacon callsign, then the hardware id). Persists.
  /// Returns false when the callsign is invalid.
  bool setNodeCallsign(String id, String raw) {
    final n = nodePositions[id];
    if (n == null) return false;
    final c = raw.trim();
    if (c.isEmpty) {
      n.callsign = null;
      n.callsignByUser = false;
    } else {
      final clean = cleanCallsign(c);
      if (clean == null) return false;
      n.callsign = clean;
      n.callsignByUser = true;
    }
    _saveLayout();
    notifyListeners();
    return true;
  }

  /// Beacon-broadcast callsigns (ESP32 status page). Never overwrite a
  /// user-set callsign.
  void _applyBeaconCallsigns(Map<String, String> beaconCallsigns) {
    var changed = false;
    for (final e in beaconCallsigns.entries) {
      final n = nodePositions[e.key];
      if (n == null || n.callsignByUser) continue;
      final clean = cleanCallsign(e.value);
      if (clean == null) continue;
      if (n.callsign != clean) {
        n.callsign = clean;
        changed = true;
      }
    }
    if (changed) {
      _saveLayout();
      notifyListeners();
    }
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
      _lastPhoneFix = (
        lat: fix.lat,
        lon: fix.lon,
        altM: fix.altitudeM,
        accuracyM: fix.accuracyM,
        at: DateTime.now(),
      );
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
      n.userPlaced = true;
      _saveLayout();
      _lastPhoneFix = (
        lat: fix.lat,
        lon: fix.lon,
        altM: fix.altitudeM,
        accuracyM: fix.accuracyM,
        at: DateTime.now(),
      );
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
      _lastPhoneFix = (
        lat: fix.lat,
        lon: fix.lon,
        altM: fix.altitudeM,
        accuracyM: fix.accuracyM,
        at: DateTime.now(),
      );
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
    _zmeta?.close();
    _zmeta = null;
    for (final p in _pollers) {
      p.timer?.cancel();
      try {
        p.driver.dispose();
      } catch (_) {}
    }
    _pollers.clear();
    wifi.stop();
    try {
      _cameraDriver.dispose();
    } catch (_) {}
    super.dispose();
  }
}

/// One driver's poll loop state.
/// Honest RF parameters for one link, resolved for ZMeta export.
class _ZmetaRf {
  const _ZmetaRf(this.freqHz, this.bwHz, {this.doaDeg, this.energyDbfs});
  final double freqHz;
  final double bwHz;
  final double? doaDeg;
  final double? energyDbfs;
}

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
