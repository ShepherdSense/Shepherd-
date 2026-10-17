/// Camera driver: motion events become [SensorObservation]s of type
/// MOTION — corroboration only, never detection, never veto.
///
/// Two ingest paths (use either; both feed the same observation
/// stream):
///
/// A. HTTP motion-webhook receiver (MOST PLUG-AND-PLAY). The driver
///    binds an HTTP server (default port 49162); cameras / NVRs
///    (Frigate, Shinobi, Blue Iris, most IP cams) POST on motion:
///      POST /motion  {"camera":"front-porch","zone":"3",
///                     "label":"Driveway","snapshot_url":"http://…"}
///    Lenient: also accepts ?camera=x&zone=3 query form and several
///    common field spellings. Anything unparseable → 400, logged,
///    never a crash.
///
/// B. ONVIF event subscription (best-effort). PullPoint subscription
///    against the camera's events service, polling PullMessages for
///    RuleEngine/MotionDetector (and VideoSource/MotionAlarm) topics.
///    VERIFIED: SOAP envelope construction + topic/state parsing
///    against synthetic responses (unit-tested). NOT field-verified
///    against real camera firmware — WS-Security variants, digest
///    nonce handling, and vendor topic dialects differ in the wild.
///    Failures are logged; the webhook path is the supported one.
///
/// UPGRADE-ONLY CONTRACT (load-bearing): this driver has no code path
/// that can suppress, cancel, or downgrade a detection. Motion
/// observations raise the displayed confidence of tracks the RF
/// tripwire already supports ([SensorObservation.corroborationFor]).
/// Absence of motion means nothing (occlusion, night, facing away).
/// SEAM: at merge, app_state's requestCameraConfirmation consults
/// [recentMotion] — see the merge snippet at the bottom of this file.
///
/// Snapshots: [fetchSnapshot] pulls a JPEG on demand for the evidence
/// view ("why did it alert" + a frame). Frames stay on-device; the
/// ZMeta payload carries only a local snapshot_ref, never pixels.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/sensor_observation.dart';
import '../models/link_sample.dart';
import 'radio_driver.dart';

/// Persisted camera config. New code path — settings.dart does not
/// touch this yet.
/// SEAM: at merge, settings.dart loads/saves this via SharedPreferences
/// (key 'camera_settings') and adds UI: enable toggle, webhook port,
/// ONVIF address/user/pass, snapshot URL template.
class CameraSettings {
  CameraSettings({
    this.enabled = false,
    this.webhookPort = 49162,
    this.onvifAddress = '',
    this.onvifUser = '',
    this.onvifPass = '',
    this.snapshotUrlTemplate = '',
  });

  bool enabled;
  int webhookPort;
  String onvifAddress;
  String onvifUser;
  String onvifPass;

  /// e.g. "http://cam-ip/shot.jpg" or with {camera} placeholder.
  String snapshotUrlTemplate;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'webhookPort': webhookPort,
        'onvifAddress': onvifAddress,
        'onvifUser': onvifUser,
        'onvifPass': onvifPass,
        'snapshotUrlTemplate': snapshotUrlTemplate,
      };

  factory CameraSettings.fromJson(Map<String, dynamic> j) => CameraSettings(
        enabled: j['enabled'] == true,
        webhookPort: (j['webhookPort'] is num)
            ? (j['webhookPort'] as num).toInt().clamp(1024, 65535)
            : 49162,
        onvifAddress: '${j['onvifAddress'] ?? ''}',
        onvifUser: '${j['onvifUser'] ?? ''}',
        onvifPass: '${j['onvifPass'] ?? ''}',
        snapshotUrlTemplate: '${j['snapshotUrlTemplate'] ?? ''}',
      );
}

class CameraDriver extends RadioDriver {
  CameraDriver({CameraSettings? settings})
      : settings = settings ?? CameraSettings();

  final CameraSettings settings;

  /// SEAM: at merge, app_state sets this to route observations into
  /// the shared observation store / evidence path.
  void Function(SensorObservation)? onObservation;

  HttpServer? _webhook;
  OnvifMotionClient? _onvif;
  Timer? _onvifTimer;
  bool _running = false;
  int _webhookHits = 0;
  int _webhookBad = 0;

  @override
  String get driverId => 'camera';

  @override
  String get label => 'CAMERA';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'Camera driver idle — enable it and point a camera webhook at '
      'http://<this-device>:${settings.webhookPort}/motion, or set an '
      'ONVIF address.';

  int get webhookHits => _webhookHits;
  int get webhookBad => _webhookBad;

