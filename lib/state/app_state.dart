import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

import '../models/link_sample.dart';
import '../models/tracking.dart';
import '../services/discovery.dart';
import '../services/gps_positioning.dart';
import '../services/health.dart';
import '../services/tracker.dart';
import '../services/tripwire.dart';
import '../services/adaptive_baseline.dart';
import '../services/field_activity.dart';
import '../services/radio_driver.dart';
import '../services/meshtastic_driver.dart';
import '../services/esp32_driver.dart';
import '../services/node_udp_hub.dart';
import '../services/camera_driver.dart';
import '../services/confidence_merger.dart';
import '../services/cot_listener.dart';
import '../services/cot_publisher.dart';
import '../services/geo_projection.dart';
import '../services/sensor_protocol.dart';
import '../services/track_consistency.dart';
import '../services/generic_sensor_driver.dart';
import '../models/sensor_observation.dart';
import '../services/recorder.dart';
import '../services/replay_driver.dart';
import '../services/ai_classifier.dart';
import '../services/track_stitcher.dart';
import '../services/zmeta_adapter.dart';
import '../services/zmeta_https_ingest.dart';
import '../services/zmeta_ingest_store.dart';
import '../services/zmeta_pairing.dart' show zmetaIsUsableIngestUrl;
import '../utils/node_ids.dart';
import '../services/wifi_aware.dart';
import '../services/wifi_rtt.dart';
import '../services/wifi_sense.dart';
import '../services/airframe_identity.dart';
import '../services/simulated.dart';
import '../services/remote_id.dart';
import '../services/remote_id_service.dart';
import '../services/device_signatures.dart';
import '../services/hunt_tracker.dart';
import '../services/offline_map_source.dart';
import '../services/phone_tier.dart';
import '../services/device_autoconnect.dart';

/// Short display ID: strips the driver namespace (`silvus:90550` → `90550`).
/// (Moved to utils/node_ids.dart; re-exported here for existing callers.)
export '../utils/node_ids.dart';

/// Loopback test shared by the settings UI warning and the fail-closed
/// ZMeta emit gate (canonical definition in services/zmeta_adapter.dart).
export '../services/zmeta_adapter.dart' show zmetaIsLocalHost;

