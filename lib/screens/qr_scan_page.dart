import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// Full-screen QR scanner for ZMeta invite codes.
///
/// Pops with the raw decoded string of the first QR found; deciding
/// whether it is actually an invite code is the caller's job
/// (zmetaInviteCodeFromScan). Backing out pops null. Android/iOS only —
/// the join dialog only offers scanning where a camera stack exists.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SentryColors.background,
      appBar: AppBar(
        backgroundColor: SentryColors.background,
        title: Text('SCAN INVITE QR',
            style: SentryType.rowValue(SentryColors.onDark)),
        actions: [
          IconButton(
            tooltip: 'TORCH',
            icon: const Icon(Icons.flashlight_on_outlined,
                color: SentryColors.muted),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'CAMERA NOT AVAILABLE HERE — GO BACK AND PASTE THE '
                  'INVITE CODE INSTEAD.',
                  style: SentryType.section(11).copyWith(height: 1.7),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Text(
              'POINT AT THE QR CODE THE HUB OPERATOR SHOWS YOU. '
              'THE CODE FILLS IN AUTOMATICALLY.',
              style: SentryType.section(10).copyWith(
                height: 1.6,
                color: SentryColors.onDark,
                shadows: const [
                  Shadow(color: Colors.black, blurRadius: 8),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
