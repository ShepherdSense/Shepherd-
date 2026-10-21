import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/zmeta_ingest_store.dart';
import '../services/zmeta_pairing.dart';
import '../theme.dart';
import 'qr_scan_page.dart';

/// Result handed back to Settings when a join succeeds. Export itself
/// is NOT enabled by the join.
class ZmetaJoinResult {
  const ZmetaJoinResult({
    required this.zmetaHost,
    required this.zmetaPort,
    required this.platformId,
    required this.linkMode,
    this.ingestUrl = '',
    this.ingestFp = '',
  });

  final String zmetaHost;
  final int zmetaPort;
  final String platformId;

  /// 'https' (no-WireGuard ingest path) or 'wireguard'.
  final String linkMode;

  /// Hub ingest endpoint for 'https' mode. Empty otherwise.
  final String ingestUrl;

  /// TLS mode for 'https' mode, from the invite code's certfp: '-'
  /// (Cloudflare / public-CA) or 64-hex (pinned self-signed).
  final String ingestFp;
}

enum _Step { input, working, success, error }

/// "Join network" dialog for ZMeta invite codes.
///
/// Flow: paste code -> local keypair -> redeem -> connected.
/// When the hub returns HTTPS ingest fields, the join needs no other
/// app: events POST straight to the hub (bearer token in secure
/// storage). Otherwise the classic WireGuard flow applies (QR + .conf
/// for the WireGuard app). Nothing here turns ZMeta export on.
class ZmetaJoinDialog extends StatefulWidget {
  const ZmetaJoinDialog({super.key, required this.initialPlatformId});

  final String initialPlatformId;

  @override
  State<ZmetaJoinDialog> createState() => _ZmetaJoinDialogState();
}

class _ZmetaJoinDialogState extends State<ZmetaJoinDialog> {
  late final TextEditingController _codeCtl;
  late final TextEditingController _platformCtl;
  _Step _step = _Step.input;
  String _error = '';
  String _conf = '';
  String _targetNote = '';
  bool _reloadNeeded = false;
  String _usedPlatformId = '';

  /// True when the hub returned HTTPS ingest fields: the no-WireGuard
  /// path. The WG config is still built (fields always come back) and
  /// offered under the collapsed advanced section.
  bool _ingestMode = false;

  /// Validated ingest URL, kept for the result handed to Settings.
  String _ingestUrl = '';

  /// Invite code's certfp ('-' or 64-hex), kept for the result handed
  /// to Settings so the emitter builds the right HttpClient (S1).
  String _ingestFp = '';

  @override
  void initState() {
    super.initState();
    _codeCtl = TextEditingController();
    _platformCtl = TextEditingController(text: widget.initialPlatformId);
  }

  Timer? _clipTimer;