/// Evidence-line wording for one fresh CoT emitter observation.
/// Honesty contract: "coincident" — never "confirmed", never identity.
String cotEmitterEvidenceLine(String callsign) =>
    'RF emitter reported at this position by $callsign (coincident)';

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
    this.autoConnectSilvusUsb = true,
    this.wifiDipThresholdDb = 6.0,
    this.zmetaEnabled = false,
    this.zmetaHost = '127.0.0.1',
    this.zmetaPort = 5555,
    this.zmetaPlatformId = 'shepherd-mesh-1',
    this.zmetaTransport = 'udp',
    this.zmetaIngestUrl = '',
    this.zmetaIngestFp = '',
    this.zmetaJoinedPlatformId = '',
    this.zmetaSecured = false,
    this.zmetaHeartbeatEnabled = false,
    this.zmetaHeartbeatIntervalSec = 60,
    this.cotEmitEnabled = false,
    this.cotEmitUseMulticast = true,
    this.cotMulticastGroup = '239.2.3.1',
    this.cotMulticastPort = 6969,
    this.cotTakHost = '',
    this.cotTakPort = 8087,
    this.cotStaleSeconds = 30,
    this.cotPublishFloor = 0.3,
    this.cotCallsignPrefix = 'SHEPHERD-',
    this.cotAirTypeThreshold = 0.5,
    this.cotListenEnabled = false,
    this.cotListenMulticastGroup = '239.2.3.1',
    this.cotListenMulticastPort = 6969,
    this.cotListenWindowSeconds = 60,
    this.cotEmitterPrefix = 'PREDATOR-',
    this.friendlySerials = '',
    this.remoteIdEnabled = false,
    this.droneEoUrl = 'rtsp://192.168.42.10:5554/subject',
    this.droneIrUrl = 'rtsp://192.168.42.10:6554/infrared',
    this.droneCloudEoUrl = '',
    this.droneCloudIrUrl = '',
    this.droneStreamSource = 'local',
    this.trustedSources = '',
    this.cotCoincidenceRadiusM = 50.0,
    this.sdrStationLat,
    this.sdrStationLon,
    this.sdrEnbLat,
    this.sdrEnbLon,
    this.sdrEnbCenterMhz,
    this.sdrAutoStation = false,
    this.phoneTierEnabled = true,
    this.deviceSignaturesEnabled = false,
    this.tileSourceId = 'osm_standard',
  });

  String radioIp;
  String subnet;
  double pollInterval;
  double dipThreshold;
  int confirmPolls;
  int baselineWindow;
  bool simulatedMode;

  /// Auto-connect: when a Silvus radio appears on USB (172.17.97.x
  /// interface), validate it and add it as a radio config automatically.
  /// Never removes configs — unplug only marks the driver offline.
  bool autoConnectSilvusUsb;

  /// WiFi dip depth (dB below rolling median) that counts as a disturbance.
  double wifiDipThresholdDb;

  /// ZMeta export: emit OBSERVATION/INFERENCE events per detection over
  /// UDP to a ZMeta gateway (emit-only). One Shepherd mesh = one ZMeta
  /// platform_id; the gateway fuses across meshes.
  bool zmetaEnabled;
  String zmetaHost;
  int zmetaPort;
  String zmetaPlatformId;

  /// Transport for ZMeta export: 'udp' (manual host/port, default),
  /// 'https' (hub-issued ingest URL + bearer token — the no-WireGuard
  /// path for forward-deployed operators), or 'wireguard' (joined via
  /// invite code; still UDP underneath, to the tunnel address).
  String zmetaTransport;

  /// HTTPS ingest endpoint for [zmetaTransport] == 'https', set by the
  /// join flow. The bearer token lives in secure storage (see
  /// zmeta_ingest_store.dart), never here.
  String zmetaIngestUrl;

  /// TLS mode for the HTTPS ingest endpoint, captured from the invite
  /// code's certfp at join time: '-' (Cloudflare / public-CA mode) or
  /// 64-hex (pinned self-signed). The emitter builds its HttpClient
  /// accordingly — a pin-mode hub must not silently drop events.
  String zmetaIngestFp;

  /// Platform ID the mesh joined under (set by the join flow). If the
  /// operator later edits [zmetaPlatformId] to something else, the stored
  /// token / hub peer no longer matches — see [zmetaPlatformMismatch].
  String zmetaJoinedPlatformId;

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

  /// CoT track output (emit-only, defensive-only): publish the fused
  /// track as a CoT event per update — the only bytes Shepherd ever
  /// sends. Affiliation is always unknown (enforced in CotPublisher).
  bool cotEmitEnabled;

  /// true = UDP multicast (default), false = TAK Server TCP.
  bool cotEmitUseMulticast;
  String cotMulticastGroup;
  int cotMulticastPort;
  String cotTakHost;
  int cotTakPort;

  /// Stale window in seconds (track loss signaled by letting the
  /// event go stale — no explicit deletes).
  int cotStaleSeconds;

  /// Tracks below this displayed confidence are never published.
  double cotPublishFloor;

  /// Emit callsign/uid prefix, e.g. 'SHEPHERD-' (hyphen, no space).
  /// Non-empty, no whitespace (validated at apply time).
  String cotCallsignPrefix;

  /// Type-guess confidence at or above this, with an air-type guess,
  /// emits `a-u-A`; otherwise `a-u-G`. Clamped 0..1.
  double cotAirTypeThreshold;

  /// CoT emitter ingest (RX-only): keep only events whose callsign
  /// starts with [cotEmitterPrefix] and feed spatial coincidences
  /// into the gated merger as upgrade-only corroboration.
  bool cotListenEnabled;

  /// Listen-side multicast destination (operator-tunable, like the
  /// emit side). Defaults match the emit default group/port.
  String cotListenMulticastGroup;
  int cotListenMulticastPort;

  /// Observation lifetime in seconds for the ingest window.
  /// Clamped 10..600 at apply time.
  int cotListenWindowSeconds;

  String cotEmitterPrefix;
  double cotCoincidenceRadiusM;

  /// Friendly airframe registry text (Skydio P1): one airframe per
  /// line, `SERIAL[, CALLSIGN[, A|B]]` — battery-tray ANSI serials,
  /// typed in by the operator. Parsed by FriendlyRegistry. A match
  /// changes rendering/correlation ONLY — it never suppresses a
  /// track or an alert. Empty = no friendly registry.
  String friendlySerials;

  /// Remote ID receiver (Skydio P2): decode ASTM F3411 broadcasts
  /// from BLE advertisements (rides the existing BLE scan) and, on
  /// Android, Wi-Fi beacons in the existing survey. Receive-only.
  /// Off by default (a new sensor stays opt-in).
  bool remoteIdEnabled;

  /// Drone tab stream endpoints (Skydio P3). Vehicle-direct RTSP on
  /// the local link (the Skydio documented fit): EO is the subject
  /// stream, IR the thermal — separate simultaneous streams; the
  /// viewer switches between them, no control channel is used. The
  /// EO stream shows the pilot's selected focal view (wide/tele is
  /// chosen by the pilot, in the single EO stream).
  String droneEoUrl;
  String droneIrUrl;

  /// Cloud-announced stream URLs (Skydio Cloud webhook variant).
  /// Empty = local-link streams only.
  String droneCloudEoUrl;
  String droneCloudIrUrl;

  /// Which endpoint set the Drone tab uses: 'local' or 'cloud'.
  String droneStreamSource;

  /// Comma-separated sender IPs accepted on the unauthenticated UDP
  /// inputs (node beacons/events on 49160 and the CoT multicast
  /// listener). Empty = accept any sender on the segment.
  String trustedSources;

  /// SDR station geometry for the passive-Doppler correlator (WGS84).
  /// Null until the operator configures it in Settings → SDR station;
  /// without all four coordinates the correlator abstains. Converted
  /// to field-local meters (via the GPS field origin when set, else
  /// relative to the station) by [AppState.applySdrStationFromSettings]
  /// and pushed to the SDR drivers with setSdrStation.
  double? sdrStationLat;
  double? sdrStationLon;
  double? sdrEnbLat;
  double? sdrEnbLon;

  /// LTE eNB center frequency (MHz) the geometry refers to. Operator
  /// record, persisted with the coordinates; the bridge's Doppler refs
  /// carry their own tuned center.
  double? sdrEnbCenterMhz;

  /// AUTO station: when true, the SDR station position is taken from
  /// the device's own GPS fix (the SDR host is the device in the field
  /// setup) instead of the hand-entered station coordinates, which are
  /// kept untouched underneath. The eNB position has no honest auto
  /// source (no tower database on-device) and always stays manual.
  bool sdrAutoStation;

  /// Phone-only tier master switch (v0.26.0, Fieldwatch borrow).
  /// Default true, but the tier ONLY activates when no mesh/SDR
  /// hardware is attached (see [AppState.phoneTier]) — mesh users
  /// see zero change from this default.
  bool phoneTierEnabled;

  /// Device-signature library master switch (v0.26.0). Default
  /// false, per the builder suggestion: signature matches are
  /// HYPOTHESES, never identity, and stay opt-in.
  bool deviceSignaturesEnabled;

  /// Selected keyless tile source id (v0.26.0 offline-maps
  /// pattern). Default 'osm_standard' (OpenStreetMap Standard).
  /// Unknown ids fall back to the default via [selectTileSource];
  /// keyed providers are never built in.
  String tileSourceId;

  TripwireConfig get tripwireConfig => TripwireConfig(
        baselineWindow: baselineWindow,
        dipThreshold: dipThreshold,
        confirmPolls: confirmPolls,
      );

  /// ZMeta settings block, persisted to SharedPreferences (the only
  /// settings block currently stored — radio configs, node layout and
  /// the GPS origin have their own keys). Missing keys keep defaults.
  Map<String, dynamic> toJson() => {
        'autoConnectSilvusUsb': autoConnectSilvusUsb,
        'zmetaEnabled': zmetaEnabled,
        'zmetaHost': zmetaHost,
        'zmetaPort': zmetaPort,
        'zmetaPlatformId': zmetaPlatformId,
        'zmetaTransport': zmetaTransport,
        'zmetaIngestUrl': zmetaIngestUrl,
        'zmetaIngestFp': zmetaIngestFp,
        'zmetaJoinedPlatformId': zmetaJoinedPlatformId,
        'zmetaSecured': zmetaSecured,
        'zmetaHeartbeatEnabled': zmetaHeartbeatEnabled,
        'zmetaHeartbeatIntervalSec': zmetaHeartbeatIntervalSec,
        'cotEmitEnabled': cotEmitEnabled,
        'cotEmitUseMulticast': cotEmitUseMulticast,
        'cotMulticastGroup': cotMulticastGroup,
        'cotMulticastPort': cotMulticastPort,
        'cotTakHost': cotTakHost,
        'cotTakPort': cotTakPort,
        'cotStaleSeconds': cotStaleSeconds,
        'cotPublishFloor': cotPublishFloor,
        'cotCallsignPrefix': cotCallsignPrefix,
        'cotAirTypeThreshold': cotAirTypeThreshold,
        'cotListenEnabled': cotListenEnabled,
        'cotListenMulticastGroup': cotListenMulticastGroup,
        'cotListenMulticastPort': cotListenMulticastPort,
        'cotListenWindowSeconds': cotListenWindowSeconds,
        'cotEmitterPrefix': cotEmitterPrefix,
        'friendlySerials': friendlySerials,
        'remoteIdEnabled': remoteIdEnabled,
        'droneEoUrl': droneEoUrl,
        'droneIrUrl': droneIrUrl,
        'droneCloudEoUrl': droneCloudEoUrl,
        'droneCloudIrUrl': droneCloudIrUrl,
        'droneStreamSource': droneStreamSource,
        'trustedSources': trustedSources,
        'cotCoincidenceRadiusM': cotCoincidenceRadiusM,
        'sdrStationLat': sdrStationLat,
        'sdrStationLon': sdrStationLon,
        'sdrEnbLat': sdrEnbLat,
        'sdrEnbLon': sdrEnbLon,
        'sdrEnbCenterMhz': sdrEnbCenterMhz,
        'sdrAutoStation': sdrAutoStation,
        'phoneTierEnabled': phoneTierEnabled,
        'deviceSignaturesEnabled': deviceSignaturesEnabled,
        'tileSourceId': tileSourceId,
      };

  void applyJson(Map<String, dynamic> j) {
    final ac = j['autoConnectSilvusUsb'];
    if (ac is bool) autoConnectSilvusUsb = ac;
    final sa = j['sdrAutoStation'];
    if (sa is bool) sdrAutoStation = sa;
    final e = j['zmetaEnabled'];
    if (e is bool) zmetaEnabled = e;
    final h = j['zmetaHost'];
    if (h is String && h.isNotEmpty) zmetaHost = h;
    final p = j['zmetaPort'];
    if (p is int && p > 0 && p < 65536) zmetaPort = p;
    final id = j['zmetaPlatformId'];
    if (id is String && id.isNotEmpty) zmetaPlatformId = id;
    final tr = j['zmetaTransport'];
    if (tr is String && (tr == 'udp' || tr == 'https' || tr == 'wireguard')) {
      zmetaTransport = tr;
    }
    final iu = j['zmetaIngestUrl'];
    if (iu is String) zmetaIngestUrl = iu;
    final fp = j['zmetaIngestFp'];
    if (fp is String && (fp == '-' || RegExp(r'^[0-9a-f]{64}$').hasMatch(fp))) {
      zmetaIngestFp = fp;
    }
    final jid = j['zmetaJoinedPlatformId'];
    if (jid is String) zmetaJoinedPlatformId = jid;
    // Migration: meshes joined via the WireGuard flow before the
    // transport field existed target the hub's tunnel subnet.
    if (zmetaTransport == 'udp' && zmetaHost.startsWith('10.99.')) {
      zmetaTransport = 'wireguard';
    }
    final s = j['zmetaSecured'];
    if (s is bool) zmetaSecured = s;
    final hb = j['zmetaHeartbeatEnabled'];
    if (hb is bool) zmetaHeartbeatEnabled = hb;
    final hbi = j['zmetaHeartbeatIntervalSec'];
    if (hbi is int) zmetaHeartbeatIntervalSec = hbi.clamp(15, 600);
    final cotEmit = j['cotEmitEnabled'];
    if (cotEmit is bool) cotEmitEnabled = cotEmit;
    final cotMulti = j['cotEmitUseMulticast'];
    if (cotMulti is bool) cotEmitUseMulticast = cotMulti;
    final cotGroup = j['cotMulticastGroup'];
    if (cotGroup is String && cotGroup.isNotEmpty) {
      cotMulticastGroup = cotGroup;
    }
    final cotMport = j['cotMulticastPort'];
    if (cotMport is int && cotMport > 0 && cotMport < 65536) {
      cotMulticastPort = cotMport;
    }
    final cotHost = j['cotTakHost'];
    if (cotHost is String) cotTakHost = cotHost;
    final cotTport = j['cotTakPort'];
    if (cotTport is int && cotTport > 0 && cotTport < 65536) {
      cotTakPort = cotTport;
    }
    final cotStale = j['cotStaleSeconds'];
    if (cotStale is int) cotStaleSeconds = cotStale.clamp(5, 300);
    final cotFloor = j['cotPublishFloor'];
    if (cotFloor is num) cotPublishFloor = cotFloor.clamp(0.0, 1.0).toDouble();
    final cotCs = j['cotCallsignPrefix'];
    if (cotCs is String &&
        cotCs.isNotEmpty &&
        !RegExp(r'\s').hasMatch(cotCs)) {
      cotCallsignPrefix = cotCs;
    }
    final cotAir = j['cotAirTypeThreshold'];
    if (cotAir is num) {
      cotAirTypeThreshold = cotAir.clamp(0.0, 1.0).toDouble();
    }
    final cotListen = j['cotListenEnabled'];
    if (cotListen is bool) cotListenEnabled = cotListen;
    final cotListenGroup = j['cotListenMulticastGroup'];
    if (cotListenGroup is String && cotListenGroup.isNotEmpty) {
      cotListenMulticastGroup = cotListenGroup;
    }
    final cotListenPort = j['cotListenMulticastPort'];
    if (cotListenPort is int &&
        cotListenPort > 0 &&
        cotListenPort < 65536) {
      cotListenMulticastPort = cotListenPort;
    }
    final cotListenWindow = j['cotListenWindowSeconds'];
    if (cotListenWindow is int) {
      cotListenWindowSeconds = cotListenWindow.clamp(10, 600);
    }
    final ts = j['trustedSources'];
    if (ts is String) trustedSources = ts;
    final fs = j['friendlySerials'];
    if (fs is String) friendlySerials = fs;
    final ridOn = j['remoteIdEnabled'];
    if (ridOn is bool) remoteIdEnabled = ridOn;
    final dEo = j['droneEoUrl'];
    if (dEo is String && dEo.isNotEmpty) droneEoUrl = dEo;
    final dIr = j['droneIrUrl'];
    if (dIr is String && dIr.isNotEmpty) droneIrUrl = dIr;
    final dCe = j['droneCloudEoUrl'];
    if (dCe is String) droneCloudEoUrl = dCe;
    final dCi = j['droneCloudIrUrl'];
    if (dCi is String) droneCloudIrUrl = dCi;
    final dSrc = j['droneStreamSource'];
    if (dSrc is String && (dSrc == 'local' || dSrc == 'cloud')) {
      droneStreamSource = dSrc;
    }
    final cotPrefix = j['cotEmitterPrefix'];
    if (cotPrefix is String && cotPrefix.isNotEmpty) {
      cotEmitterPrefix = cotPrefix;
    }
    final cotRadius = j['cotCoincidenceRadiusM'];
    if (cotRadius is num) {
      cotCoincidenceRadiusM = cotRadius.clamp(5.0, 500.0).toDouble();
    }
    final pt = j['phoneTierEnabled'];
    if (pt is bool) phoneTierEnabled = pt;
    final ds = j['deviceSignaturesEnabled'];
    if (ds is bool) deviceSignaturesEnabled = ds;
    final tsid = j['tileSourceId'];
    if (tsid is String && tsid.isNotEmpty) tileSourceId = tsid;
    double? lat(String k) {
      final v = j[k];
      if (v is num) {
        final d = v.toDouble();
        if (d.isFinite) return d;
      }
      return null;
    }

    final slat = lat('sdrStationLat');
    final slon = lat('sdrStationLon');
    final elat = lat('sdrEnbLat');
    final elon = lat('sdrEnbLon');
    // Per-pair all-or-nothing: a partial pair is unconfigured, not a
    // half-applied one. The pairs are independent because AUTO station
    // mode legitimately persists an eNB with no manual station (the
    // station then comes from the phone GPS fix at apply time).
    // Range-checked like the settings UI.
    bool latOk(double? v) => v != null && v >= -90 && v <= 90;
    bool lonOk(double? v) => v != null && v >= -180 && v <= 180;
    if (latOk(slat) && lonOk(slon)) {
      sdrStationLat = slat;
      sdrStationLon = slon;
    }
    if (latOk(elat) && lonOk(elon)) {
      sdrEnbLat = elat;
      sdrEnbLon = elon;
      final mhz = lat('sdrEnbCenterMhz');
      sdrEnbCenterMhz = (mhz != null && mhz > 0) ? mhz : null;
    }
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

/// Calibration state machine (adaptive_baseline_spec.md): the
/// deploy-time guided "Dial it in" routine plus the always-on ARTI
/// updater. idle → calibrating → stable; degraded when the routine ran
/// without a proper vacant window, or when ARTI suspect links pile up.
enum CalibrationState {
  /// No calibration performed this session.
  idle,

  /// Guided routine collecting a vacant window.
  calibrating,

  /// Guided routine finished on a proper vacant window.
  stable,

  /// Degraded-mode routine, or suspect links eroding trust.
  degraded,
}

class AppState extends ChangeNotifier {
  AppState() {
    _tripwire.attachAdaptiveBaseline(_adaptive);
    _loadLayout();
    _loadGpsOrigin();
    _loadZmetaSettings();
    _initCameraDriver();
    _wireSkydio();
    _radiosReady = _loadRadios();
    // v0.26.0: user signatures load in the background; missing
    // file = built-in catalog only, never a boot failure.
    unawaited(loadUserSignatures());
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

  /// HTTPS ingest emitter (no-WireGuard path). Created lazily like the
  /// UDP one. The token comes from secure storage via the provider;
  /// the emitter caches it briefly (30 s) and drops the cache on any
  /// 401/403 and on every settings save, so a revoked-then-rejoined
  /// token takes effect without an app restart.
  ZMetaHttpsEmitter? _zmetaHttps;

  ZMetaHttpsEmitter _zmetaHttpsEmitter() {
    final cur = _zmetaHttps;
    if (cur != null &&
        cur.ingestUrl == settings.zmetaIngestUrl &&
        cur.fpMode == settings.zmetaIngestFp) {
      return cur;
    }
    cur?.close();
    final next = ZMetaHttpsEmitter(
      ingestUrl: settings.zmetaIngestUrl,
      fpMode: settings.zmetaIngestFp,
      tokenProvider: () {
        final platform = settings.zmetaPlatformId.trim().isEmpty
            ? 'shepherd-mesh-1'
            : settings.zmetaPlatformId.trim();
        return ZmetaIngestStore.readToken(platform);
      },
    );
    _zmetaHttps = next;
    return next;
  }

  /// S3: true once the hub has rejected the ingest token 5 times running.
  /// The settings screen turns this into a re-join prompt.
  bool get zmetaIngestTokenRejected => _zmetaHttps?.tokenRejected ?? false;

  /// S4: the operator changed the platform ID after joining (the stored
  /// token / hub peer is bound to the OLD id). Emission must stop until
  /// they re-join under the new id.
  bool get zmetaPlatformMismatch {
    final t = settings.zmetaTransport;
    if (t != 'https' && t != 'wireguard') return false;
    final joined = settings.zmetaJoinedPlatformId.trim();
    if (joined.isEmpty) return false;
    return joined != settings.zmetaPlatformId.trim();
  }

  /// Fail-closed emit gate, transport-aware. UDP keeps the existing
  /// rule (loopback always OK; a remote host needs the operator's
  /// secured-link attestation). HTTPS is gated on a usable ingest URL —
  /// TLS plus the bearer token IS the secured link there. A platform ID
  /// changed after joining (S4) stops all joined transports cold.
  bool _zmetaEmitAllowed() {
    if (zmetaPlatformMismatch) return false;
    if (settings.zmetaTransport == 'https') {
      return zmetaIsUsableIngestUrl(settings.zmetaIngestUrl);
    }
    return zmetaIsLocalHost(settings.zmetaHost) || settings.zmetaSecured;
  }

  /// Send closure for the active transport. Both emitters share the
  /// `send(Map)` shape and swallow their own failures, so call sites
  /// don't care which transport is active.
  ZmetaSend _zmetaSendFn() {
    if (settings.zmetaTransport == 'https' &&
        settings.zmetaIngestUrl.isNotEmpty) {
      return _zmetaHttpsEmitter().send;
    }
    return _zmetaEmitter().send;
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
      // AUTO station rides the phone fix: a fresh fix (re)arms the
      // Doppler geometry, and the 25 m gate inside decides whether
      // the device has moved enough to matter. allowKick:false —
      // this IS the refresh, it must not kick another one.
      if (settings.sdrAutoStation) _applySdrStation(allowKick: false);
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

  // ---- CoT output + emitter ingest wiring ----

  /// CoT track publisher (emit-only, defensive-only). Always exists
  /// after configure; publishTrack drops tracks itself when disabled,
  /// when the GPS origin is null (no projection), or below the floor.
  CotPublisher? _cotPublisher;

  /// CoT emitter ingest listener (RX-only). Null unless listening is
  /// enabled.
  CotListener? _cotListener;

  /// Device auto-connect coordinator (Silvus USB today; more families
  /// as their drivers land). Null when disabled or simulated.
  DeviceAutoConnect? _autoConnect;

  /// Stable CoT track identity: the deterministic tracker follows a
  /// single mover, so one uid per mesh (SHEPHERD-mover-1 via the
  /// callsign contract in cot_publisher.dart).
  static const String _cotTrackId = 'mover-1';

  CotPublisherConfig _cotPublisherConfig() => CotPublisherConfig(
        enabled: settings.cotEmitEnabled,
        useMulticast: settings.cotEmitUseMulticast,
        multicastGroup: settings.cotMulticastGroup,
        multicastPort: settings.cotMulticastPort,
        takHost: settings.cotTakHost,
        takPort: settings.cotTakPort,
        callsignPrefix: settings.cotCallsignPrefix,
        staleSeconds: settings.cotStaleSeconds,
        publishFloor: settings.cotPublishFloor,
        airTypeThreshold: settings.cotAirTypeThreshold,
      );

  static bool _samePublisherConfig(CotPublisherConfig a, CotPublisherConfig b) =>
      a.enabled == b.enabled &&
      a.useMulticast == b.useMulticast &&
      a.multicastGroup == b.multicastGroup &&
      a.multicastPort == b.multicastPort &&
      a.takHost == b.takHost &&
      a.takPort == b.takPort &&
      a.callsignPrefix == b.callsignPrefix &&
      a.staleSeconds == b.staleSeconds &&
      a.publishFloor == b.publishFloor &&
      a.airTypeThreshold == b.airTypeThreshold;

  /// Configure-generation counter: the CoT setters (and applySettings)
  /// fire-and-forget [_configureCot], so a rapid ON→OFF toggle can
  /// interleave two configures across the socket awaits and strand a
  /// live socket on a detached listener. Each call takes a generation
  /// number; a stale generation bails before touching state and tears
  /// down any socket it started mid-await.
  int _cotConfigureGen = 0;

  /// (Re)build the publisher and listener from settings. Called from
  /// applySettings, from the CoT setters, and after the persisted
  /// settings load on cold start. The publisher's projection is
  /// refreshed per track publish (the GPS origin can arrive or change
  /// after configure time); the listener socket starts/stops here.
  Future<void> _configureCot() async {
    final gen = ++_cotConfigureGen;
    // Rebuild the publisher only when ITS config changed: unrelated
    // edits (listener radius, prefix, ...) used to dispose it, which
    // reset the 1 Hz throttle and dropped the TAK connection.
    final pubCfg = _cotPublisherConfig();
    final oldPub = _cotPublisher;
    if (oldPub == null || !_samePublisherConfig(oldPub.config, pubCfg)) {
      oldPub?.dispose();
      _cotPublisher = CotPublisher(config: pubCfg);
    }
    // Eager TAK connect: the link state should be known at configure
    // time (cold start, toggle-on), not only on first track publish.
    // Fire-and-forget — a dead server must never break settings apply;
    // the backoff inside connectNow paces the retries.
    if (settings.cotEmitEnabled) {
      unawaited(_cotPublisher?.connectNow());
    }
    final listener = _cotListener;
    if (settings.cotListenEnabled) {
      final configChanged = listener == null ||
          listener.config.emitterPrefix != settings.cotEmitterPrefix ||
          listener.config.coincidenceRadiusM !=
              settings.cotCoincidenceRadiusM ||
          listener.config.multicastGroup !=
              settings.cotListenMulticastGroup ||
          listener.config.multicastPort != settings.cotListenMulticastPort ||
          listener.config.windowSeconds != settings.cotListenWindowSeconds ||
          listener.config.allowedSources.join(',') !=
              CotListenerConfig.parseSources(settings.trustedSources)
                  .join(',');
      if (configChanged) {
        await _cotListener?.stop();
        // A newer configure may have superseded us across the stop
        // await — never install a listener on a stale generation.
        if (gen != _cotConfigureGen) return;
        _cotListener = CotListener(
          config: CotListenerConfig(
            enabled: true,
            multicastGroup: settings.cotListenMulticastGroup,
            multicastPort: settings.cotListenMulticastPort,
            windowSeconds: settings.cotListenWindowSeconds,
            emitterPrefix: settings.cotEmitterPrefix,
            coincidenceRadiusM: settings.cotCoincidenceRadiusM,
            allowedSources:
                CotListenerConfig.parseSources(settings.trustedSources),
          ),
          // Skydio P1: friendly-platform ingest rides the SAME
          // socket. The matcher reads the live friendly registry, so
          // registry edits apply without a listener rebuild.
          platformMatcher: (callsign, uid, type) =>
              airframes.registry.match(
                  callsign: callsign.isEmpty ? null : callsign,
                  uid: uid.isEmpty ? null : uid) !=
              null,
        );
      }
      if (gen != _cotConfigureGen) return;
      final l = _cotListener!;
      if (!l.isListening) {
        // (Re)try the bind when the listener has no live socket: a
        // previous bind failure (see CotListener.lastError) must not
        // leave a permanently dead listener behind.
        try {
          // A failed bind must not break settings apply — the socket
          // is best-effort; detection authority is untouched.
          await l.start();
        } catch (_) {}
        if (gen != _cotConfigureGen && !identical(l, _cotListener)) {
          // Superseded while starting AND the newer generation
          // replaced this listener: tear down our orphan. If the
          // newer generation reuses [l], it owns it — stopping it here
          // would silently kill the live listener.
          await l.stop();
        }
      }
    } else if (listener != null) {
      await listener.stop();
      if (gen == _cotConfigureGen) _cotListener = null;
    }
  }

  /// Emit toggle: rebuild the publisher so the new config takes
  /// effect immediately.
  Future<void> setCotEmitEnabled(bool v) async {
    settings.cotEmitEnabled = v;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Listen toggle: start/stop the multicast ingest socket.
  Future<void> setCotListenEnabled(bool v) async {
    settings.cotListenEnabled = v;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  // ---- Skydio integration (P1–P3) --------------------------------

  /// One-time wiring: BLE advertisements tap into the Remote ID
  /// receiver, and fresh RID data refreshes the UI. Called from the
  /// constructor; assignments are idempotent.
  void _wireSkydio() {
    wifi.ble.advertisementHook = remoteId.onBleAdvertisement;
    remoteId.onUpdate = () {
      _foldAirframeEvidence();
      notifyListeners();
    };
  }

  /// Push the persisted Skydio settings into the live services:
  /// parse the friendly registry (records re-match immediately) and
  /// arm/disarm the Remote ID receiver. Called at boot (after the
  /// persisted settings land) and on every settings save.
  void _applySkydioSettings() {
    airframes.registry = FriendlyRegistry.parse(settings.friendlySerials);
    airframes.rematchAll();
    // The Wi-Fi poll rides the shepherd/wifi_sense channel, which
    // only exists on Android; elsewhere the poll is a caught no-op
    // (MissingPluginException) and BLE remains the receive path.
    remoteId.setEnabled(settings.remoteIdEnabled, wifiCapable: true);
  }

  /// Remote ID toggle (Settings switch applies immediately, like the
  /// CoT listen toggle).
  Future<void> setRemoteIdEnabled(bool v) async {
    settings.remoteIdEnabled = v;
    await _saveSettings();
    _applySkydioSettings();
    notifyListeners();
  }

  /// Live airframe records, freshest first (Tracking overlay +
  /// Drone tab).
  List<AirframeRecord> get airframeRecords => airframes.records;

  /// Live friendly ground tracks (PRC-163 PLI via TAK/CoT),
  /// freshest first (Tracking overlay only — never the Drone tab).
  /// Display-only, like [airframeRecords].
  List<GroundTrackRecord> get groundTrackRecords => airframes.groundRecords;

  /// Projection origin for lat/lon overlays: the GPS origin when
  /// set; in simulated mode only, the sim feed's demo anchor when
  /// no origin is set (so sim ground tracks can render). Live mode
  /// never invents an origin.
  GpsOrigin? get displayOrigin =>
      gpsOrigin ??
      (settings.simulatedMode
          ? GpsOrigin(
              lat: SimGroundFeed.demoOriginLat,
              lon: SimGroundFeed.demoOriginLon)
          : null);

  /// Live Remote ID contacts, freshest first.
  List<RidContact> get ridContacts => remoteId.contacts;

  /// Route platform observations into the classifier BY DOMAIN:
  /// ground observations become ground tracks, never airframes
  /// (the PRC-163 rule — a dismount is not a drone).
  void _foldPlatformObservations(List<PlatformObservation> observations) {
    for (final p in observations) {
      if (p.isGround) {
        airframes.observeCotGround(CotGroundEvidence(
          uid: p.uid,
          callsign: p.callsign,
          cotType: p.type,
          lat: p.lat,
          lon: p.lon,
          time: p.time,
          courseDeg: p.courseDeg,
          speedMps: p.speedMps,
          batteryPct: p.batteryPct,
        ));
      } else {
        airframes.observeCotPlatform(CotPlatformEvidence(
          uid: p.uid,
          callsign: p.callsign,
          cotType: p.type,
          lat: p.lat,
          lon: p.lon,
          time: p.time,
          haeM: p.haeM,
          courseDeg: p.courseDeg,
          speedMps: p.speedMps,
          batteryPct: p.batteryPct,
        ));
      }
    }
  }

  /// Sim-only friendly-ground feed + its private listener
  /// (v0.23.0): sim dismount PLI runs through the real CoT parse
  /// path, so the demo is the production path with a fake radio.
  SimGroundFeed? _simGroundFeed;
  CotListener? _simGroundListener;
  DateTime? _lastSimGroundTick;

  /// Simulated-mode ground tracks: two dismounts carrying "163s"
  /// walking the sim field. Inert in live mode.
  void _foldSimGround() {
    if (!settings.simulatedMode) return;
    final origin = displayOrigin;
    if (origin == null) return;
    final feed = _simGroundFeed ??= SimGroundFeed();
    final listener = _simGroundListener ??= CotListener(
      config: const CotListenerConfig(enabled: true, windowSeconds: 60),
      // Ground events enter by their a-f-G type; the matcher stays
      // shut so nothing else can sneak into the sim collection.
      platformMatcher: (_, __, ___) => false,
    );
    final now = DateTime.now();
    final last = _lastSimGroundTick;
    _lastSimGroundTick = now;
    var dt = last == null ? 1.0 : now.difference(last).inMilliseconds / 1000.0;
    if (dt <= 0) dt = 1.0;
    // A backgrounded app must not teleport the patrol on resume.
    if (dt > 5) dt = 5;
    for (final xml in feed.tick(
        dt: dt, originLat: origin.lat, originLon: origin.lon, now: now)) {
      listener.handleDatagram(utf8.encode(xml), now.toUtc());
    }
    _foldPlatformObservations(listener.platformObservations);
  }

  /// Fold the latest platform/RID/mesh evidence into the airframe
  /// classifier. Runs on the 1 Hz watchdog and on RID updates.
  /// Display-only: nothing here touches detection state.
  void _foldAirframeEvidence() {
    final listener = _cotListener;
    if (listener != null) {
      _foldPlatformObservations(listener.platformObservations);
    }
    _foldSimGround();
    if (remoteId.enabled) {
      for (final c in remoteId.contacts) {
        final serial = c.serial;
        if (serial == null || serial.isEmpty) continue;
        airframes.observeRid(RidEvidence(
          serial: serial,
          time: c.lastSeen ?? DateTime.now(),
          lat: c.lat,
          lon: c.lon,
          altM: c.altGeoM,
          operatorLat: c.operatorLat,
          operatorLon: c.operatorLon,
          operatorLocationType: c.operatorLocationType,
          courseDeg: c.directionDeg,
          speedMps: c.speedHorizontalMps,
        ));
      }
    }
    // Class A evidence: a registry-matched mesh node carrying fresh
    // link samples. Motion = field-local position change since the
    // last fold (the trail updates only here, so a parked node
    // settles to not-moving instead of re-reporting its last jump).
    if (airframes.registry.isNotEmpty) {
      final health = nodeHealthMap;
      final origin = gpsOrigin;
      for (final n in effectiveNodes.values) {
        final cs = n.callsign;
        if (cs == null || cs.isEmpty) continue;
        if (airframes.registry.entryForCallsign(cs) == null) continue;
        final h = health[n.nodeId] ?? NodeHealthStatus.unknown;
        final hasLinks = h == NodeHealthStatus.ok ||
            h == NodeHealthStatus.degraded;
        final prev = _nodePosTrail[n.nodeId];
        var moved = false;
        if (prev != null) {
          final dx = n.x - prev.x;
          final dy = n.y - prev.y;
          moved = dx * dx + dy * dy > 15 * 15 ||
              (n.height - prev.h).abs() > 2;
        }
        _nodePosTrail[n.nodeId] = (x: n.x, y: n.y, h: n.height);
        double? lat = n.lat;
        double? lon = n.lon;
        if ((lat == null || lon == null) && origin != null) {
          final geo =
              GeoProjection(originLat: origin.lat, originLon: origin.lon)
                  .metersToLatLon(n.x, n.y);
          lat = geo.lat;
          lon = geo.lon;
        }
        airframes.observeMeshNode(
          nodeCallsign: cs,
          hasLinkMetrics: hasLinks && !settings.simulatedMode,
          moving3d: moved,
          time: DateTime.now(),
          lat: lat,
          lon: lon,
        );
      }
    }
    airframes.prune(DateTime.now());
  }

  /// Emit-destination selector: true = UDP multicast, false = TAK
  /// Server TCP.
  Future<void> setCotEmitUseMulticast(bool v) async {
    settings.cotEmitUseMulticast = v;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotTakHost(String v) async {
    settings.cotTakHost = v;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotTakPort(int v) async {
    settings.cotTakPort = v.clamp(1, 65535);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotStaleSeconds(int v) async {
    settings.cotStaleSeconds = v.clamp(5, 300);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotPublishFloor(double v) async {
    settings.cotPublishFloor = v.clamp(0.0, 1.0);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotEmitterPrefix(String v) async {
    if (v.isNotEmpty) settings.cotEmitterPrefix = v;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  Future<void> setCotCoincidenceRadiusM(double v) async {
    settings.cotCoincidenceRadiusM = v.clamp(5.0, 500.0);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Emit callsign/uid prefix (default 'SHEPHERD-'). Must be
  /// non-empty with no whitespace; invalid input keeps the current
  /// value.
  Future<void> setCotCallsignPrefix(String v) async {
    final t = v.trim();
    if (t.isNotEmpty && !RegExp(r'\s').hasMatch(t)) {
      settings.cotCallsignPrefix = t;
    }
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Air-type confidence threshold (0..1, default 0.5): a type guess
  /// naming an airframe class at or above this emits `a-u-A`.
  Future<void> setCotAirTypeThreshold(double v) async {
    settings.cotAirTypeThreshold = v.clamp(0.0, 1.0);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Listen-side multicast group (default 239.2.3.1).
  Future<void> setCotListenMulticastGroup(String v) async {
    final t = v.trim();
    if (t.isNotEmpty) settings.cotListenMulticastGroup = t;
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Listen-side multicast port (default 6969).
  Future<void> setCotListenMulticastPort(int v) async {
    settings.cotListenMulticastPort = v.clamp(1, 65535);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Ingest observation window in seconds (clamped 10..600).
  Future<void> setCotListenWindowSeconds(int v) async {
    settings.cotListenWindowSeconds = v.clamp(10, 600);
    await _saveSettings();
    await _configureCot();
    notifyListeners();
  }

  /// Push the fused track to CoT output. Fire-and-forget: the service
  /// drops tracks when disabled, unanchored (null projection), or
  /// below the publish floor, and never throws out of the transport
  /// path.
  void _publishCotTrack(TrackEstimate t) {
    final pub = _cotPublisher;
    if (pub == null) return;
    final origin = gpsOrigin;
    // Nullable projection: exists-but-unanchored means skip sending,
    // exactly what the service does on a null projection.
    pub.projection = origin == null
        ? null
        : GeoProjection(originLat: origin.lat, originLon: origin.lon);
    final conf = trackConfidence;
    unawaited(pub.publishTrack(CotTrackInput(
      trackId: _cotTrackId,
      xEast: t.x,
      yNorth: t.y,
      headingDeg: t.headingDeg ?? 0.0,
      speedMps: t.speedMps ?? 0.0,
      sizeLabel: t.sizeClass,
      // TrackEstimate carries no calibrated size confidence: 0.5 is a
      // DOCUMENTED fixed default — "heuristic estimate, not a
      // measurement" (the integration spec's fixed-defaults rule).
      sizeConfidence: 0.5,
      typeGuess: t.typeGuess,
      typeConfidence: t.typeConfidence,
      inboundOutbound: t.relation,
      confidence: conf?.displayed ?? 0.0,
      // TrackEstimate has no position-uncertainty field: 15.0 m is a
      // DOCUMENTED fixed default (single-mover tripwire fix, no
      // stated error) — feeds the CoT ce/le elements.
      positionUncertaintyM: 15.0,
    )));
  }

  /// Emitter-mover coincidences for the merger: upgrade-only,
  /// freshness-weighted, never subtractive (the service emits boost
  /// >= 0 only — no subtraction logic here by design).
  List<GatedCorroboration> _emitterCoincidences(
      DateTime now, TrackEstimate t) {
    final out = <GatedCorroboration>[];
    final listener = _cotListener;
    final origin = gpsOrigin;
    if (listener == null || origin == null) return out;
    final geo = GeoProjection(originLat: origin.lat, originLon: origin.lon)
        .metersToLatLon(t.x, t.y);
    for (final h in listener.checkCoincidence(
        [TrackPosition(id: _cotTrackId, lat: geo.lat, lon: geo.lon)],
        now)) {
      out.add(GatedCorroboration(
        sensorId: 'cot-emitter:${h.emitterCallsign}',
        boost: h.boost, // 0.10, upgrade-only
        gateWeight: h.freshness01,
        note: 'RF emitter ${h.emitterCallsign} coincident with track '
            '(${h.distanceM.toStringAsFixed(0)}m) — consistent with, '
            'not confirmed',
      ));
    }
    return out;
  }

  /// Evidence lines for fresh emitter observations, using the
  /// listener's own window (activeEmitters already prunes to it, so
  /// the filter below is belt-and-braces on the same window).
  /// Wording is the honesty contract: "coincident", never "confirmed",
  /// never identity.
  List<String> get emitterEvidenceLines {
    final listener = _cotListener;
    if (listener == null) return const [];
    final now = DateTime.now();
    final window = Duration(seconds: listener.config.windowSeconds);
    return [
      for (final e in listener.activeEmitters)
        if (now.difference(e.time) <= window)
          cotEmitterEvidenceLine(e.callsign),
    ];
  }

  /// Dashboard status line. Null when both paths are off — the
  /// dashboard renders nothing in that case.
  String? get cotStatusLine {
    final segs = <String>[];
    if (settings.cotEmitEnabled) {
      final dest = settings.cotEmitUseMulticast
          ? '${settings.cotMulticastGroup}:${settings.cotMulticastPort}'
          : '${settings.cotTakHost}:${settings.cotTakPort}';
      final n = _cotPublisher?.stats.tracksPublishing ?? 0;
      segs.add('CoT → $dest · $n publishing');
    }
    if (settings.cotListenEnabled) {
      final listener = _cotListener;
      // A failed bind must surface: the dashboard may not claim
      // "listening" while the socket never bound.
      final err = listener?.lastError;
      if (err != null) {
        segs.add('listening FAILED: $err');
      } else if (listener == null || !listener.isListening) {
        segs.add('listening (socket not started)');
      } else {
        // activeEmitterCount excludes future-dated observations —
        // they can never coincide, so they are not "tracked".
        final m = listener.activeEmitterCount;
        final warn = listener.warning;
        segs.add('listening ($m emitter${m == 1 ? '' : 's'} tracked'
            '${warn == null ? '' : ' · $warn'})');
      }
    }
    if (segs.isEmpty) return null;
    return segs.join(' · ');
  }

  /// One opt-in heartbeat: SYSTEM_EVENT / PLATFORM_STATUS. Same
  /// fail-closed gate as detections (non-local + unsecured = no emit),
  /// never during replay.
  Future<void> _emitZmetaHeartbeat() async {
    if (replaying) return;
    if (!_zmetaEmitAllowed()) return;
    try {
      await refreshPhoneFix();
      final platform = settings.zmetaPlatformId.trim().isEmpty
          ? 'shepherd-mesh-1'
          : settings.zmetaPlatformId.trim();
      final geo = _platformGeo();
      final send = _zmetaSendFn();
      await send(zmetaPlatformStatus(
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

  /// ARTI geometrically-gated online reference updater + guided
  /// calibration routine (adaptive_baseline_spec.md). Sits next to the
  /// tripwire, not inside it: detection stays deterministic; ARTI
  /// never suppresses an alert. Survives settings changes (anchors
  /// persist); the tripwire is re-attached on every rebuild.
  final AdaptiveBaseline _adaptive = AdaptiveBaseline();

  Tripwire _newTripwire() {
    final tw = Tripwire(config: settings.tripwireConfig);
    tw.attachAdaptiveBaseline(_adaptive);
    return tw;
  }

  /// Calibration state machine + guided routine state.
  CalibrationState calibrationState = CalibrationState.idle;
  CalibrationRecord? lastCalibration;
  String? calibrationNote;
  DateTime? _calibStartAt;
  int _calibQuietPolls = 0;
  DateTime? _lastArtiStatsAt;

  /// Bands with completed TX-power characterization
  /// (rti_imaging_weights_spec §3). 'mesh' is characterized by the
  /// guided routine; SDR bands join via [markBandCharacterized] after
  /// the lab attenuator procedure passes (per-band fade levels agree
  /// within 2 dB). Uncharacterized + deep-fade links are flagged in
  /// health so the imager never silently trusts an uncalibrated band.
  final Set<String> characterizedBands = {'mesh'};

  void markBandCharacterized(String band) {
    characterizedBands.add(band);
    notifyListeners();
  }

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
  /// demand from radio status, link freshness, baseline resets, ARTI
  /// divergence-suspect links, fade levels, and uncalibrated bands.
  HealthReport get health {
    final now = DateTime.now();
    final lastByLink = {
      for (final e in history.entries)
        if (e.value.isNotEmpty) e.key: e.value.last,
    };
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
      lastByLink: lastByLink,
      staleAfter: _staleAfter,
      rebaselines: _tripwire.rebaselinedAt,
      suspectLinks: _adaptive.suspectLinkKeys,
      fadeLevels: {
        for (final e in lastByLink.entries) e.key: e.value.fadeLevel,
      },
      uncalibratedBands: _uncalibratedDeepFadeLinks(lastByLink),
    );
  }

  /// Link keys that are BOTH deep-fade and on an uncharacterized band —
  /// the imager must never silently trust these (rti_imaging_weights).
  Set<String> _uncalibratedDeepFadeLinks(
      Map<String, LinkSample> lastByLink) {
    final out = <String>{};
    for (final e in lastByLink.entries) {
      final band = bandChannelOf(e.key);
      if (!characterizedBands.contains(band) && e.value.fadeLevel < -6.0) {
        out.add(e.key);
      }
    }
    return out;
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

  /// Gated confidence verdict for the current track (research finding
  /// #2): C_display = clamp(C_RF + Σ w_s·e_s, C_RF, C_max), never
  /// subtractive, saturating at +0.35, upgrades suspended while the
  /// track is inconsistent. Null when there is no track. Display only
  /// — the tripwire stays the detection authority.
  MergedConfidence? trackConfidence;

  /// Fix-to-fix consistency verdict for the current track (the honest
  /// NEES analogue for the covariance-free tracker). Null when there
  /// is no track.
  TrackConsistency? trackConsistency;

  /// Fix-to-fix consistency monitor (lane3 P8: RMSE alone can't catch
  /// an inconsistent tracker). Fed one fix per fused track update.
  final TrackConsistencyMonitor _consistencyMonitor =
      TrackConsistencyMonitor();

  /// Latest shadow (attenuation) grid for the tracking map.
  List<ShadowCell> shadow = [];

  /// Latest fused RTI disturbance image (rti_imaging_weights_spec):
  /// probability mass over the ground plane — "estimated disturbance
  /// location (ground projection)", never a located object.
  List<RtiCell> rtiImage = [];

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

  /// ELRS Gemini signature evidence lines for the evidence view.
  ///
  /// Combines bridge-local signatures (wideband dual-frequency
  /// coincidence) with app-level cross-radio correlation (GemX:
  /// 2.4 GHz + 900 MHz chirps coinciding in time). Wording is the
  /// honesty contract: "Possible ELRS Gemini signature", never an
  /// identification.
  List<String> get elrsEvidenceLines {
    final now = DateTime.now();
    const cutoff = Duration(seconds: 120);
    final lines = <String>[];
    final chirps = <ElrsChirp>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      for (final s in d.latestSignatures) {
        if (now.difference(s.t) <= cutoff && s.score >= 0.3) {
          lines.add(s.displayLabel);
        }
      }
      chirps.addAll(d.recentChirps);
    }
    for (final s in GeminiCorrelator.correlate(chirps, now)) {
      if (s.score >= 0.3) lines.add(s.displayLabel);
    }
    return lines;
  }

  /// Gated ELRS corroboration contributions for the confidence merger.
  ///
  /// The signature is EXISTENCE evidence, not position evidence: it
  /// says "a LoRa-FHSS emitter with the Gemini dual-emission pattern
  /// is active", while the track's position comes from the RF
  /// tripwire. No geometry is claimed (and none is needed -- the
  /// contribution carries no position).
  ///
  /// Not double-counting: SDR band ENERGY already feeds the tripwire
  /// via virtual links; this is the modulation PATTERN on top of the
  /// energy -- a distinct measurement (chirp shape + dual-band time
  /// correlation), so it is independent evidence, not the same
  /// reading counted twice.
  List<GatedCorroboration> _elrsCorroborations(DateTime now) {
    final out = <GatedCorroboration>[];
    final healthy = _sdrSourceHealthy(now);
    if (!healthy) return out;
    const horizon = Duration(seconds: 60);
    void add(ElrsSignature s, String sensorId) {
      final age = now.difference(s.t);
      if (age.isNegative || age > horizon || s.score < 0.3) return;
      final w = reliabilityGate(
        alignmentQuality: s.score,
        age: age,
        stalenessHorizon: horizon,
        sourceHealthy: true,
      );
      if (w <= 0) return;
      out.add(GatedCorroboration(
        sensorId: sensorId,
        // Protocol-pattern evidence: comparable to a camera-motion
        // corroboration (0.15), scaled by the signature score through
        // the reliability gate. Never subtractive (merger enforces).
        boost: 0.15,
        gateWeight: w,
        note: s.displayLabel,
      ));
    }
    final chirps = <ElrsChirp>[];
    // Modes already contributed by a bridge-local signature: the app
    // correlator must not double-count the same emission (reviewer B).
    // Bridge-local modes are gemini-2g4/gemini-900m; app modes are
    // gemx/gemini-2g4, so only gemini-2g4 can collide.
    final bridgeModes = <String>{};
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      for (final s in d.latestSignatures) {
        bridgeModes.add(s.mode);
        add(s, 'elrs:${s.radio}:${s.mode}');
      }
      chirps.addAll(d.recentChirps);
    }
    for (final s in GeminiCorrelator.correlate(chirps, now)) {
      if (bridgeModes.contains(s.mode)) continue;
      add(s, 'elrs:app:${s.mode}');
    }
    return out;
  }

  /// Source health for the ELRS path: an SDR driver must be enabled
  /// and have polled recently -- otherwise the "no signature" silence
  /// is unmeasurable and the gate must read it as no information.
  bool _sdrSourceHealthy(DateTime now) {
    for (final p in _pollers) {
      if (p.driver is SdrDriver && p.config.enabled) {
        final lp = p.status.lastPoll;
        return lp != null &&
            now.difference(lp) < const Duration(seconds: 30);
      }
    }
    return false;
  }

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

  /// Friendly-airframe classification (Skydio P1): folds CoT
  /// platform observations, Remote ID contacts and mesh-node
  /// evidence into capability-class records. Display and
  /// correlation-priority only — records never feed detection, the
  /// tracker, or the confidence merger, and a registry match never
  /// suppresses anything.
  final AirframeClassifier airframes = AirframeClassifier();

  /// Remote ID receiver (Skydio P2). Receive-only; rides the BLE
  /// scan via its advertisement hook plus the Android Wi-Fi survey.
  final RemoteIdService remoteId = RemoteIdService();

  // ---- v0.26.0 Fieldwatch-borrow integration (additive, opt-in) --
  // Nothing here touches detection, the tracker, the merger, the
  // gateway, CoT, or ZMeta: these are identification / proximity /
  // display layers only, and every one degrades to off when its
  // input is missing.

  /// Merged device-signature catalog: built-in entries plus any
  /// user-added entries from device_signatures.json. Starts
  /// built-in only; [loadUserSignatures] refreshes it from disk.
  /// Matches are HYPOTHESES, never identity (see
  /// device_signatures.dart). The catalog loads regardless of the
  /// [AppSettings.deviceSignaturesEnabled] switch; screens gate
  /// DISPLAY on that switch.
  DeviceSignatureCatalog deviceSignatures =
      const DeviceSignatureCatalog();

  /// User-signature load problems, surfaced in Settings (never
  /// silent, never a crash). Empty means the user file was absent,
  /// empty, or fully valid.
  List<String> get deviceSignatureWarnings =>
      deviceSignatures.userLoadWarnings;

  /// Loads user-added signatures from `device_signatures.json` in
  /// the app documents directory and merges them over the built-in
  /// catalog via [DeviceSignatureCatalog.fromUserJsonText]. A
  /// missing file means built-in only (no warning — absence is the
  /// normal state). A malformed file degrades to built-in only
  /// with a surfaced warning. Never throws.
  Future<void> loadUserSignatures() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/device_signatures.json');
      if (!await file.exists()) {
        if (deviceSignatures.userSignatures.isNotEmpty ||
            deviceSignatures.userLoadWarnings.isNotEmpty) {
          deviceSignatures = const DeviceSignatureCatalog();
          if (!_disposed) notifyListeners();
        }
        return;
      }
      final text = await file.readAsString();
      deviceSignatures =
          DeviceSignatureCatalog.fromUserJsonText(text);
    } catch (e) {
      // Unreadable file degrades to built-in only with a reason,
      // never to a crash and never to silently dropped entries.
      deviceSignatures = DeviceSignatureCatalog(userLoadWarnings: [
        'User signatures ignored: could not read '
            'device_signatures.json ($e) — built-in catalog only.',
      ]);
    }
    if (!_disposed) notifyListeners();
  }

  /// Phone-only tier, evaluated LIVE from actual driver state —
  /// not from a stored flag. The tier is active only when the
  /// [AppSettings.phoneTierEnabled] switch is on AND no mesh/SDR
  /// hardware is attached:
  /// - mesh: a Silvus/MPU5/L3Harris/Meshtastic/sim poller, or
  ///   simulated mode itself (the sim mesh is the active picture,
  ///   so the phone banner never flickers over it before Start);
  /// - SDR: an SDR-bridge or KrakenDF poller ([hasSdrDriver] plus
  ///   the Kraken driver id);
  /// - serial-class: an ESP32-node poller.
  /// start()/stop() already notifyListeners, so this recomputes on
  /// every attachment change. Sensor-bus and camera pollers are
  /// corroboration feeds, not mesh/SDR coverage, so they neither
  /// activate nor deactivate the tier: the tier's claim is only
  /// ever "no mesh/SDR hardware attached", and its banner lists
  /// phone sources only. When the switch is off, the tier
  /// evaluates as inactive by construction (a synthetic
  /// attached-mesh state).
  PhoneTier get phoneTier {
    if (!settings.phoneTierEnabled) {
      return PhoneTier.evaluate(
        hardware: const HardwareAttachment(meshDriverAttached: true),
      );
    }
    const meshIds = {'silvus', 'mpu5', 'harris', 'meshtastic', 'sim'};
    final pollerIds = {
      for (final p in _pollers) p.config.driverId,
    };
    // v0.26.0 fix-pass: (1) a mesh driver CONFIGURED in the saved
    // radio list deactivates the tier even when it is not polling
    // — a mesh user who has not pressed START (or pressed STOP)
    // must not see a false PHONE-ONLY banner; (2) until the saved
    // list has finished loading, no attachment determination has
    // been made at all, so the tier stays inactive rather than
    // guessing phone-only. Simulated mode still counts as
    // mesh-attached. (3) Source availability is passed for real:
    // Remote ID and the signature library are available only when
    // their switches are actually on, so the banner can never
    // claim all five sources while one is switched off.
    final configuredMesh = !_radiosLoaded ||
        radioConfigs.any((c) => meshIds.contains(c.driverId));
    return PhoneTier.evaluate(
      hardware: HardwareAttachment(
        meshDriverAttached:
            settings.simulatedMode ||
                pollerIds.any(meshIds.contains),
        sdrAttached:
            hasSdrDriver || pollerIds.contains('kraken'),
        serialDriverAttached: pollerIds.contains('esp32'),
        meshDriverConfigured: configuredMesh,
      ),
      sourceAvailable: {
        PhoneScanSource.remoteId: remoteId.enabled,
        PhoneScanSource.signatureLibrary:
            settings.deviceSignaturesEnabled,
      },
    );
  }

  /// Last motion-sensor error from the current Hunt session's step
  /// source, if any — surfaced on the Hunt screen (v0.26.0
  /// fix-pass; previously written and read by nothing). Null when
  /// no session is running or the sensor has not errored.
  String? get huntSensorError {
    final source = _huntStepSource;
    return source is SensorsPlusStepSource ? source.lastError : null;
  }

  /// Shared bounded (50 MB LRU) tile cache for the offline-maps
  /// pattern. Cache-first; missing tiles degrade to the honestly
  /// labeled blank grid, never an invented map.
  final TileCache tileCache = TileCache();

  /// All built-in keyless tile sources (OSM + USGS only).
  List<TileSource> get tileSources => defaultTileSources;

  /// Selected tile source for the current [AppSettings.tileSourceId];
  /// unknown ids fall back to OpenStreetMap Standard.
  TileSource get selectedTileSource =>
      selectTileSource(settings.tileSourceId);

  /// Current Hunt session, if one is running. Created by
  /// [startHuntSession], ended by [endHuntSession]. The session
  /// itself is proximity-only: its loudest cell is never a
  /// position fix.
  HuntTracker? huntSession;

  /// Step source owned by the current Hunt session (kept beside
  /// the tracker because [HuntTracker.dispose] only cancels its
  /// step subscription — the sensor subscription itself is closed
  /// here in [endHuntSession]).
  StepSource? _huntStepSource;

  /// Starts a Hunt session (disposing any previous one first) and
  /// starts its motion-sensor step source. Callbacks are the
  /// screen's to wire: onBeep → system click + flash, onVibrate →
  /// haptics. There is no audio plugin in this build, so the beep
  /// is a system click, not a dedicated tone — documented in the
  /// Hunt screen header.
  HuntTracker startHuntSession({
    void Function(HuntFeedback feedback)? onBeep,
    void Function(HuntFeedback feedback)? onVibrate,
    void Function(HuntFeedback feedback)? onFeedback,
  }) {
    final previous = huntSession;
    huntSession = null;
    unawaited(previous?.dispose());
    unawaited(_huntStepSource?.dispose());
    final stepSource = SensorsPlusStepSource();
    _huntStepSource = stepSource;
    stepSource.start();
    final session = HuntTracker(
      stepSource: stepSource,
      onBeep: onBeep,
      onVibrate: onVibrate,
      onFeedback: onFeedback,
    );
    huntSession = session;
    notifyListeners();
    return session;
  }

  /// Ends the current Hunt session and closes its step source.
  /// Safe to call with no session running.
  Future<void> endHuntSession() async {
    final session = huntSession;
    huntSession = null;
    final stepSource = _huntStepSource;
    _huntStepSource = null;
    await session?.dispose();
    await stepSource?.dispose();
    if (!_disposed) notifyListeners();
  }

  /// Last field-local position per mesh node id — Class A motion
  /// evidence (a registry-matched node whose position moves in 3D).
  final Map<String, ({double x, double y, double h})> _nodePosTrail = {};
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
    if (!_zmetaEmitAllowed()) return;
    try {
      final send = _zmetaSendFn();
      final platform = settings.zmetaPlatformId.trim().isEmpty
          ? 'shepherd-mesh-1'
          : settings.zmetaPlatformId.trim();
      for (final o in obs) {
        final evt = zmetaSensorObservation(platformId: platform, obs: o);
        if (evt == null) continue; // no honest modality — stays local
        await send(evt);
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
    unawaited(_saveSettings());
    NodeUdpHub.setAllowedSourcesFromText(s.trustedSources);
    // A settings save is also how a completed (re-)join lands: drop
    // the ingest emitter's cached token so the freshly stored token
    // takes effect on the next send, not after the cache TTL.
    _zmetaHttps?.invalidateToken();
    _applySkydioSettings();
    _configureZmetaTimers();
    unawaited(_configureCot());
    // Via _newTripwire() so the ARTI layer is re-attached (a bare
    // Tripwire() silently lost it until the next full start).
    _tripwire = _newTripwire();
    _tracker.reset();
    _clearTrackState();
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
    // Re-arm the Doppler geometry against the new settings right away
    // (start() also does this when polling resumes). In AUTO station
    // mode this is what kicks the first GPS fix.
    applySdrStationFromSettings();
    // v0.26.0: a settings save refreshes the user-signature catalog
    // so warnings in Settings stay current after the operator edits
    // device_signatures.json (or toggles the library on).
    unawaited(loadUserSignatures());
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
    _clearTrackState();
    history.clear();
    _tripwire = _newTripwire();
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
    // Re-arm the persisted Doppler geometry on the fresh drivers.
    applySdrStationFromSettings();
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
    // Device auto-connect: plugged-in radios validate themselves in.
    // Idempotent — stop() tore the old coordinator down on re-entry.
    _startAutoConnect();
  }

  DateTime? _cotListenRetryAt;

  /// A listener whose bind failed or whose socket died is retried
  /// every 15 s instead of staying dead until the next settings edit.
  /// Routed through _configureCot (not l.start() directly) so the retry
  /// always operates on the current listener under the generation guards —
  /// a bare l.start() could resurrect a discarded listener and leak an
  /// orphan multicast socket.
  void _retryCotListener() {
    final l = _cotListener;
    if (!settings.cotListenEnabled || l == null) return;
    if (l.isListening || l.lastError == null) return;
    final now = DateTime.now();
    final last = _cotListenRetryAt;
    if (last != null && now.difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _cotListenRetryAt = now;
    unawaited(_configureCot());
  }

  void _watchdogTick() {
    _retryCotListener();
    _foldAirframeEvidence();
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

  /// Test seam: attach a driver directly (bypasses radio persistence
  /// and polling) so monitor-section getters can be tested.
  @visibleForTesting
  void attachDriverForTest(RadioDriver driver) {
    _addPoller(
      RadioConfig(
        driverId: driver.driverId,
        address: 'test',
        label: 'TEST',
        pollInterval: 1.0,
      ),
      driver,
    );
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
    _tripwire = _newTripwire();
    _tracker.reset();
    _clearTrackState();
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
    _autoConnect?.stop();
    _autoConnect = null;
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
      // ARTI online updater (adaptive_baseline_spec.md): runs on every
      // poll, silently. Detection already happened above — ARTI only
      // adapts the reference layer beneath it and never suppresses an
      // alert. Uses the previous fused track (1-cycle lag); the gates
      // are statistical, not control-critical.
      _updateAdaptiveBaseline(enrichedAll);
      if (calibrationState == CalibrationState.calibrating) {
        _accumulateCalibration(enrichedAll);
      }
      _maybeRecordArtiStats();
      final fresh = _tripwire.drainEvents();
      final classified = [
        for (final e in fresh) _classifyEvent(e, p.config.pollInterval),
      ];
      // No audible alert for replayed detections: the operator is
      // rehearsing, not watching a live mesh.
      if (classified.isNotEmpty && !replaying) unawaited(_alert(AlertKind.detection));
      events.insertAll(0, classified);
      // Episodes that ended this poll: the confirm-time event only saw
      // the first couple of polls, so write back the true duration and
      // peak and classify again on the real episode (the model was
      // trained on full-length episodes).
      for (final s in _tripwire.drainClosedEpisodes()) {
        _finalizeEpisode(s, p.config.pollInterval);
      }
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
    // Fused RTI disturbance image (rti_imaging_weights_spec): two
    // direction images with area-normalized weights, fused after
    // weighting. Probability mass over the ground plane — an
    // estimated disturbance location, never a located object.
    rtiImage = _tracker.rtiImage(
      samples: geo,
      nodes: effectiveNodes,
      dipThreshold: settings.dipThreshold,
      bandOf: bandChannelOf,
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
    // Gated confidence + consistency (research finding #2): feed the
    // fix-to-fix monitor one fix per update, then merge corroborating
    // sensors into the DISPLAYED confidence only. Detection authority
    // is untouched — the tripwire above already decided what exists.
    final t = track;
    if (t != null) {
      _consistencyMonitor.observe(t.timestamp, t.x, t.y);
      trackConsistency = _consistencyMonitor.snapshot;
      trackConfidence = _mergeTrackConfidence(now, t);
      // CoT output: the track is finalized here; the service drops it
      // when emit is off, unanchored, or below the publish floor.
      _publishCotTrack(t);
    } else {
      _consistencyMonitor.noteGap(now);
      trackConsistency = null;
      trackConfidence = null;
    }
  }

  /// Merge recent sensor observations into the track's displayed
  /// confidence via the gated merger (confidence_merger.dart).
  ///
  /// Only observations that (a) are fresher than every staleness
  /// horizon, (b) come from a healthy source, and (c) geometrically
  /// corroborate the track can contribute — and then only while the
  /// track is internally consistent. Silence is "no opinion": missing
  /// sensors, unknown sensor positions, and geometry misses add
  /// nothing and subtract nothing.
  MergedConfidence _mergeTrackConfidence(DateTime now, TrackEstimate t) {
    final gated = <GatedCorroboration>[];
    final origin = gpsOrigin;
    if (origin != null) {
      for (final o in sensorObservations) {
        final age = now.difference(o.timestamp);
        if (age.isNegative) continue; // clock skew: not evidence
        final horizon = stalenessHorizonFor(o.type);
        if (age > horizon) continue; // stale: the AV-FDTI zero-weight case
        final slat = o.sensorLat;
        final slon = o.sensorLon;
        if (slat == null || slon == null) continue; // no geometry, no vote
        final m = latLonToMeters(slat, slon, origin.lat, origin.lon);
        final c = o.corroborationFor(t, sensorX: m.x, sensorY: m.y);
        if (c.boost <= 0) continue; // silence: never a penalty
        final w = reliabilityGate(
          alignmentQuality: c.quality,
          age: age,
          stalenessHorizon: horizon,
          sourceHealthy: _sensorSourceHealthy(o, now),
        );
        if (w <= 0) continue;
        gated.add(GatedCorroboration(
          sensorId: o.sensorId,
          boost: c.boost,
          gateWeight: w,
          note: c.note,
        ));
      }
    }
    // ELRS Gemini signature: protocol-pattern existence evidence from
    // the SDR bridge (no geometry claimed -- see _elrsCorroborations).
    gated.addAll(_elrsCorroborations(now));
    // CSI motion: upgrade-only corroboration, gated by the per-link
    // health gates (wind / path-loss / imbalance).
    gated.addAll(_csiCorroborations(now, t));
    // Passive Doppler: velocity-consistency evidence; disagreement
    // contributes exactly 0 and never touches C_RF.
    gated.addAll(_dopplerCorroborations(now, t));
    // CoT emitter coincidences: upgrade-only, freshness-weighted,
    // never subtractive (predator_integration_spec.md).
    gated.addAll(_emitterCoincidences(now, t));
    // WPP-IDP: upgrade-only existence evidence; moving-node events
    // contribute exactly 0 (ego-motion gate).
    gated.addAll(_wppIdpCorroborations(now));
    return mergeTrackConfidence(
      baseConfidence: rfCoreConfidence(linksUsed: t.linksUsed),
      contributions: gated,
      trackConsistent: _consistencyMonitor.consistent,
    );
  }

  /// CSI corroborations for the merger (esp32_csi_pipeline_spec.md).
  ///
  /// e_csi from the dev_hz band table (weak 0.05 / moderate 0.10 /
  /// strong 0.15); w_csi = freshness · health · quality. Any gate
  /// failure (wind-gated, link-budget-gated, stale, no wind source)
  /// forces the weight to exactly 0 — the AV-FDTI zero-weight case.
  /// While the track is INCONSISTENT all upgrades suspend (merger).
  List<GatedCorroboration> _csiCorroborations(
      DateTime now, TrackEstimate t) {
    final out = <GatedCorroboration>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! GenericSensorDriver) continue;
      for (final o in d.liveCsiObservations(now)) {
        final h = d.csiHealthFor(o.sensorId, now);
        if (!h.enabled) continue; // gated ⇒ weight exactly 0
        final e = csiBoostFor(o.devHz);
        if (e <= 0) continue; // below the noise floor: no claim
        final q = _csiGeometryQuality(o, t);
        final w = reliabilityGate(
          alignmentQuality: q,
          age: now.difference(o.timestamp),
          stalenessHorizon: CsiObservation.stalenessHorizon,
          sourceHealthy: true,
        );
        if (w <= 0) continue;
        out.add(GatedCorroboration(
          sensorId: 'csi:${o.sensorId}',
          boost: e,
          gateWeight: w,
          note: 'CSI ${o.devHz.toStringAsFixed(1)} Hz consistent with '
              'track (link association)',
        ));
      }
    }
    return out;
  }

  /// Geometry-alignment quality for a CSI observation: the motion is
  /// attributed to the sniffed AP link, so quality is the proximity of
  /// the track to the sniffing node (the only endpoint we know).
  /// Heuristic 0..1, documented as such — misalignment ⇒ ~0 weight.
  double _csiGeometryQuality(CsiObservation o, TrackEstimate t) {
    final lat = o.sensorLat;
    final lon = o.sensorLon;
    final origin = gpsOrigin;
    if (lat == null || lon == null || origin == null) return 0.0;
    final m = latLonToMeters(lat, lon, origin.lat, origin.lon);
    final dx = t.x - m.x;
    final dy = t.y - m.y;
    final dist = math.sqrt(dx * dx + dy * dy);
    return (1 - dist / 60.0).clamp(0.0, 1.0);
  }

  /// Doppler corroborations for the merger
  /// (doppler_refinement_spec.md): velocity-consistency evidence,
  /// boost 0.10. w_dop = freshness · health · quality; ref-unlocked ⇒
  /// 0; disagreement or sub-bar ⇒ exactly 0 (never subtractive).
  List<GatedCorroboration> _dopplerCorroborations(
      DateTime now, TrackEstimate t) {
    final out = <GatedCorroboration>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      final sx = d.stationX, sy = d.stationY, ex = d.enbX, ey = d.enbY;
      if (sx == null || sy == null || ex == null || ey == null) {
        continue; // unconfigured stations: the correlator abstains
      }
      final v = DopplerCorrelator.correlate(
        track: t,
        refs: d.recentDopplerRefs,
        now: now,
        radioX: sx,
        radioY: sy,
        enbX: ex,
        enbY: ey,
      );
      if (!v.qualified) continue; // disagreement ⇒ exactly 0
      final newest = v.newestAgreementAt;
      final age = newest == null
          ? DopplerCorrelator.agreementWindow
          : now.difference(newest);
      final w = reliabilityGate(
        alignmentQuality: v.score,
        age: age,
        stalenessHorizon: kDopplerStalenessHorizon,
        sourceHealthy: _sdrSourceHealthy(now),
      );
      if (w <= 0) continue;
      out.add(GatedCorroboration(
        sensorId: 'doppler:${d.host}:${d.port}',
        boost: kDopplerBoost,
        gateWeight: w,
        note: 'Doppler radial velocity consistent with track '
            '(${v.agreements} agreements)',
      ));
    }
    return out;
  }

  /// WPP-IDP corroborations for the merger
  /// (passive_radar_wpp_idp_spec.md): upgrade-only existence evidence,
  /// boost 0.10. Moving-node events contribute exactly 0 (ego-motion
  /// gate); micro-Doppler is never identity (Kozlov constraint).
  List<GatedCorroboration> _wppIdpCorroborations(DateTime now) {
    final out = <GatedCorroboration>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      for (final w in d.recentWppIdp) {
        // Ego-motion gate: moving-node events contribute exactly 0.
        if (!w.mergesIntoConfidence) continue;
        final age = now.difference(w.t);
        if (age.isNegative || age > kWppIdpStalenessHorizon) continue;
        // Quality from strength over a 3 dB floor (starting estimate).
        final q = ((w.strength - 3.0) / 12.0).clamp(0.0, 1.0);
        final gw = reliabilityGate(
          alignmentQuality: q,
          age: age,
          stalenessHorizon: kWppIdpStalenessHorizon,
          sourceHealthy: _sdrSourceHealthy(now),
        );
        if (gw <= 0) continue;
        final a = w.assess();
        out.add(GatedCorroboration(
          sensorId: 'wpp_idp:${w.radio}',
          boost: kWppIdpBoost,
          gateWeight: gw,
          note: a.label + (a.rcsMismatch ? ' — RCS MISMATCH FLAGGED' : ''),
        ));
      }
    }
    return out;
  }

  /// Source health for one observation: the producing driver must be
  /// alive with recent data, otherwise its evidence is unmeasurable —
  /// exactly the "degraded modality" AV-FDTI's gate removes.
  bool _sensorSourceHealthy(SensorObservation o, DateTime now) {
    if (o.type == SensorObsType.motion) {
      // Camera path: healthy when the integration is enabled and has
      // produced motion recently (the camera driver owns its cadence).
      return cameraSettings.enabled &&
          _cameraDriver
              .recentMotion(const Duration(seconds: 90))
              .isNotEmpty;
    }
    // Sensor-bus path: the bus driver must have polled recently.
    for (final p in _pollers) {
      if (p.driver.driverId == 'sensor' && p.config.enabled) {
        final lp = p.status.lastPoll;
        return lp != null &&
            now.difference(lp) < const Duration(seconds: 90);
      }
    }
    return false;
  }

  /// Clear all track-derived display state (settings change, session
  /// start, replay start). The monitor resets too — a new session's
  /// velocity state starts clean.
  void _clearTrackState() {
    track = null;
    trackConfidence = null;
    trackConsistency = null;
    rtiImage = const [];
    _consistencyMonitor.reset();
  }

  // ---- Adaptive baseline (ARTI) + guided calibration ----

  /// Band/channel label for calibration and imaging tables: SDR
  /// virtual links carry `sdr:band-<label>`; mesh links are 'mesh'.
  static String bandChannelOf(String linkKey) {
    final m = RegExp(r'sdr:band-([a-z0-9]+)', caseSensitive: false)
        .firstMatch(linkKey);
    if (m != null) return m.group(1)!;
    return 'mesh';
  }

  /// Feed one poll's enriched samples through the ARTI updater.
  void _updateAdaptiveBaseline(List<LinkSample> samples) {
    final now = DateTime.now();
    final arti = <ArtiSample>[];
    for (final s in samples) {
      final level = s.snr;
      if (level == null || !level.isFinite) continue;
      final th = s.effectiveThreshold(settings.dipThreshold);
      final ch = bandChannelOf(s.linkKey);
      for (final dir in const ['dip', 'rise']) {
        arti.add(ArtiSample(
          linkKey: s.linkKey,
          channel: ch,
          direction: dir,
          level: level,
          madThreshold: th,
        ));
      }
    }
    _adaptive.update(
      now: now,
      samples: arti,
      tracks: track == null ? const [] : [track!],
      nodes: effectiveNodes,
      heldLinks: _tripwire.heldLinkPolls,
    );
  }

  /// Collect static RSS into the guided routine's accumulator while
  /// calibrating. Only nodes flagging `calib` in their beacon count
  /// toward the fit (a node mid-reboot must not contaminate it);
  /// mesh (non-ESP32) links are always eligible.
  void _accumulateCalibration(List<LinkSample> samples) {
    final calibNodes = <String>{};
    for (final p in _pollers) {
      final d = p.driver;
      if (d is Esp32Driver) calibNodes.addAll(d.calibNodes);
    }
    for (final s in samples) {
      final level = s.snr;
      if (level == null || !level.isFinite) continue;
      if (driverOf(s.fromNode) == 'esp32' &&
          !calibNodes.contains(s.fromNode.replaceFirst('esp32:', ''))) {
        continue;
      }
      _adaptive.observeCalibration(
        linkKey: s.linkKey,
        channel: bandChannelOf(s.linkKey),
        rssi: level,
      );
    }
    if (track == null) _calibQuietPolls++;
  }

  /// Throttled ARTI runtime-stats persistence (1/min aggregates).
  void _maybeRecordArtiStats() {
    final now = DateTime.now();
    final last = _lastArtiStatsAt;
    if (last != null &&
        now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastArtiStatsAt = now;
    unawaited(recorder.recordJson(_adaptive.stats.toJson(now)));
  }

  /// Begin the deploy-time guided "Dial it in" routine. The operator
  /// emplaces nodes, taps Calibrate, stands clear 30–60 s, then nudges
  /// the named worst node and taps Re-measure until fade levels stop
  /// improving (or Done). Degraded mode runs on whatever quiet the
  /// tactical situation allows, and says so.
  void startCalibration({bool degradedMode = false}) {
    _adaptive.beginGuidedCalibration(degraded: degradedMode);
    calibrationState = CalibrationState.calibrating;
    _calibStartAt = DateTime.now();
    _calibQuietPolls = 0;
    calibrationNote = degradedMode
        ? 'DEGRADED MODE — running on whatever quiet is available; '
            'fade levels are provisional'
        : 'VACANT WINDOW — keep the area clear for 30–60 s';
    notifyListeners();
  }

  /// One nudge/re-measure round done (operator moved the named node).
  void calibrationNudgeRound() {
    _adaptive.nudgeRound();
    notifyListeners();
  }

  /// Finish the routine: fit path loss, rank links by fade level, set
  /// mu_calib anchors, persist the calibration record.
  Future<void> finishCalibration() async {
    final start = _calibStartAt;
    final vacantSecs = start == null
        ? 0.0
        : _calibQuietPolls * settings.pollInterval;
    final record = _adaptive.finishGuidedCalibration(
      nodes: effectiveNodes,
      vacantSecs: vacantSecs,
    );
    _calibStartAt = null;
    if (record == null) {
      calibrationState = CalibrationState.idle;
      calibrationNote = 'NO SAMPLES COLLECTED — routine discarded';
    } else {
      lastCalibration = record;
      calibrationState = record.degraded
          ? CalibrationState.degraded
          : CalibrationState.stable;
      calibrationNote = record.degraded
          ? 'CALIBRATED (DEGRADED MODE) — ${record.links.length} link-channels'
          : 'CALIBRATED — ${record.links.length} link-channels, '
              'worst: ${record.worstFirst.isEmpty ? '—' : record.worstFirst.first.link}';
      unawaited(recorder.recordJson(record.toJson()));
    }
    notifyListeners();
  }

  /// Abort the routine without anchoring anything.
  void cancelCalibration() {
    _adaptive.cancelGuidedCalibration();
    calibrationState = CalibrationState.idle;
    calibrationNote = null;
    _calibStartAt = null;
    notifyListeners();
  }

  /// Worst-link ranking for the guided routine: worst fade first.
  List<CalibrationLink> get calibrationWorstLinks =>
      lastCalibration?.worstFirst ?? const [];

  /// Owning-node summary for the ranked list, e.g.
  /// "RAPTOR-2 owns 4 of the 5 worst links".
  String get calibrationOwnerSummary {
    final worst = calibrationWorstLinks.take(5).toList();
    if (worst.isEmpty) return '';
    final counts = <String, int>{};
    for (final l in worst) {
      for (final id in l.link.split(' → ')) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    final top = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b);
    final name = nodePositions[top.key]?.displayName ?? top.key;
    return '$name owns ${top.value} of the ${worst.length} worst links';
  }

  /// ARTI suspect links (divergence safeguard froze them).
  Set<String> get suspectLinks => _adaptive.suspectLinkKeys;

  // ---- CSI / Doppler / WPP-IDP evidence lines + merger wiring ----

  /// CSI evidence lines for the evidence view. Honesty wording only:
  /// "Possible … consistent with …" — never identity.
  List<String> get csiEvidenceLines {
    final now = DateTime.now();
    final lines = <String>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! GenericSensorDriver) continue;
      for (final o in d.liveCsiObservations(now)) {
        final h = d.csiHealthFor(o.sensorId, now);
        final band = csiBoostFor(o.devHz);
        if (band <= 0) continue;
        final cls = switch (o.band) {
          CsiBand.smallMover => 'small-mover',
          CsiBand.personAnimal => 'person/animal-class',
          CsiBand.vehicleClass => 'vehicle-class',
          CsiBand.noise => 'noise',
        };
        lines.add(h.enabled
            ? 'Possible $cls disturbance (CSI ${o.devHz.toStringAsFixed(1)} Hz) — '
                'consistent with motion on the sniffed link'
            : 'CSI ${o.devHz.toStringAsFixed(1)} Hz on ${o.sensorId} — '
                'gated (${h.reason}); contributes nothing');
      }
      final flips = d.csiGateEvents;
      for (final g in flips.skip(
          flips.length > 3 ? flips.length - 3 : 0)) {
        lines.add(g);
      }
    }
    return lines;
  }

  /// Doppler evidence lines for the evidence view.
  List<String> get dopplerEvidenceLines {
    final now = DateTime.now();
    final lines = <String>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      final refs = d.recentDopplerRefs;
      if (refs.isEmpty) continue;
      final locked = refs.where((r) => r.refLocked).toList();
      if (locked.length < refs.length) {
        lines.add('Doppler reference unlocked on ${d.host}:${d.port} — '
            'no coherent measurement, contributes nothing');
      }
      final t = track;
      final sx = d.stationX, sy = d.stationY, ex = d.enbX, ey = d.enbY;
      if (t == null || sx == null || sy == null || ex == null || ey == null) {
        continue;
      }
      final v = DopplerCorrelator.correlate(
        track: t,
        refs: refs,
        now: now,
        radioX: sx,
        radioY: sy,
        enbX: ex,
        enbY: ey,
      );
      if (v.qualified) {
        lines.add('Doppler radial velocity consistent with track '
            '(${v.agreements} agreement${v.agreements == 1 ? '' : 's'})');
      } else if (v.agreements > 0) {
        lines.add('Doppler peaks present but below the agreement bar — '
            'contributes nothing (disagreement never downgrades a track)');
      }
    }
    return lines;
  }

  /// WPP-IDP evidence lines for the evidence view.
  List<String> get wppIdpEvidenceLines {
    final now = DateTime.now();
    final lines = <String>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      for (final w in d.recentWppIdp) {
        if (now.difference(w.t) > SdrDriver.wppIdpWindow) continue;
        if (!w.nodeStatic) {
          lines.add('WPP-IDP detection from moving node ${w.radio} — '
              'R&D logging only, contributes nothing (ego-motion gate)');
          continue;
        }
        final a = w.assess();
        lines.add(a.label +
            (a.rcsMismatch ? ' — RCS MISMATCH FLAGGED' : ''));
      }
    }
    return lines;
  }

  /// EXPERIMENTAL PMR monitor lines for the evidence sheet's monitor
  /// section (readings log + alert lines). Alerts first, then recent
  /// readings, capped so the section stays readable. This getter is
  /// the ONLY place PMR surfaces in the app: PMR is deliberately NOT
  /// wired into the confidence merger, the tripwire, tracks, or any
  /// veto. A low PMR is consistent with preamble interference, never
  /// a confirmed jamming verdict — the display wording in
  /// [PmrReading.displayLabel] enforces that.
  List<String> get pmrMonitorLines {
    final now = DateTime.now();
    final alerts = <String>[];
    final readings = <String>[];
    for (final p in _pollers) {
      final d = p.driver;
      if (d is! SdrDriver) continue;
      for (final r in d.recentPmrReadings) {
        if (now.difference(r.t) > SdrDriver.pmrWindow) continue;
        if (r.alert) {
          alerts.add(r.displayLabel);
        } else {
          readings.add(r.displayLabel);
        }
      }
    }
    final lines = <String>[...alerts, ...readings];
    if (lines.length > 12) return lines.sublist(0, 12);
    return lines;
  }

  /// Operator-configured station data for the Doppler correlator
  /// (field-local meters): the SDR radio's position and the LTE eNB's
  /// position. Without both, the correlator abstains.
  void setSdrStation({
    required double stationX,
    required double stationY,
    required double enbX,
    required double enbY,
  }) {
    for (final p in _pollers) {
      final d = p.driver;
      if (d is SdrDriver) {
        d.stationX = stationX;
        d.stationY = stationY;
        d.enbX = enbX;
        d.enbY = enbY;
      }
    }
    notifyListeners();
  }

  /// Last phone GPS fix, exposed for status readouts (SDR AUTO
  /// station, Settings). Null until the first successful fix.
  ({double lat, double lon, double altM, double accuracyM, DateTime at})?
      get lastPhoneFix => _lastPhoneFix;

  /// The auto-station position currently applied to the drivers, so a
  /// fresh phone fix only re-arms the geometry when the device has
  /// actually moved (> 25 m) — not on every fix refresh.
  ({double lat, double lon})? _appliedAutoStation;
  bool _autoStationRefreshInFlight = false;

  /// Human status for the Doppler geometry, shown in Settings.
  String get sdrGeometryStatus {
    final s = settings;
    final elat = s.sdrEnbLat, elon = s.sdrEnbLon;
    if (elat == null || elon == null) {
      return 'NOT CONFIGURED — THE DOPPLER CORRELATOR ABSTAINS UNTIL '
          'THE eNB IS SET (eNB POSITION IS ALWAYS MANUAL)';
    }
    if (s.sdrAutoStation) {
      final applied = _appliedAutoStation;
      if (applied == null) {
        return 'AUTO STATION — WAITING FOR A PHONE GPS FIX; '
            'CORRELATOR ABSTAINS UNTIL IT LANDS';
      }
      final fix = _lastPhoneFix;
      final acc = fix == null
          ? ''
          : ' (±${fix.accuracyM.toStringAsFixed(0)} M)';
      // Armed on a fix that has since gone stale: say so — the
      // geometry on the drivers is last-known, not current.
      if (fix != null && DateTime.now().difference(fix.at).inMinutes >= 30) {
        return 'AUTO STATION FROM PHONE GPS$acc — FIX STALE '
            '(${DateTime.now().difference(fix.at).inMinutes} MIN OLD); '
            'GEOMETRY IS LAST-KNOWN UNTIL A FRESH FIX LANDS';
      }
      final coarse = fix != null && fix.accuracyM > 100
          ? ' — COARSE FIX, GEOMETRY IS ROUGH'
          : '';
      return 'AUTO STATION FROM PHONE GPS$acc — CORRELATOR ARMED; '
          'eNB MANUAL$coarse';
    }
    if (s.sdrStationLat == null || s.sdrStationLon == null) {
      return 'NOT CONFIGURED — SET THE STATION OR TURN ON AUTO STATION';
    }
    return 'MANUAL GEOMETRY — CORRELATOR ARMED';
  }

  /// Push the persisted SDR station / LTE eNB geometry (Settings → SDR
  /// station) to the SDR drivers for the Doppler correlator.
  ///
  /// Lat/lon → field-local meters via the GPS field origin when one is
  /// set; otherwise the station itself is the local origin (0,0) and
  /// the eNB is placed relative to it. No-op until the station and the
  /// eNB are both known — the correlator abstains without them
  /// (silence, never a guess). Called on start() so a restart re-arms
  /// the persisted geometry, and after settings are saved.
  ///
  /// AUTO station (settings.sdrAutoStation): the station is the
  /// device's own GPS fix instead of the hand-entered coordinates
  /// (kept untouched underneath). A fix older than 30 min does not
  /// arm the correlator; a missing/stale fix kicks a refresh and the
  /// apply retries when it lands.
  void applySdrStationFromSettings() =>
      _applySdrStation(allowKick: true);

  void _applySdrStation({required bool allowKick}) {
    final s = settings;
    var slat = s.sdrStationLat;
    var slon = s.sdrStationLon;
    final elat = s.sdrEnbLat;
    final elon = s.sdrEnbLon;
    if (elat == null || elon == null) return;
    if (s.sdrAutoStation) {
      final fix = _lastPhoneFix;
      final fresh = fix != null &&
          DateTime.now().difference(fix.at).inMinutes < 30 &&
          fix.lat.isFinite &&
          fix.lon.isFinite;
      if (!fresh) {
        // One kick per apply chain: the refresh completion re-applies
        // with allowKick=false, so a failed fix can't loop forever.
        if (allowKick) _kickAutoStationRefresh();
        return;
      }
      final applied = _appliedAutoStation;
      if (applied != null) {
        final moved =
            latLonToMeters(fix.lat, fix.lon, applied.lat, applied.lon);
        final distM = math.sqrt(moved.x * moved.x + moved.y * moved.y);
        if (distM < 25) {
          // Already armed at (nearly) this spot — keep the applied
          // position so the geometry doesn't jitter with GPS noise.
          slat = applied.lat;
          slon = applied.lon;
        } else {
          slat = fix.lat;
          slon = fix.lon;
          _appliedAutoStation = (lat: fix.lat, lon: fix.lon);
        }
      } else {
        slat = fix.lat;
        slon = fix.lon;
        _appliedAutoStation = (lat: fix.lat, lon: fix.lon);
      }
    } else {
      _appliedAutoStation = null;
    }
    if (slat == null || slon == null) return;
    final origin = gpsOrigin;
    final refLat = origin?.lat ?? slat;
    final refLon = origin?.lon ?? slon;
    final st = latLonToMeters(slat, slon, refLat, refLon);
    final en = latLonToMeters(elat, elon, refLat, refLon);
    setSdrStation(
      stationX: st.x,
      stationY: st.y,
      enbX: en.x,
      enbY: en.y,
    );
  }

  /// Refresh the phone fix for AUTO station mode, then re-apply.
  /// In-flight guarded; failures leave the correlator abstaining.
  void _kickAutoStationRefresh() {
    if (_autoStationRefreshInFlight) return;
    _autoStationRefreshInFlight = true;
    unawaited(refreshPhoneFix().whenComplete(() {
      _autoStationRefreshInFlight = false;
      if (settings.sdrAutoStation) _applySdrStation(allowKick: false);
    }));
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
  void _finalizeEpisode(EpisodeSummary s, double pollInterval) {
    final i = events.indexWhere(
        (e) => e.linkKey == s.linkKey && e.timestamp == s.confirmedAt);
    if (i < 0) return;
    final old = events[i];
    final peak = s.peak > old.dipDepth ? s.peak : old.dipDepth;
    final dur =
        s.durationSecs > old.durationSecs ? s.durationSecs : old.durationSecs;
    final next = old.copyWith(
      dipDepth: peak,
      durationSecs: dur,
      sizeEstimate: peak < 10 ? 'S' : peak < 20 ? 'M' : 'L',
      viaVariance: old.viaVariance || s.viaVariance,
    );
    events[i] = _classifyEvent(next, pollInterval);
  }

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
    if (!_zmetaEmitAllowed()) return;
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
      final send = _zmetaSendFn();
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
        await send(obs);
        if (e.aiLabel != null && e.aiConfidence != null) {
          final obsId = (obs['event'] as Map)['event_id'] as String;
          await send(zmetaInference(
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

  // ---- Persisted settings (ZMeta block + CoT block) ----
  // NOTE: the storage key keeps its historical 'zmeta' name — renaming
  // it would orphan every existing install's saved settings.

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
    // The persisted trusted-sources list gates BOTH unauthenticated
    // inputs from boot — _configureCot covers CoT; the node UDP hub
    // needs its own call or the 49160 allowlist silently reverts to
    // accept-any on every restart (reviewer catch, 2026-10-21).
    NodeUdpHub.setAllowedSourcesFromText(settings.trustedSources);
    // Same boot rule for the Skydio surfaces: the persisted friendly
    // registry and Remote ID toggle must be live from boot, not only
    // after the next settings save.
    _applySkydioSettings();
    unawaited(_configureCot());
    notifyListeners();
  }

  Future<void> _saveSettings() async {
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

  /// (Re)start the device auto-connect coordinator. Called at the end
  /// of start() and when the auto-connect setting changes. Never
  /// removes configs — a watcher only ADDS validated devices.
  void _startAutoConnect() {
    _autoConnect?.stop();
    _autoConnect = null;
    if (!settings.autoConnectSilvusUsb || settings.simulatedMode) return;
    _autoConnect = DeviceAutoConnect(
      watchers: [
        SilvusUsbWatcher(
          // Skip the handshake for radios we already poll — the
          // closure reads the live config list each tick.
          knownAddresses: () => {
            for (final c in radioConfigs)
              if (c.driverId == 'silvus') c.address,
          },
        ),
      ],
      onCandidate: _onAutoConnectCandidate,
      isKnown: (familyId, address) => radioConfigs.any(
        (c) => c.driverId == familyId && c.address == address,
      ),
    );
    _autoConnect!.start();
  }

  /// A validated device appeared. Dedupe by driverId+address (an
  /// interface flap must not clone the config), then add it — addRadio
  /// restarts polling so the new driver starts immediately.
  Future<void> _onAutoConnectCandidate(AutoConnectCandidate c) async {
    final known = radioConfigs.any(
      (r) => r.driverId == c.familyId && r.address == c.address,
    );
    if (known) return;
    await addRadio(RadioConfig(
      driverId: c.familyId,
      address: c.address,
      label: c.label,
      pollInterval: settings.pollInterval,
    ));
  }

  /// Auto-connect toggle for Silvus USB. Takes effect immediately.
  Future<void> setAutoConnectSilvusUsb(bool v) async {
    settings.autoConnectSilvusUsb = v;
    await _saveSettings();
    if (polling && !settings.simulatedMode) _startAutoConnect();
    notifyListeners();
  }

  /// Dashboard radios card: TAK/CoT emit link state. Multicast is
  /// connectionless by design, so it reports the mode, not a link.
  String get cotLinkStatus {
    if (!settings.cotEmitEnabled) return 'OFF';
    if (settings.cotEmitUseMulticast) return 'MULTICAST';
    final p = _cotPublisher;
    if (p == null) return 'OFF';
    if (p.takConnected) return 'LINKED';
    return 'RETRYING';
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
    // Review fix: these periodic timers were never cancelled on
    // dispose and kept firing (phone-fix refresh, heartbeat, and the
    // Remote ID Wi-Fi poll) against a disposed AppState.
    _zmetaFixTimer?.cancel();
    _zmetaFixTimer = null;
    _zmetaHeartbeatTimer?.cancel();
    _zmetaHeartbeatTimer = null;
    remoteId.dispose();
    _autoConnect?.stop();
    _autoConnect = null;
    _zmeta?.close();
    _zmeta = null;
    _cotPublisher?.dispose();
    _cotPublisher = null;
    unawaited(_cotListener?.stop());
    _cotListener = null;
    for (final p in _pollers) {
      p.timer?.cancel();
      try {
        p.driver.dispose();
      } catch (_) {}
    }
    _pollers.clear();
    wifi.stop();
    // v0.26.0: a running Hunt session owns a motion-sensor
    // subscription; close it with the app state, not on next launch.
    unawaited(endHuntSession());
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
