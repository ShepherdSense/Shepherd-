/// ZMeta HTTPS ingest — the no-WireGuard emit path.
///
/// For forward-deployed operators who can't install the WireGuard app
/// (or whose network blocks WireGuard's UDP), the hub exposes an HTTPS
/// ingest endpoint. The mesh redeems its invite code exactly as before;
/// the hub's redeem response additionally carries `ingest_url` +
/// `ingest_token`. Events POST as JSON with `Authorization: Bearer`.
///
/// The token is the credential: it lives in secure storage (see
/// zmeta_ingest_store.dart), never in SharedPreferences, and is bound
/// hub-side to exactly one platform_id (the same binding the WireGuard
/// tunnel IP used to provide). The gateway still validates every event.
///
/// TLS is dual-mode, matching the redeem (S1): the invite code's certfp
/// ('-' for Cloudflare/public-CA, 64-hex for pinned self-signed) is
/// persisted in settings at join time and the emitter builds its
/// HttpClient the same way — a pin-mode hub must not silently drop
/// every event.
///
/// Security posture mirrors the UDP path: emit-only, fail-closed, never
/// throws into detection. Plain HTTP is accepted ONLY for loopback
/// (field hubs behind cloudflared terminate TLS at the edge and run
/// the pairing/ingest server on 127.0.0.1 --no-tls).
///
/// Pure Dart (dart:io) — no Flutter imports — so it stays unit-testable.
library zmeta_https_ingest;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'zmeta_pairing.dart' show zmetaFingerprintHex;

/// Send closure type: one event map in, nothing out, never throws.
typedef ZmetaSend = Future<void> Function(Map<String, dynamic> event);

/// After this many consecutive 401s the hub is presumed to have revoked
/// (or never issued) the token; the UI surfaces a re-join prompt (S3).
const int kIngestTokenRejectThreshold = 5;

/// HTTPS emitter for ZMeta events. Never throws into the app: a down
/// hub, a bad token, or a network failure just drops the event (counted
/// in [dropped]) — detection continues. Single attempt per event; the
/// next event tries again. No retry storm by construction.
class ZMetaHttpsEmitter {
  ZMetaHttpsEmitter({
    required this.ingestUrl,
    required this.tokenProvider,
    this.fpMode = '',
  });

  /// Validated ingest endpoint (see [zmetaValidateIngestUrl]).
  final String ingestUrl;

  /// Returns the bearer token, or null when none is stored. Called per
  /// send so a revoked-then-rejoined token is picked up without an
  /// app restart.
  final Future<String?> Function() tokenProvider;

  /// TLS mode captured from the invite code at join: '-' (Cloudflare /
  /// public-CA) or 64-hex (pinned self-signed). Empty = default trust.
  final String fpMode;

  int sent = 0;
  int dropped = 0;
  int _consecutive401 = 0;

  /// Most sends allowed in flight at once. Beyond this an event is
  /// dropped (counted) instead of queueing without bound behind a dead
  /// hub — each send can hold ~30 s of timeouts.
  static const int maxInFlight = 32;
  int _inFlight = 0;

  /// In-memory token cache: the keystore read is slow and was paid per
  /// event, with a 5 s timeout that could stall every send. Re-read
  /// after [_tokenTtl], and immediately after any 401 (so a re-joined
  /// token is picked up without a restart).
  static const Duration _tokenTtl = Duration(seconds: 30);
  String? _cachedToken;
  DateTime? _cachedAt;

  /// Forget the cached token (call after a re-join).
  void invalidateToken() {
    _cachedToken = null;
    _cachedAt = null;
  }

  Future<String?> _token() async {
    final at = _cachedAt;
    if (_cachedToken != null &&
        at != null &&
        DateTime.now().difference(at) < _tokenTtl) {
      return _cachedToken;
    }
    String? t;
    try {
      t = await tokenProvider().timeout(const Duration(seconds: 5));
    } catch (_) {
      t = null;
    }
    if (t != null && t.isNotEmpty) {
      _cachedToken = t;
      _cachedAt = DateTime.now();
    }
    return t;
  }

  /// True once the hub has rejected the token [kIngestTokenRejectThreshold]
  /// times in a row — the settings screen tells the operator to re-join.
  /// Resets on any 2xx.
  bool get tokenRejected => _consecutive401 >= kIngestTokenRejectThreshold;

  bool _closed = false;
  HttpClient? _client;

  HttpClient _buildClient() {
    // S1: pin mode gets the same empty-trust-store + pin callback the
    // redeem used; Cloudflare mode (or unknown) uses system roots.
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(fpMode)) {
      final c = HttpClient(context: SecurityContext())
        ..maxConnectionsPerHost = 4
        ..connectionTimeout = const Duration(seconds: 10);
      c.badCertificateCallback =
          (X509Certificate cert, String host, int port) =>
              zmetaFingerprintHex(cert) == fpMode;
      return c;
    }
    return HttpClient()
      ..maxConnectionsPerHost = 4
      ..connectionTimeout = const Duration(seconds: 10);
  }

  /// POSTs one event as JSON. Safe to call without awaiting; errors are
  /// swallowed and counted.
  Future<void> send(Map<String, dynamic> event) async {
    if (_closed) return;
    if (_inFlight >= maxInFlight) {
      dropped++;
      return;
    }
    _inFlight++;
    try {
      await _send(event);
    } finally {
      _inFlight--;
    }
  }

  Future<void> _send(Map<String, dynamic> event) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      dropped++;
      return;
    }
    try {
      _client ??= _buildClient();
      final req = await _client!
          .postUrl(Uri.parse(ingestUrl))
          .timeout(const Duration(seconds: 10));
      // Never follow redirects with a bearer token attached: a redirect
      // must not carry the credential to another host.
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.write(jsonEncode(event));
      final resp =
          await req.close().timeout(const Duration(seconds: 10));
      // Drain the body so the connection can be reused/closed cleanly.
      await resp.drain<void>().timeout(const Duration(seconds: 5));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        sent++;
        _consecutive401 = 0;
      } else {
        dropped++;
        if (resp.statusCode == 401) {
          _consecutive401++;
          invalidateToken();
        } else if (resp.statusCode == 403) {
          // A platform-binding rejection is also a credential problem:
          // drop the cached token so a re-joined token is picked up on
          // the next send instead of after the cache TTL (reviewer
          // catch, 2026-10-21).
          invalidateToken();
        }
      }
    } catch (_) {
      dropped++;
    }
  }

  void close() {
    _closed = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}
