/// ZMeta invite-code pairing ("Join network") — mesh side.
///
/// A hub operator generates a single-use invite code. The mesh operator
/// pastes it here; this service validates the code, generates a local
/// X25519 keypair (the private key NEVER leaves the device), redeems the
/// code against the hub's pairing endpoint, and builds the WireGuard
/// .conf the operator activates in the WireGuard app.
///
/// TLS is DUAL-MODE, selected by the invite code's certfp field:
/// - 64-hex fingerprint (direct pin mode): the hub serves pairing over
///   TLS with a self-signed cert. The client uses an EMPTY trust store,
///   so default verification fails for EVERY cert and the
///   badCertificateCallback pin — sha256(cert.der) == fingerprint — is
///   the SOLE gate. Even a compromised CA or a proxy CA installed on
///   the device cannot impersonate the hub.
/// - "-" (Cloudflare mode): the hub sits behind cloudflared and the
///   pairing endpoint is ordinary public HTTPS. The client does normal
///   public-CA verification of the hub's domain; the 256-bit single-use
///   token in the POST body is the credential. Tradeoff: this trusts
///   the public CA system and the Cloudflare edge (the edge sees the
///   token), but a stolen token only lets an attacker race the
///   legitimate redeem — and the loser's redeem fails loudly ("used"),
///   so interception is noisy and detectable in the hub's pairing.log.
///
/// Security posture (mirrors the hub contract):
/// - The private key is generated on-device and never transmitted.
/// - Nothing here enables ZMeta export by itself; the operator still
///   toggles export on explicitly in Settings.
///
/// Pure Dart (dart:io + package:crypto + package:cryptography) — no
/// Flutter imports — so it stays unit-testable.
library zmeta_pairing;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'zmeta_adapter.dart' show zmetaIsLocalHost;

/// Invite code format:
///   Z1.<hub_host>.<pair_port>.<wg_port>.<token_b64url>.<certfp>
/// Parsed right-to-left because hub_host itself may contain dots.
/// certfp is "-" (Cloudflare / public-CA mode) or 64 hex chars
/// (direct self-signed pin mode).
class ZmetaInvite {
  const ZmetaInvite({
    required this.hubHost,
    required this.pairPort,
    required this.wgPort,
    required this.token,
    required this.certFpHex,
  });

  final String hubHost;
  final int pairPort;
  final int wgPort;

  /// 43-char base64url single-use token.
  final String token;

  /// "-" for Cloudflare/public-CA mode, or 64 lowercase hex chars:
  /// SHA-256 of the pairing server's TLS cert (direct pin mode).
  final String certFpHex;

  String get redeemUrl => 'https://$hubHost:$pairPort/redeem';
}

/// Human-readable pairing failure. [message] is safe to show verbatim.
class ZmetaPairingException implements Exception {
  ZmetaPairingException(this.message);
  final String message;
  @override
  String toString() => 'ZmetaPairingException: $message';
}

/// Platform IDs are hub-scoped identities: lowercase, digits, dashes.
bool zmetaIsValidPlatformId(String s) =>
    RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(s);

/// Extracts a valid invite code from scanned QR text. Hub operators
/// may QR the bare code or a line of text containing it (e.g. a label
/// or URL), so this scans for the `Z1.` token and takes the run of
/// code characters that follows. Returns the code only when it fully
/// parses — a QR that is not a Shepherd invite yields null, never a
/// partially-trusted string.
String? zmetaInviteCodeFromScan(String raw) {
  final start = raw.indexOf('Z1.');
  if (start < 0) return null;
  final rest = raw.substring(start);
  final end = rest.indexOf(RegExp(r'[\s"<>&]'));
  final candidate = (end < 0 ? rest : rest.substring(0, end)).trim();
  try {
    parseInviteCode(candidate);
    return candidate;
  } on ZmetaPairingException {
    return null;
  }
}

