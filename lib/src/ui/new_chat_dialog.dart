import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../files.dart';
import '../profile.dart';
import '../qr_util.dart';
import '../theme.dart';
import 'qr_scan_screen.dart';
import 'sidebar.dart' show AdvancedToggle;
import 'text_input.dart';
import 'toast.dart';

Future<void> showNewChatDialog(BuildContext context, AppState state) {
  return showTincanDialog(context, (_) => NewChatDialog(state: state));
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
  bool _advanced = false;
  String? _error;

  /// Text that came off the camera; still verified while the field holds it.
  String? _scanned;

  late String? _id = widget.state.selfProfile?.encode();
  late String? _addr = widget.state.selfAddress;
  late String _name = widget.state.selfName;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _token.dispose();
    super.dispose();
  }

  // Only what this dialog shows; any other notify would re-encode the QR.
  void _onState() {
    final s = widget.state;
    final id = s.selfProfile?.encode();
    if (id == _id && s.selfAddress == _addr && s.selfName == _name) return;
    setState(() {
      _id = id;
      _addr = s.selfAddress;
      _name = s.selfName;
    });
  }

  /// A code scanned off their screen is them, so it starts verified.
  Future<void> _connect() async {
    final input = _token.text;
    setState(() {
      _connecting = true;
      _error = null;
    });
    final err = await widget.state.connect(input, verified: input == _scanned);
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
    _scanned = scanned;
    await _connect();
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
      setState(() => _error = 'That QR code isn\'t a Tincan ID.');
      return;
    }
    _token.text = text;
    await _connect();
  }

  // mobile_scanner has no desktop implementation.
  static final bool _hasCamera = Platform.isAndroid || Platform.isIOS;

  Future<void> _saveContact() async {
    final vcard = widget.state.selfProfile?.toVCard();
    if (vcard == null) return;
    // The Android save path is joined onto a scratch dir, so no separators.
    final safe = _name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final target = await chooseSaveTarget('${safe.isEmpty ? 'Contact' : safe} (Tincan).vcf',
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
    if (!mounted) return;
    showToast(
        context,
        err != null
            ? 'Couldn\'t save the contact: $err'
            : Platform.isAndroid
                ? 'Contact saved. Import the .vcf into Google or Samsung Contacts.'
                : 'Contact saved');
  }

  Future<void> _share(String id, Rect? origin) async {
    try {
      await SharePlus.instance.share(ShareParams(
        text: id,
        subject: '$_name on Tincan',
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: id));
      if (mounted) showToast(context, 'Couldn\'t open sharing, so it was copied instead');
    }
  }

  void _copy(String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, toast);
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Dialog(
      insetPadding: EdgeInsets.all(narrow ? 14 : 40),
      child: Container(
        width: narrow ? 440 : 700,
        padding: EdgeInsets.all(narrow ? 20 : 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Start a conversation',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Text('No accounts, no sign-in. You connect straight to a peer.',
                        style: TextStyle(fontSize: 13, color: tc.inkMuted)),
                  ]),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, size: 18, color: tc.inkMuted),
                ),
              ]),
              const SizedBox(height: 22),
              if (narrow) ...[
                _connectColumn(tc),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 20),
                  color: tc.border,
                ),
                _shareColumn(tc),
              ] else
                // No IntrinsicHeight: QrImageView holds a LayoutBuilder,
                // which refuses intrinsic-size queries.
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _shareColumn(tc)),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: tc.border)),
                      ),
                      padding: const EdgeInsets.only(left: 24),
                      child: _connectColumn(tc),
                    ),
                  ),
                ]),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.only(top: 16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tc.border)),
                ),
                child: Row(children: [
                  Icon(Icons.lock_outline, size: 15, color: tc.inkMuted),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'End-to-end encrypted. Straight between devices when your networks allow it, otherwise through a relay that can\'t read your messages.',
                      style: TextStyle(fontSize: 12, color: tc.inkMuted),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shareColumn(TincanColors tc) {
    final id = _id;
    final addr = _addr;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Share your Tincan ID',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tc.qrBg,
            border: Border.all(color: tc.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: id == null
              ? SizedBox(
                  width: 148,
                  height: 148,
                  child: Center(
                      child: Text('starting…', style: TextStyle(color: tc.qrInk))))
              : Semantics(
                  label: 'QR code of your Tincan ID',
                  child: QrImageView(
                    data: id,
                    version: QrVersions.auto,
                    size: 148,
                    padding: EdgeInsets.zero,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: tc.qrInk),
                    dataModuleStyle: QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square, color: tc.qrInk),
                  ),
                ),
        ),
      ),
      const SizedBox(height: 6),
      Center(
        child: Text('$_name · scan or paste',
            style: TextStyle(fontSize: 12, color: tc.inkMuted)),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: Size.fromHeight(minTap)),
        onPressed: id == null ? null : () => _copy(id, 'Tincan ID copied'),
        icon: const Icon(Icons.copy_outlined, size: 15),
        label: const Text('Copy Tincan ID',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: Builder(
            builder: (context) => OutlinedButton.icon(
              onPressed: id == null
                  ? null
                  : () {
                      final box = context.findRenderObject() as RenderBox?;
                      final origin = box == null
                          ? null
                          : box.localToGlobal(Offset.zero) & box.size;
                      _share(id, origin);
                    },
              icon: const Icon(Icons.ios_share, size: 15),
              label: const Text('Share…', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: id == null ? null : _saveContact,
            icon: const Icon(Icons.contact_page_outlined, size: 15),
            label: const Text('Save contact…', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      ]),
      if (addr != null) ...[
        const SizedBox(height: 6),
        AdvancedToggle(open: _advanced, onTap: () => setState(() => _advanced = !_advanced)),
        if (_advanced)
          Row(children: [
            Expanded(
              child: SelectableText(addr, maxLines: 2, style: Tc.mono(11.5, tc.inkMuted)),
            ),
            IconButton(
              tooltip: 'Copy address',
              onPressed: () => _copy(addr, 'Address copied'),
              icon: Icon(Icons.copy_outlined, size: 15, color: tc.inkMuted),
            ),
          ]),
      ],
    ]);
  }

  Widget _connectColumn(TincanColors tc) {
    final tap = BoxConstraints(minWidth: minTap, minHeight: minTap);
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
        style: Tc.mono(12.5, tc.ink),
        decoration: InputDecoration(
          hintText: 'Paste their Tincan ID',
          hintStyle: TextStyle(fontSize: 13, color: tc.inkFaint),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_hasCamera)
              IconButton(
                constraints: tap,
                tooltip: 'Scan a QR code',
                onPressed: _connecting ? null : _scanQrCamera,
                icon: Icon(Icons.qr_code_scanner, size: 18, color: tc.inkMuted),
              ),
            IconButton(
              constraints: tap,
              tooltip: 'Read a QR code from an image',
              onPressed: _connecting ? null : _scanQrImage,
              icon: Icon(Icons.image_outlined, size: 18, color: tc.inkMuted),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: Size.fromHeight(minTap)),
        onPressed: _connecting ? null : _connect,
        child: busyOr(
            _connecting,
            const Text('Connect', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            size: 18),
      ),
      const SizedBox(height: 12),
      Text(
        _error ??
            'Your first message becomes a chat request they accept or refuse. Anyone with your Tincan ID can ask, so share it like a phone number.',
        style: TextStyle(fontSize: 12, height: 1.5, color: _error == null ? tc.inkMuted : tc.danger),
      ),
    ]);
  }
}