  /// Start webhook receiver and (if configured) the ONVIF poller.
  /// Safe to call repeatedly; [dispose] then [start] re-applies
  /// changed settings.
  Future<void> start() async {
    if (_running || !settings.enabled) return;
    _running = true;
    await _startWebhook();
    _startOnvif();
  }

  Future<void> _startWebhook() async {
    try {
      _webhook?.close(force: true);
      _webhook = await HttpServer.bind(
          InternetAddress.anyIPv4, settings.webhookPort);
      _webhook!.listen(_handleWebhook);
    } catch (e) {
      debugPrint('camera webhook bind failed: $e');
      _webhook = null;
    }
  }

  Future<void> _handleWebhook(HttpRequest req) async {
    try {
      if (req.method != 'POST' || req.uri.path != '/motion') {
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('POST /motion only');
        await req.response.close();
        return;
      }
      final body = await utf8.decoder.bind(req).join();
      final obs = _webhookToObs(body, req.uri.queryParameters);
      if (obs == null) {
        _webhookBad++;
        req.response
          ..statusCode = HttpStatus.badRequest
          ..write('unparseable motion payload');
      } else {
        _webhookHits++;
        _emitMotion(obs);
        req.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
      }
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Lenient webhook → MOTION observation. Never throws.
  /// Test hook is [webhookToObsForTest].
  SensorObservation? _webhookToObs(
      String body, Map<String, String> query) {
    try {
      return _webhookToObsInner(body, query);
    } catch (_) {
      return null;
    }
  }

  SensorObservation? _webhookToObsInner(
      String body, Map<String, String> query) {
    final t = body.trim();
    // No signal at all: not a motion event (could be a health check).
    if (t.isEmpty && query.isEmpty) return null;
    Map<String, dynamic> j = {};
    if (t.startsWith('{')) {
      final d = jsonDecode(t);
      if (d is! Map<String, dynamic>) return null;
      j = d;
    } else if (t.isNotEmpty && query.isEmpty) {
      return null; // garbage body, no params → not a motion signal
    }
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = j[k] ?? query[k];
        if (v != null && '$v'.trim().isNotEmpty) return '$v'.trim();
      }
      return '';
    }

    // Frigate-compatible: {"after":{"camera":"x","label":"person"}}
    final after = j['after'];
    String frigateCam = '';
    String frigateLabel = '';
    if (after is Map<String, dynamic>) {
      frigateCam = '${after['camera'] ?? ''}';
      frigateLabel = '${after['label'] ?? ''}';
    }

    var cam = pick(['camera', 'camera_id', 'id', 'name', 'device']);
    if (cam.isEmpty) cam = frigateCam;
    if (cam.isEmpty) cam = 'webhook';
    var zone = pick(['zone', 'channel', 'ch']);
    var label = pick(['label', 'event', 'type', 'description']);
    if (label.isEmpty) label = frigateLabel;
    final snap = pick(['snapshot_url', 'snapshot', 'image_url']);

    // A bare ping with no motion semantics is not an observation.
    final looksLikeMotion = j['event'] == null ||
        '${j['event']}'.toLowerCase().contains('motion') ||
        label.toLowerCase().contains('motion') ||
        label.toLowerCase().contains('person') ||
        label.toLowerCase().contains('car') ||
        frigateLabel.isNotEmpty ||
        query.isNotEmpty;
    if (!looksLikeMotion && t.isNotEmpty && !t.startsWith('{')) {
      return null;
    }
    return SensorObservation(
      type: SensorObsType.motion,
      sensorId: 'cam:${cam.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}',
      timestamp: DateTime.now(),
      zone: zone.isEmpty ? null : zone,
      zoneLabel: label.isEmpty ? null : label,
      snapshotRef: snap.isEmpty ? null : 'url:$snap',
    );
  }

  @visibleForTesting
  SensorObservation? webhookToObsForTest(
          String body, Map<String, String> query) =>
      _webhookToObs(body, query);