/// Strict invite-code parse. Throws [ZmetaPairingException] with a
/// human-readable reason on any deviation.
ZmetaInvite parseInviteCode(String raw) {
  final code = raw.trim();
  if (code.isEmpty) {
    throw ZmetaPairingException('Paste the invite code first.');
  }
  if (!code.startsWith('Z1.')) {
    throw ZmetaPairingException(
        'Not a ZMeta invite code — it must start with "Z1.".');
  }
  final parts = code.substring(3).split('.');
  // Minimum: host(1+) + pairPort + wgPort + token + certfp = 5 parts.
  if (parts.length < 5) {
    throw ZmetaPairingException(
        'Invite code is truncated — ${parts.length} sections, need at least 5.');
  }
  final certFp = parts.removeLast();
  final token = parts.removeLast();
  final wgPortS = parts.removeLast();
  final pairPortS = parts.removeLast();
  final host = parts.join('.');

  if (certFp != '-' && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(certFp)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: certificate fingerprint must be "-" '
        '(Cloudflare mode) or 64 hex characters (direct pin mode).');
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: token must be 43 base64url characters.');
  }
  final pairPort = int.tryParse(pairPortS);
  final wgPort = int.tryParse(wgPortS);
  if (pairPort == null || pairPort < 1 || pairPort > 65535) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad pairing port "$pairPortS".');
  }
  if (wgPort == null || wgPort < 1 || wgPort > 65535) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad WireGuard port "$wgPortS".');
  }
  if (host.isEmpty ||
      !RegExp(r'^[A-Za-z0-9.:\-_]+$').hasMatch(host)) {
    throw ZmetaPairingException(
        'Invite code is corrupt: bad hub address.');
  }
  return ZmetaInvite(
    hubHost: host,
    pairPort: pairPort,
    wgPort: wgPort,
    token: token,
    certFpHex: certFp.toLowerCase(),
  );
}

/// Generates an X25519 keypair for WireGuard. Returns standard-base64
/// (44-char) public and private keys. The private key stays on-device.
Future<({String publicB64, String privateB64})> zmetaGenerateWgKeypair() async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final privateBytes = await keyPair.extractPrivateKeyBytes();
  return (
    publicB64: base64.encode(publicKey.bytes),
    privateB64: base64.encode(privateBytes),
  );
}

/// Builds the WireGuard .conf the operator scans/imports in the
/// WireGuard app.
///
/// N11: the tunnel IP comes from the hub over the network — validate it
/// is a plain IPv4 dotted-quad before embedding it, so a compromised or
/// buggy hub cannot inject config text (e.g. newlines) into the .conf.
String zmetaBuildWgConf({
  required String privateKeyB64,
  required String tunnelIp,
  required String hubPubkey,
  required String hubEndpoint,
}) {
  final octets = tunnelIp.split('.');
  final ipOk = octets.length == 4 &&
      octets.every((o) {
        final n = int.tryParse(o);
        // o == '$n' rejects leading zeros, whitespace, empty, "+1", etc.
        return n != null && n >= 0 && n <= 255 && o == '$n';
      });
  if (!ipOk) {
    throw ZmetaPairingException(
        'Hub returned a bad tunnel address "$tunnelIp". Ask the hub '
        'operator to check the pairing service.');
  }
  return '[Interface]\n'
      'PrivateKey = $privateKeyB64\n'
      'Address = $tunnelIp/32\n'
      '\n'
      '[Peer]\n'
      'PublicKey = $hubPubkey\n'
      'Endpoint = $hubEndpoint\n'
      'AllowedIPs = 10.99.0.0/24\n'
      'PersistentKeepalive = 25\n';
}

