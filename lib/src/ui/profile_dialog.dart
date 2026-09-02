import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../files.dart';
import '../models.dart' show initialsOf;
import '../theme.dart';
import 'sidebar.dart' show AvatarCircle;
import 'text_input.dart';
import 'toast.dart';

Future<void> showProfileDialog(BuildContext context, AppState state) {
  return showDialog(context: context, builder: (_) => ProfileDialog(state: state));
}

class ProfileDialog extends StatefulWidget {
  const ProfileDialog({super.key, required this.state});

  final AppState state;

  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  late final _name = PlainTextEditingController(text: widget.state.selfName);
  late final _status = PlainTextEditingController(text: widget.state.selfStatus);
  late final _desc = PlainTextEditingController(text: widget.state.selfDescription);
  String? _newAvatarSource;
  String? _note;
  bool _noteIsError = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    _desc.dispose();
    unawaited(releasePicked(_newAvatarSource));
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final path = await pickFile(const [imageTypes], mimeTypes: const ['image/*']);
    if (path == null) return;
    if (!mounted) return unawaited(releasePicked(path));
    unawaited(releasePicked(_newAvatarSource));
    setState(() => _newAvatarSource = path);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final err = await widget.state.saveProfile(
      name: _name.text,
      description: _desc.text,
      status: _status.text,
      newAvatarSource: _newAvatarSource,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _note = err;
        _noteIsError = true;
      });
    }
  }

  Future<void> _run(Future<String?> Function() op, String doneNote) async {
    setState(() => _busy = true);
    final err = await op();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = err ?? doneNote;
      _noteIsError = err != null;
    });
  }

  Future<void> _saveAccount() async {
    final target = await chooseSaveTarget('tincan-account.json',
        const [XTypeGroup(label: 'Account', extensions: ['json'])]);
    if (target == null) return;
    await _run(() => target.write(widget.state.saveAccount),
        'Account saved. The file contains your PRIVATE KEY — guard it like a password.');
  }

  Future<void> _restoreAccount() async {
    final path = await pickFile(const [
      XTypeGroup(label: 'Account', extensions: ['json'])
    ]);
    if (path == null) return;
    try {
      if (!mounted ||
          !await confirmDialog(context,
              title: 'Restore this account?',
              body: 'Your current identity is replaced by the one in the backup, and every open conversation drops. Chat history on this device stays.',
              action: 'Restore',
              destructive: false) ||
          !mounted) {
        return;
      }
      await _run(() => widget.state.restoreAccount(path), 'Account restored.');
    } finally {
      // It holds the private key in plaintext.
      await releasePicked(path);
    }
    if (mounted) {
      _name.text = widget.state.selfName;
      _status.text = widget.state.selfStatus;
      _desc.text = widget.state.selfDescription;
      setState(() {});
    }
  }

  Future<void> _saveChats() async {
    final target = await chooseSaveTarget(
        'tincan-chats.zip', const [XTypeGroup(label: 'Chats', extensions: ['zip'])]);
    if (target == null) return;
    await _run(() => target.write(widget.state.saveChats),
        'Chats saved (messages and shared media).');
  }

  Future<void> _restoreChats() async {
    final path = await pickFile(const [XTypeGroup(label: 'Chats', extensions: ['zip'])]);
    if (path == null) return;
    try {
      await _run(() => widget.state.restoreChats(path),
          'Chats restored (merged with what was here).');
    } finally {
      await releasePicked(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatarPreview =
        _newAvatarSource ?? widget.state.plaintextPath(widget.state.selfAvatarPath);
    return Dialog(
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your profile',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Peers see all of this when you connect; changes reach them live.',
                  style: TextStyle(fontSize: 12.5, color: Tc.inkMuted)),
              const SizedBox(height: 16),
              Row(children: [
                AvatarCircle(
                    id: widget.state.selfName,
                    initials: initialsOf(_name.text),
                    imagePath: avatarPreview,
                    size: 56),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickAvatar,
                  icon: const Icon(Icons.image_outlined, size: 15),
                  label: const Text('Change picture…', style: TextStyle(fontSize: 12.5)),
                ),
              ]),
              const SizedBox(height: 16),
              _field(_name, 'Nickname', maxLength: 40, autofocus: true),
              const SizedBox(height: 12),
              _field(_status, 'Status', maxLength: 80),
              const SizedBox(height: 12),
              _field(_desc, 'Description', maxLength: 300, lines: 3),
              const SizedBox(height: 18),
              Text('BACKUP', style: Tc.caps(Tc.label)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _ghostButton('Save account…', _saveAccount)),
                const SizedBox(width: 8),
                Expanded(child: _ghostButton('Restore account…', _restoreAccount)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _ghostButton('Save chats…', _saveChats)),
                const SizedBox(width: 8),
                Expanded(child: _ghostButton('Restore chats…', _restoreChats)),
              ]),
              const SizedBox(height: 6),
              const Text(
                  'The account file contains your private key. The chats file contains your history and shared media.',
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: Tc.inkFaint)),
              if (_note != null) ...[
                const SizedBox(height: 8),
                Text(_note!,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _noteIsError ? Tc.danger : Tc.inkMuted)),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Tc.inkMuted)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: busyOr(_busy, const Text('Save')),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {int maxLength = 40, int lines = 1, bool autofocus = false}) {
    return TextField(
      controller: c,
      autofocus: autofocus,
      enabled: !_busy,
      maxLength: maxLength,
      maxLines: lines,
      // A nickname is not prose. (The composing underline is the
      // controller's job, not these flags.)
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        alignLabelWithHint: true,
      ),
    );
  }

  Widget _ghostButton(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: _busy ? null : onTap,
      child: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }
}