  void _startOnvif() {
    final addr = settings.onvifAddress.trim();
    if (addr.isEmpty) return;
    _onvif = OnvifMotionClient(
      address: addr,
      user: settings.onvifUser,
      pass: settings.onvifPass,
      onMotion: (zone) {
        _emitMotion(SensorObservation(
          type: SensorObsType.motion,
          sensorId: 'cam:onvif-${addr.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}',
          timestamp: DateTime.now(),
          zone: zone,
          zoneLabel: 'ONVIF motion',
        ));
      },
    );
    _onvifTimer?.cancel();
    _onvifTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _onvif?.pollOnce());
    _onvif?.pollOnce();
  }

  /// One funnel for motion events: local log (for the confirmation
  /// contract) + the merge-wired observation callback.
  void _emitMotion(SensorObservation obs) {
    _motionLog.add(obs);
    if (_motionLog.length > 200) {
      _motionLog.removeRange(0, _motionLog.length - 200);
    }
    onObservation?.call(obs);
  }

  /// Recent MOTION observations for the confirmation contract.
  /// SEAM: app_state.requestCameraConfirmation calls this at merge;
  /// statuses to use: 'CORROBORATED' when non-empty (upgrades
  /// displayed confidence), 'NOT_CONFIGURED' when disabled, 'NO_MOTION'
  /// otherwise (informational only — never a veto).
  List<SensorObservation> recentMotion(Duration window) =>
      _recentMotionStore(window);

  final List<SensorObservation> _motionLog = [];

  List<SensorObservation> _recentMotionStore(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    _motionLog.removeWhere((o) => o.timestamp.isBefore(cutoff));
    return List.of(_motionLog);
  }

  /// Pull a snapshot JPEG for the evidence view. Returns bytes or null.
  /// On-device only; never shipped anywhere automatically.
  Future<List<int>?> fetchSnapshot(String cameraId) async {
    final tpl = settings.snapshotUrlTemplate.trim();
    if (tpl.isEmpty) return null;
    final url = tpl.replaceAll('{camera}', cameraId.replaceFirst('cam:', ''));
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final req = await client.getUrl(Uri.parse(url));
      if (settings.onvifUser.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader,
            _basicAuth(settings.onvifUser, settings.onvifPass));
      }
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        client.close(force: true);
        return null;
      }
      final bytes = await resp.fold<List<int>>(
          [], (p, e) => p..addAll(e));
      client.close(force: true);
      if (bytes.length < 100 || bytes.length > 20 * 1024 * 1024) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static String _basicAuth(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  @override
  Future<List<LinkSample>> poll() async {
    // Cameras corroborate; they don't drive the tripwire. No links.
    return const [];
  }

  @override
  Future<bool> probe() async => true;

  @override
  void dispose() {
    _running = false;
    _onvifTimer?.cancel();
    _onvifTimer = null;
    _onvif?.close();
    _onvif = null;
    try {
      _webhook?.close(force: true);
    } catch (_) {}
    _webhook = null;
  }
}

/// Best-effort ONVIF PullPoint motion client.
///
/// VERIFIED: SOAP envelope shapes + topic/state extraction against
/// synthetic responses (see test). NOT field-verified: real cameras
/// vary in WS-Security requirements, digest nonce handling, event
/// service paths, and topic dialects. HTTP digest auth is handled by
/// Dart's HttpClient; WS-UsernameToken headers are NOT sent (many
/// cameras accept HTTP-level auth alone — when they don't, this
/// client fails closed with a logged error and the webhook path
/// remains the supported integration).
class OnvifMotionClient {
  OnvifMotionClient({
    required this.address,
    required this.user,
    required this.pass,
    required this.onMotion,
  });

  final String address;
  final String user;
  final String pass;
  final void Function(String? zone) onMotion;

  final HttpClient _client = HttpClient();
  String? _subscriptionAddr;
  bool _closed = false;
  bool _authArmed = false;

  static const _motionTopics = [
    'MotionDetector',
    'MotionAlarm',
  ];

  Uri get _eventsUri {
    var a = address.trim();
    if (!a.startsWith('http')) a = 'http://$a';
    return Uri.parse('$a/onvif/events_service');
  }

  Future<void> pollOnce() async {
    if (_closed) return;
    try {
      _subscriptionAddr ??= await _subscribe();
      if (_subscriptionAddr == null) return;
      await _pull();
    } catch (e) {
      debugPrint('onvif poll: $e');
    }
  }

  Future<String?> _subscribe() async {
    const body = '''
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
 xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"
 xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
<soap:Body><tev:CreatePullPointSubscription>
<tev:Filter><wsnt:TopicExpression Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">tns1:RuleEngine/MotionDetector</wsnt:TopicExpression></tev:Filter>
<tev:InitialTerminationTime>PT600S</tev:InitialTerminationTime>
</tev:CreatePullPointSubscription></soap:Body></soap:Envelope>''';
    final resp = await _soap(_eventsUri, body,
        'http://www.onvif.org/ver10/events/wsdl/CreatePullPointSubscription');
    if (resp == null) {
      // Fallback path some firmwares use.
      final alt = _eventsUri.toString().replaceAll(
          '/onvif/events_service', '/onvif/event_service');
      final r2 = await _soap(Uri.parse(alt), body,
          'http://www.onvif.org/ver10/events/wsdl/CreatePullPointSubscription');
      if (r2 == null) return null;
      return extractSubscription(r2);
    }
    return extractSubscription(resp);
  }