/// Splits a "host:port" zmeta_target into parts. Null when unparseable.
({String host, int port})? zmetaParseTarget(String target) {
  final t = target.trim();
  final idx = t.lastIndexOf(':');
  if (idx <= 0) return null;
  final host = t.substring(0, idx).replaceAll(RegExp(r'^\[|\]$'), '');
  final port = int.tryParse(t.substring(idx + 1));
  if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// Validates a hub-supplied ingest URL. Returns the normalized URL.
///
/// Rules: must be a valid absolute URI with a non-empty host; scheme
/// must be https, or http ONLY when the host is loopback (local
/// testing / cloudflared-on-localhost deployments where TLS terminates
/// at the edge). Throws [ZmetaPairingException] with a human-readable
/// reason otherwise.
String zmetaValidateIngestUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) {
    throw ZmetaPairingException('The hub did not provide an ingest URL.');
  }
  Uri uri;
  try {
    uri = Uri.parse(t);
  } catch (_) {
    throw ZmetaPairingException('The hub provided a malformed ingest URL.');
  }
  if (!uri.isAbsolute || uri.host.isEmpty) {
    throw ZmetaPairingException('The hub provided a malformed ingest URL.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') {
    return uri.toString();
  }
  if (scheme == 'http' && zmetaIsLocalHost(uri.host)) {
    return uri.toString();
  }
  throw ZmetaPairingException(
      'The hub\'s ingest URL must be HTTPS (plain HTTP is only allowed '
      'for local testing).');
}

/// Non-throwing version of [zmetaValidateIngestUrl] for the emit gate.
bool zmetaIsUsableIngestUrl(String raw) {
  try {
    zmetaValidateIngestUrl(raw);
    return true;
  } catch (_) {
    return false;
  }
}

/// Validates a hub-supplied ingest bearer token. The token is opaque —
/// the hub mints it — so this only rejects empty/whitespace/control
/// garbage, never a well-formed token.
String zmetaValidateIngestToken(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.length < 16 || RegExp(r'\s').hasMatch(t)) {
    throw ZmetaPairingException(
        'The hub provided an unusable ingest credential. Ask the hub '
        'operator to check the pairing service.');
  }
  return t;
}

/// Hub's successful redeem response.
class ZmetaRedeemResult {
  const ZmetaRedeemResult({
    required this.tunnelIp,
    required this.hubPubkey,
    required this.hubEndpoint,
    required this.zmetaTarget,
    required this.reloadNeeded,
    this.ingestUrl = '',
    this.ingestToken = '',
  });

  final String tunnelIp;
  final String hubPubkey;
  final String hubEndpoint;
  final String zmetaTarget;

  /// Hub accepted the join but its tunnel needs a manual reactivate —
  /// the operator must ask the hub operator to reactivate it.
  final bool reloadNeeded;

  /// HTTPS ingest endpoint (no-WireGuard path). Empty when the hub
  /// predates it — then the join falls back to the WireGuard flow.
  final String ingestUrl;

  /// Bearer token for [ingestUrl]. Stored in secure storage by the UI
  /// layer, never in SharedPreferences. Empty when absent.
  final String ingestToken;
}

