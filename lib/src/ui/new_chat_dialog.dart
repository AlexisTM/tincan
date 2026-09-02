import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../files.dart';
import '../profile.dart';
import '../qr_util.dart';
import '../theme.dart';
import 'qr_scan_screen.dart';
import 'text_input.dart';
import 'toast.dart';

Future<void> showNewChatDialog(BuildContext context, AppState state) {
  return showDialog(context: context, builder: (_) => NewChatDialog(state: state));
}

class NewChatDialog extends StatefulWidget {
  const NewChatDialog({super.key, required this.state});

  final AppState state;

  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> {
  final _token = PlainTextEditingController();
  bool _connecting = false;
  String? _error;
  String? _shareNote;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect([String? input]) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final err = await widget.state.connect(input ?? _token.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _connecting = false;
        _error = err;
      });
    }
  }

  Future<void> _scanQrCamera() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (scanned == null || !mounted) return;
    _token.text = scanned;
    await _connect(scanned);
  }

  Future<void> _scanQrImage() async {
    final path = await pickFile(const [imageTypes], mimeTypes: const ['image/*']);
    if (path == null) return;
    final text = await decodeQrFromImageFile(path);
    unawaited(releasePicked(path));
    if (!mounted) return;
    if (text == null) {
      setState(() => _error = 'No QR code found in that image.');
      return;
    }
    if (parseConnectInput(text) == null) {
      setState(() => _error = 'That QR code isn\'t a Tincan address.');
      return;
    }
    _token.text = text;
    await _connect(text);
  }

  // mobile_scanner has no desktop implementation.
  static final bool _hasCamera = Platform.isAndroid || Platform.isIOS;

  Future<void> _saveContact() async {
    final vcard = widget.state.selfProfile?.toVCard();
    if (vcard == null) return;
    final target = await chooseSaveTarget('${widget.state.selfName} (Tincan).vcf',
        const [XTypeGroup(label: 'vCard', extensions: ['vcf'])]);
    if (target == null) return;
    final err = await target.write((path) async {
      try {
        await File(path).writeAsString(vcard);
        return null;
      } on FileSystemException catch (e) {
        return e.osError?.message ?? e.message;
      }
    });
    final note = err == null
        ? 'Contact saved — import the .vcf into Google or Samsung Contacts.'
        : 'Couldn\'t save the contact: $err';
    if (mounted) setState(() => _shareNote = note);
  }

  Future<void> _regenerate() async {
    if (!await confirmDialog(context,
        title: 'Generate a new address?',
        body: 'Your current address stops working forever, and every open conversation is dropped. Anyone who only has the old address can no longer reach you.',
        action: 'New address')) {
      return;
    }
    final err = await widget.state.regenerateAddress();
    if (!mounted) return;
    setState(() => _shareNote = err ?? 'New address generated.');
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Dialog(
      insetPadding: EdgeInsets.all(narrow ? 14 : 40),
      child: Container(
        width: narrow ? 440 : 700,
        padding: EdgeInsets.all(narrow ? 20 : 28),
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Start a conversation',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      SizedBox(height: 5),
                      Text('No accounts, no sign-in — you connect straight to a peer.',
                          style: TextStyle(fontSize: 13, color: Tc.inkMuted)),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: Tc.inkMuted),
                  ),
                ]),
                const SizedBox(height: 22),
                if (narrow) ...[
                  _connectColumn(),
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(vertical: 20),
                    color: const Color(0xFFE9E5DD),
                  ),
                  _shareColumn(),
                ] else
                  // No IntrinsicHeight: QrImageView holds a LayoutBuilder,
                  // which refuses intrinsic-size queries.
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _shareColumn()),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Container(
                        decoration: const BoxDecoration(
                          border: Border(left: BorderSide(color: Color(0xFFE9E5DD))),
                        ),
                        padding: const EdgeInsets.only(left: 24),
                        child: _connectColumn(),
                      ),
                    ),
                  ]),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.only(top: 16),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFFE9E5DD))),
                  ),
                  child: const Row(children: [
                    Icon(Icons.lock_outline, size: 15, color: Tc.inkMuted),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'End-to-end encrypted. Straight between devices when your networks allow it — otherwise through a relay that can\'t read your messages.',
                        style: TextStyle(fontSize: 12, color: Tc.inkMuted),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _shareColumn() {
    final profile = widget.state.selfProfile?.encode();
    final addr = widget.state.selfAddress;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Share your profile',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Tc.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: profile == null
              ? const SizedBox(
                  width: 148, height: 148, child: Center(child: Text('starting…')))
              : QrImageView(
                  data: profile,
                  version: QrVersions.auto,
                  size: 148,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square, color: Color(0xFF1E2433)),
                  dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF1E2433)),
                ),
        ),
      ),
      const SizedBox(height: 6),
      Center(
        child: Text('${widget.state.selfName} · scan or paste',
            style: const TextStyle(fontSize: 11.5, color: Tc.inkMuted)),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 38,
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: profile == null
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: profile));
                  showToast(context, 'Profile copied');
                },
          icon: const Icon(Icons.copy_outlined, size: 14),
          label: const Text('Copy profile',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: addr == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: addr));
                    showToast(context, 'Address copied');
                  },
            child: const Text('Copy address', style: TextStyle(fontSize: 12.5)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: addr == null ? null : _saveContact,
            child: const Text('Save contact', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      TextButton.icon(
        style: TextButton.styleFrom(
            foregroundColor: Tc.danger,
            padding: const EdgeInsets.symmetric(horizontal: 8)),
        onPressed: addr == null ? null : _regenerate,
        icon: const Icon(Icons.refresh, size: 14),
        label: const Text('Generate a new address…', style: TextStyle(fontSize: 12)),
      ),
      if (_shareNote != null) ...[
        const SizedBox(height: 4),
        Text(_shareNote!,
            style: const TextStyle(fontSize: 11.5, height: 1.4, color: Tc.inkMuted)),
      ],
    ]);
  }

  Widget _connectColumn() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Connect to a peer',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      TextField(
        controller: _token,
        enabled: !_connecting,
        onSubmitted: (_) => _connect(),
        autocorrect: false,
        enableSuggestions: false,
        style: Tc.mono(12.5, Tc.ink),
        decoration: InputDecoration(
          hintText: 'tc… address or shared profile',
          hintStyle: Tc.mono(12.5, Tc.inkFaint),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 40,
        width: double.infinity,
        child: FilledButton(
          onPressed: _connecting ? null : _connect,
          child: busyOr(
              _connecting,
              const Text('Connect', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              size: 18),
        ),
      ),
      const SizedBox(height: 8),
      if (_hasCamera)
        SizedBox(
          height: 38,
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _connecting ? null : _scanQrCamera,
            icon: const Icon(Icons.qr_code_scanner, size: 15),
            label: const Text('Scan a QR code', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      if (_hasCamera) const SizedBox(height: 8),
      SizedBox(
        height: 38,
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _connecting ? null : _scanQrImage,
          icon: const Icon(Icons.image_outlined, size: 15),
          label: Text(_hasCamera ? 'Use a QR image instead…' : 'Scan a QR image…',
              style: const TextStyle(fontSize: 12.5)),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _error ??
            'Your first message becomes a chat request the other side accepts or refuses. Anyone with your address can ask — share it like a phone number.',
        style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: _error == null ? Tc.inkMuted : Tc.danger),
      ),
    ]);
  }
}