  Future<void> _pull() async {
    final sub = _subscriptionAddr;
    if (sub == null) return;
    const body = '''
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
<soap:Body><tev:PullMessages>
<tev:Timeout>PT20S</tev:Timeout><tev:MessageLimit>16</tev:MessageLimit>
</tev:PullMessages></soap:Body></soap:Envelope>''';
    final resp = await _soap(Uri.parse(sub), body,
        'http://www.onvif.org/ver10/events/wsdl/PullMessages');
    if (resp == null) {
      _subscriptionAddr = null; // re-subscribe next poll
      return;
    }
    for (final hit in extractMotionHits(resp)) {
      onMotion(hit);
    }
  }

  Future<String?> _soap(
      Uri uri, String body, String action) async {
    try {
      if (!_authArmed && user.isNotEmpty) {
        _client.authenticate = (u, s, r) async {
          _authArmed = true;
          return true;
        };
        _client.authenticateProxy = null;
        // Dart HttpClient digest: supply credentials via addCredentials.
        _client.addCredentials(
            uri, '', HttpClientDigestCredentials(user, pass));
      }
      final req = await _client.postUrl(uri);
      req.headers.contentType =
          ContentType('application', 'soap+xml', charset: 'utf-8');
      req.headers.set('SOAPAction', action);
      req.write(body);
      final resp =
          await req.close().timeout(const Duration(seconds: 25));
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        debugPrint('onvif soap ${resp.statusCode} from $uri');
        return null;
      }
      return text;
    } catch (e) {
      debugPrint('onvif soap error: $e');
      return null;
    }
  }

  /// Test hook: extract the pull-point address from a subscribe reply.
  /// Namespace-agnostic: vendors vary the prefix (wsa/wsa5/tev/none).
  @visibleForTesting
  static String? extractSubscription(String xml) {
    final m = RegExp(
            r'<(?:\w+:)?SubscriptionReference>.*?<(?:\w+:)?Address>([^<]+)</',
            dotAll: true)
        .firstMatch(xml);
    final addr = m?.group(1)?.trim();
    return (addr == null || addr.isEmpty) ? null : addr;
  }

  /// Test hook: motion topic hits in a PullMessages reply. Returns the
  /// zone/source token per hit (null when the topic has none).
  /// Only State=true transitions count — State=false is "motion
  /// ended", not an observation.
  @visibleForTesting
  static List<String?> extractMotionHits(String xml) {
    final hits = <String?>[];
    final msgRe = RegExp(r'<wsnt:NotificationMessage>(.*?)</wsnt:NotificationMessage>',
        dotAll: true);
    for (final msg in msgRe.allMatches(xml)) {
      final body = msg.group(1)!;
      final isMotion =
          _motionTopics.any((t) => body.contains(t));
      if (!isMotion) continue;
      final state = RegExp(
              r'<(?:\w+:)?SimpleItem[^>]*Name="State"[^>]*Value="([^"]+)"')
          .firstMatch(body);
      final val = state?.group(1)?.toLowerCase() ?? '';
      if (val != 'true' && val != '1') continue;
      final source = RegExp(
              r'<(?:\w+:)?SimpleItem[^>]*Name="Source"[^>]*Value="([^"]+)"')
          .firstMatch(body);
      hits.add(source?.group(1));
    }
    return hits;
  }

  void close() {
    _closed = true;
    try {
      _client.close(force: true);
    } catch (_) {}
  }
}

// SEAM: at merge, wire into radio_driver.dart:
//   import 'camera_driver.dart';
//   case 'camera': return CameraDriver();
// and driverTypes +=
//   (id: 'camera', label: 'CAMERA (webhook / ONVIF)', implemented: true),
// app_state merge:
//   - construct ONE CameraDriver (not per RadioConfig poll), call
//     start() when settings enabled; onObservation → shared observation
//     store; requestCameraConfirmation consults recentMotion() →
//     'CORROBORATED' upgrades displayed confidence, never vetoes.
// settings.dart merge: CameraSettings UI (enable, webhook port, ONVIF
// address/user/pass, snapshot template) — all fields already exist here.