String zmetaFingerprintHex(X509Certificate cert) => sha256
    .convert(cert.der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Maps a hub {ok:false, error} string to a human-readable message.
String zmetaHumanizeHubError(String error) {
  final e = error.toLowerCase();
  if (e.contains('expired')) {
    return 'This invite code has expired. Ask the hub operator for a fresh one.';
  }
  if (e.contains('used') || e.contains('redeemed') || e.contains('consumed')) {
    return 'This invite code was already used. Codes are single-use — ask the hub operator for a new one.';
  }
  if (e.contains('rate') || e.contains('too many')) {
    return 'Too many attempts — the hub is rate-limiting. Wait a minute and try again.';
  }
  // N1: explicit mappings for the hub's specific validation errors.
  if (e.contains('bad_platform_id')) {
    return 'That platform ID is invalid — use 1–32 chars: lowercase a–z, 0–9, dashes.';
  }
  if (e.contains('bad_pubkey')) {
    return 'The hub rejected this device\u2019s key. Start the join over to generate a fresh keypair.';
  }
  if (e.contains('pool_exhausted')) {
    return 'The hub is out of tunnel addresses. Ask the hub operator to expand the pool.';
  }
  if (e.contains('provision_failed')) {
    return 'The hub hit a disk/config error while provisioning — your invite code is still valid. Ask the hub operator to check the hub, then try again.';
  }
  if (e.contains('state_corrupt')) {
    return 'The hub\u2019s pairing state is unreadable. Ask the hub operator to check pairing_state.json.';
  }
  if (e.contains('platform') &&
      (e.contains('taken') ||
          e.contains('exists') ||
          e.contains('duplicate') ||
          e.contains('registered'))) {
    return 'That platform ID is already registered on this hub. Change the platform ID and try again.';
  }
  if (e.contains('token') || e.contains('invalid') || e.contains('unknown')) {
    return 'The hub rejected the invite code. Check for typos, or ask the hub operator for a new code.';
  }
  return 'The hub refused the join: $error';
}

/// Redeems an invite code against the hub.
///
/// TLS is dual-mode (see library docs):
/// - 64-hex fingerprint: pin mode — HttpClient with an EMPTY trust
///   store, so default verification fails for every cert and the
///   badCertificateCallback pin is the sole gate. Any mismatch throws
///   with an explicit MITM warning.
/// - "-": Cloudflare mode — plain HttpClient() with system roots;
///   normal public-CA verification of the hub's domain.
/// 10 s timeouts throughout.
Future<ZmetaRedeemResult> zmetaRedeemInvite({
  required ZmetaInvite invite,
  required String publicKeyB64,
  required String platformId,
}) async {
  if (!zmetaIsValidPlatformId(platformId)) {
    throw ZmetaPairingException(
        'Platform ID must be 1–32 chars: lowercase a-z, 0-9, dashes.');
  }
  final bool pinMode = invite.certFpHex != '-';
  // Pin mode: SecurityContext() has an EMPTY trust store
  // (withTrustedRoots:false), so default verification fails for EVERY
  // cert and the callback below becomes the sole gate. Cloudflare
  // mode: plain HttpClient() — system roots, normal CA verification.
  final client = pinMode
      ? HttpClient(context: SecurityContext())
      : HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);
  if (pinMode) {
    // Certificate pinning: accept ONLY the exact fingerprint from the
    // invite code. This callback fires because default verification
    // always fails against the empty trust store (the hub uses a
    // self-signed cert); returning false aborts the handshake.
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) =>
            zmetaFingerprintHex(cert) == invite.certFpHex;
  }
  String tlsFailMsg() => pinMode
      ? 'TLS CERTIFICATE MISMATCH — the hub presented a certificate '
          'that does not match the invite code. Possible interception. '
          'STOPPED. Do not proceed; contact the hub operator out-of-band.'
      : 'TLS VERIFICATION FAILED — the hub\'s certificate is not trusted '
          'by this device. Cloudflare mode needs a valid public cert on '
          'the hub domain. STOPPED. Do not proceed; contact the hub '
          'operator out-of-band.';
  try {
    late HttpClientRequest req;
    late final Uri uri;
    try {
      // Uri constructor (not Uri.parse): brackets IPv6 hosts correctly.
      uri = Uri(scheme: 'https', host: invite.hubHost, port: invite.pairPort, path: '/redeem');
    } on ArgumentError {
      throw ZmetaPairingException(
          'Invite code has an unusable hub address "${invite.hubHost}".');
    }
    try {
      req = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 10));
    } on HandshakeException {
      // Pin mode: badCertificateCallback returned false (fingerprint
      // mismatch). Cloudflare mode: the edge cert failed CA verification.
      throw ZmetaPairingException(tlsFailMsg());
    } on SocketException {
      throw ZmetaPairingException(
          'Could not reach ${invite.hubHost}:${invite.pairPort}. Check the '
          'hub address and that the pairing service is running.');
    } on TimeoutException {
      throw ZmetaPairingException(
          'Timed out reaching the hub. Check the network and try again.');
    }
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'token': invite.token,
      'pubkey': publicKeyB64,
      'platform_id': platformId,
    }));
    late HttpClientResponse resp;
    try {
      resp = await req.close().timeout(const Duration(seconds: 10));
    } on HandshakeException {
      throw ZmetaPairingException(tlsFailMsg());
    } on SocketException {
      throw ZmetaPairingException('Lost connection to the hub mid-join.');
    } on TimeoutException {
      throw ZmetaPairingException('The hub did not answer in time.');
    }
    // S5: bound the body read too — a stalled server must not hang the
    // join forever.
    final body =
        await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    Map<String, dynamic>? doc;
    try {
      final d = jsonDecode(body);
      if (d is Map<String, dynamic>) doc = d;
    } catch (_) {}
    // The hub reports refusals as {ok:false, error} with HTTP 400/429/500,
    // so read the error body BEFORE judging the status code — otherwise
    // every specific message (expired, already used, rate limited...)
    // collapses into a generic "HTTP 400".
    if (doc == null) {
      throw ZmetaPairingException(
          'Hub returned HTTP ${resp.statusCode}. The pairing service may '
          'be misconfigured — ask the hub operator.');
    }
    if (doc['ok'] != true) {
      throw ZmetaPairingException(
          zmetaHumanizeHubError('${doc['error'] ?? 'unknown error'}'));
    }
    if (resp.statusCode != 200) {
      throw ZmetaPairingException(
          'Hub returned HTTP ${resp.statusCode}. The pairing service may '
          'be misconfigured — ask the hub operator.');
    }
    final tunnelIp = '${doc['tunnel_ip'] ?? ''}';
    final hubPubkey = '${doc['hub_pubkey'] ?? ''}';
    final hubEndpoint = '${doc['hub_endpoint'] ?? ''}';
    final zmetaTarget = '${doc['zmeta_target'] ?? ''}';
    if (tunnelIp.isEmpty || hubPubkey.isEmpty) {
      throw ZmetaPairingException(
          'Hub reply was incomplete (missing tunnel details). Ask the hub '
          'operator to check the pairing service.');
    }
    // HTTPS ingest (no-WireGuard path). Both fields are optional — hubs
    // that predate them simply don't send them, and the join falls back
    // to the WireGuard flow. Enter ingest mode ONLY when BOTH are
    // present (&&, not ||): a half-present ingest offer must never fail
    // the join — it falls back to WireGuard instead.
    var ingestUrl = '';
    var ingestToken = '';
    final rawUrl = '${doc['ingest_url'] ?? ''}';
    final rawToken = '${doc['ingest_token'] ?? ''}';
    if (rawUrl.isNotEmpty && rawToken.isNotEmpty) {
      ingestUrl = zmetaValidateIngestUrl(rawUrl);
      ingestToken = zmetaValidateIngestToken(rawToken);
    }
    // An HTTPS-only hub (no public WireGuard endpoint) is valid as long
    // as it handed out an ingest credential; the WireGuard fallback is
    // the only path that needs the endpoint.
    if (ingestToken.isEmpty && hubEndpoint.isEmpty) {
      throw ZmetaPairingException(
          'Hub reply was incomplete (missing tunnel details). Ask the hub '
          'operator to check the pairing service.');
    }
    return ZmetaRedeemResult(
      tunnelIp: tunnelIp,
      hubPubkey: hubPubkey,
      hubEndpoint: hubEndpoint,
      zmetaTarget: zmetaTarget,
      reloadNeeded: doc['reload_needed'] == true,
      ingestUrl: ingestUrl,
      ingestToken: ingestToken,
    );
  } finally {
    client.close(force: true);
  }
}