  @override
  void dispose() {
    _clipTimer?.cancel();
    _codeCtl.dispose();
    _platformCtl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final platformId = _platformCtl.text.trim();
    if (!zmetaIsValidPlatformId(platformId)) {
      setState(() {
        _step = _Step.error;
        _error = 'Platform ID must be 1–32 characters: lowercase a–z, 0–9, dashes.\n'
            'Set it first, then join.';
      });
      return;
    }
    late final ZmetaInvite invite;
    try {
      invite = parseInviteCode(_codeCtl.text);
    } on ZmetaPairingException catch (e) {
      setState(() {
        _step = _Step.error;
        _error = e.message;
      });
      return;
    }
    setState(() => _step = _Step.working);
    try {
      // Keypair is generated on-device; the private half is never sent.
      final kp = await zmetaGenerateWgKeypair();
      final res = await zmetaRedeemInvite(
        invite: invite,
        publicKeyB64: kp.publicB64,
        platformId: platformId,
      );
      // HTTPS ingest path (no WireGuard): the hub issued an ingest URL
      // + bearer token. Ingest mode only when BOTH are present (&&):
      // a half-present offer falls back to WireGuard, never fails.
      // (Already validated inside zmetaRedeemInvite; validated again
      // here at the storage boundary for defense in depth.)
      var ingestMode = false;
      var ingestUrl = '';
      String? ingestTokenToStore;
      if (res.ingestUrl.isNotEmpty && res.ingestToken.isNotEmpty) {
        ingestUrl = zmetaValidateIngestUrl(res.ingestUrl);
        ingestTokenToStore = zmetaValidateIngestToken(res.ingestToken);
        ingestMode = true;
      }
      // S1: persist the invite's TLS mode so the emitter pins (or not)
      // exactly like the redeem did.
      final ingestFp = ingestMode ? invite.certFpHex : '';
      // An HTTPS-only hub has no public WireGuard endpoint: skip the
      // .conf (and hide the WireGuard section) instead of emitting a
      // config with an empty Endpoint line.
      final conf = res.hubEndpoint.isEmpty
          ? ''
          : zmetaBuildWgConf(
              privateKeyB64: kp.privateB64,
              tunnelIp: res.tunnelIp,
              hubPubkey: res.hubPubkey,
              hubEndpoint: res.hubEndpoint,
            );
      // Persist the credential only once everything above has passed, so
      // a failed join never leaves a token behind for a half-finished
      // pairing.
      if (ingestTokenToStore != null) {
        await ZmetaIngestStore.writeToken(platformId, ingestTokenToStore);
      }
      if (!mounted) return;
      setState(() {
        _conf = conf;
        _targetNote = res.zmetaTarget.isNotEmpty ? res.zmetaTarget : '—';
        _reloadNeeded = res.reloadNeeded;
        _usedPlatformId = platformId;
        _ingestMode = ingestMode;
        _ingestUrl = ingestUrl;
        _ingestFp = ingestFp;
        _step = _Step.success;
      });
    } on ZmetaPairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.error;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _step = _Step.error;
        _error = 'Unexpected failure during join. Check the network and try again.';
      });
    }
  }

  /// Opens the camera scanner and fills the invite field from the
  /// decoded QR. Non-invite QRs are rejected with a plain message —
  /// the field is only ever filled with a fully-parsed invite code.
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (raw == null || !mounted) return;
    final code = zmetaInviteCodeFromScan(raw);
    final messenger = ScaffoldMessenger.of(context);
    if (code == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('THAT QR IS NOT A SHEPHERD INVITE CODE')));
      return;
    }
    setState(() => _codeCtl.text = code);
    messenger.showSnackBar(const SnackBar(
        content:
            Text('INVITE CODE SCANNED — CHECK PLATFORM ID, THEN JOIN')));
  }

  void _done() {
    final target = zmetaParseTarget(_targetNote);
    final linkMode = _ingestMode ? 'https' : 'wireguard';
    if (linkMode == 'https') {
      // HTTPS mode needs no UDP target — the ingest URL (already in
      // secure-storage-backed settings via the join) is the target.
      Navigator.of(context).pop(ZmetaJoinResult(
        zmetaHost: '',
        zmetaPort: 0,
        platformId: _usedPlatformId,
        linkMode: linkMode,
        ingestUrl: _ingestUrl,
        ingestFp: _ingestFp,
      ));
      return;
    }
    // No usable gateway target from the hub: still record the join (the
    // platform id and WireGuard link mode); Settings keeps the host and
    // port the operator already has instead of treating this as a cancel.
    Navigator.of(context).pop(ZmetaJoinResult(
      zmetaHost: target?.host ?? '',
      zmetaPort: target?.port ?? 0,
      platformId: _usedPlatformId,
      linkMode: linkMode,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Back must not dismiss the dialog mid-redeem (the single-use invite
    // would be burned with the result discarded) or on the success
    // screen (the WireGuard private key is shown only here).
    return PopScope(
      canPop: _step == _Step.input || _step == _Step.error,
      child: AlertDialog(
      backgroundColor: SentryColors.surface2,
      title: Text('JOIN ZMETA NETWORK',
          style: SentryType.rowValue(SentryColors.onDark)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: _body()),
      ),
      actions: _actions(),
    ));
  }

  Widget _body() {
    switch (_step) {
      case _Step.input:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASTE THE INVITE CODE FROM THE HUB OPERATOR, OR SCAN ITS '
              'QR CODE. A LOCAL WIREGUARD KEYPAIR IS GENERATED ON THIS '
              'DEVICE — THE PRIVATE KEY NEVER LEAVES IT.',
              style: SentryType.section(10),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _codeCtl,
              autofocus: true,
              style: SentryType.rowValue(SentryColors.onDark)
                  .copyWith(fontFamily: SentryType.mono, fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'INVITE CODE',
                hintText: 'Z1.hub.example.com.8443.51820.…',
              ),
            ),
            // Camera scan (field ask 2026-10-20): offered only where a
            // camera scanner exists — Android/iOS. Desktop keeps paste.
            if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('SCAN QR CODE'),
                onPressed: _scan,
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _platformCtl,
              style: SentryType.rowValue(SentryColors.onDark),
              decoration: const InputDecoration(
                labelText: 'PLATFORM ID (THIS MESH)',
                hintText: 'e.g. shepherd-mesh-1',
              ),
            ),
          ],
        );
      case _Step.working:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text('GENERATING KEYPAIR, CONTACTING HUB…',
                style: SentryType.section(10)),
          ],
        );
      case _Step.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: SentryColors.red, size: 36),
            const SizedBox(height: 10),
            Text(_error,
                style: SentryType.rowValue(SentryColors.red)
                    .copyWith(height: 1.6)),
          ],
        );
      case _Step.success:
        if (_ingestMode) return _httpsSuccessBody();
        return _wgSuccessBody();
    }
  }

  /// Success when the hub issued HTTPS ingest: no second app, no QR.
  /// The WireGuard config is still offered under a collapsed advanced
  /// section for operators who prefer the tunnel.
  Widget _httpsSuccessBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline,
            color: SentryColors.green, size: 44),
        const SizedBox(height: 10),
        Text(
          'CONNECTED — NO OTHER APP NEEDED. TURN ON "EMIT ZMETA EVENTS" '
          'IN SETTINGS. EVENTS GO STRAIGHT TO THE HUB OVER ENCRYPTED HTTPS.',
          style: SentryType.section(10).copyWith(height: 1.6),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        if (_conf.isNotEmpty)
        ExpansionTile(
          title: Text('ADVANCED: USE WIREGUARD INSTEAD',
              style: SentryType.section(10)),
          subtitle: Text(
            'PREFER A VPN TUNNEL OVER DIRECT HTTPS.',
            style: SentryType.section(9),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _wgBody(),
            ),
            Align(
              alignment: Alignment.center,
              child: _copyConfButton(),
            ),
          ],
        ),
      ],
    );
  }

  /// Classic WireGuard success: QR + .conf for the WireGuard app.
  Widget _wgSuccessBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _wgBody(),
      ],
    );
  }

  Widget _wgBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (_reloadNeeded)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'HUB ACCEPTED THE JOIN BUT ITS TUNNEL NEEDS A MANUAL '
              'REACTIVATE — ASK THE HUB OPERATOR, THEN CONTINUE BELOW.',
              style: SentryType.section(10)
                  .copyWith(color: SentryColors.amber, height: 1.6),
              textAlign: TextAlign.center,
            ),
          ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: _conf,
            version: QrVersions.auto,
            size: 210,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'SCAN WITH THE WIREGUARD APP TO ACTIVATE THE TUNNEL, THEN '
          'TURN ON "EMIT ZMETA EVENTS" IN SETTINGS. '
          '${zmetaParseTarget(_targetNote) != null ? 'GATEWAY TARGET WILL BE SET TO $_targetNote' : 'THE HUB SENT NO GATEWAY TARGET — ENTER THE GATEWAY HOST AND PORT IN SETTINGS'}'
          ' — EXPORT STAYS OFF UNTIL YOU ENABLE IT.',
          style: SentryType.section(10).copyWith(height: 1.6),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: SentryColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: SentryColors.border),
          ),
          child: SelectableText(
            _conf,
            style: const TextStyle(
              fontFamily: SentryType.mono,
              fontSize: 10.5,
              color: SentryColors.onDark,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  /// Copies the WireGuard .conf to the clipboard.
  Widget _copyConfButton() {
    return TextButton.icon(
      icon: const Icon(Icons.copy, size: 16),
      label: const Text('COPY CONF'),
      onPressed: () {
        Clipboard.setData(ClipboardData(text: _conf));
        // The conf contains this device's WireGuard PRIVATE key: don't
        // leave it on the clipboard.
        _clipTimer?.cancel();
        _clipTimer = Timer(const Duration(seconds: 60), () {
          Clipboard.setData(const ClipboardData(text: ''));
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('WIREGUARD CONF COPIED — CLIPBOARD CLEARS IN 60 S')),
        );
      },
    );
  }

  List<Widget> _actions() {
    switch (_step) {
      case _Step.input:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: _join,
            child: const Text('JOIN'),
          ),
        ];
      case _Step.working:
        return [];
      case _Step.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CLOSE'),
          ),
          ElevatedButton(
            onPressed: () => setState(() => _step = _Step.input),
            child: const Text('TRY AGAIN'),
          ),
        ];
      case _Step.success:
        return [
          // HTTPS mode: the copy button lives inside the collapsed
          // "ADVANCED: USE WIREGUARD INSTEAD" section.
          if (!_ingestMode) _copyConfButton(),
          ElevatedButton(
            onPressed: _done,
            child: const Text('DONE'),
          ),
        ];
    }
  }
}
