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

/// Picture picking, preview and saving shared by [ProfileDialog] and the
/// onboarding name step.
mixin ProfileEditor<T extends StatefulWidget> on State<T> {
  AppState get appState;

  String? newAvatarSource;
  String? error;
  bool busy = false;

  String? get avatarPreview =>
      newAvatarSource ?? appState.plaintextPath(appState.selfAvatarPath);

  @override
  void dispose() {
    unawaited(releasePicked(newAvatarSource));
    super.dispose();
  }

  Future<void> pickAvatar() async {
    final path = await pickFile(const [imageTypes], mimeTypes: const ['image/*']);
    if (path == null) return;
    if (!mounted) return unawaited(releasePicked(path));
    unawaited(releasePicked(newAvatarSource));
    setState(() => newAvatarSource = path);
  }

  /// True once saved; on failure [error] is set.
  Future<bool> saveProfile(
      {required String name, required String description, required String status}) async {
    setState(() {
      busy = true;
      error = null;
    });
    final err = await appState.saveProfile(
      name: name,
      description: description,
      status: status,
      newAvatarSource: newAvatarSource,
    );
    if (!mounted) return false;
    if (err != null) {
      setState(() {
        busy = false;
        error = err;
      });
    }
    return err == null;
  }
}

class _ProfileDialogState extends State<ProfileDialog> with ProfileEditor {
  late final _name = PlainTextEditingController(text: widget.state.selfName);
  late final _status = PlainTextEditingController(text: widget.state.selfStatus);
  late final _desc = PlainTextEditingController(text: widget.state.selfDescription);

  @override
  AppState get appState => widget.state;

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (await saveProfile(name: _name.text, description: _desc.text, status: _status.text) &&
        mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    // On a phone the keyboard would cover half the dialog straight away.
    final wide = isWide(context);
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
                  onPressed: busy ? null : pickAvatar,
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
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: TextStyle(fontSize: 12, height: 1.4, color: tc.danger)),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: tc.inkMuted),
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : _save,
                  child: busyOr(busy, const Text('Save')),
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
      enabled: !busy,
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
