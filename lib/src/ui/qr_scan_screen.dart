import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../profile.dart';
import '../theme.dart';

/// Camera QR scanner, popping with the scanned text or null. Codes that
/// aren't Tincan IDs are ignored rather than failing a connect.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      if (parseConnectInput(raw) == null) {
        if (mounted) setState(() => _hint = 'That QR code isn\'t a Tincan ID.');
        continue;
      }
      _done = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Over a camera feed, so always the dark palette.
    const tc = TincanColors.dark;
    return Scaffold(
      backgroundColor: tc.videoBg,
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Tincan needs camera access to scan codes. Allow it in system settings, or go back and use a QR image instead.'
                    : 'The camera couldn\'t start. Go back and use a QR image instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: tc.inkMuted, fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: tc.ink.withValues(alpha: 0.9), width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.arrow_back, color: tc.ink),
                tooltip: 'Back',
              ),
              Expanded(
                child: Text('Scan a Tincan QR',
                    style: TextStyle(color: tc.ink, fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                onPressed: () => _controller.toggleTorch(),
                icon: Icon(Icons.flashlight_on_outlined, color: tc.ink),
                tooltip: 'Torch',
              ),
              IconButton(
                onPressed: () => _controller.switchCamera(),
                icon: Icon(Icons.cameraswitch_outlined, color: tc.ink),
                tooltip: 'Switch camera',
              ),
            ]),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Text(
                _hint ?? 'Point the camera at the other phone\'s code.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _hint == null ? tc.inkMuted : tc.dangerInk, fontSize: 13),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
