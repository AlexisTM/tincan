import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../files.dart';
import '../models.dart' show initialsOf;
import '../theme.dart';
import 'sidebar.dart' show AvatarCircle;
import 'text_input.dart';
import 'toast.dart';

Future<void> showProfileDialog(BuildContext context, AppState state) {
  return showTincanDialog(context, (_) => ProfileDialog(state: state));
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
  String? _error;
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
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    // On a phone the keyboard would cover half the dialog straight away.
    final wide = MediaQuery.sizeOf(context).width >= 700;
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
              Text('Peers see all of this when you connect; changes reach them live.',
                  style: TextStyle(fontSize: 12.5, color: tc.inkMuted)),
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
              _field(_name, 'Nickname', maxLength: 40, autofocus: wide),
              const SizedBox(height: 12),
              _field(_status, 'Status', maxLength: 80),
              const SizedBox(height: 12),
              _field(_desc, 'Description', maxLength: 300, lines: 3),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(fontSize: 12, height: 1.4, color: tc.danger)),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: tc.inkMuted),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
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
}
