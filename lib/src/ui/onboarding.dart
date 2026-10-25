import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart' show initialsOf;
import '../theme.dart';
import 'sidebar.dart' show AvatarCircle;
import 'profile_dialog.dart' show ProfileEditor;
import 'text_input.dart';
import 'unlock_screen.dart' show PrimaryButton, SetupSheet;

/// What peers will call you. Shown after setup, and to anyone who never
/// picked a name; the only way past it is to give one.
class NameStep extends StatefulWidget {
  const NameStep({super.key, required this.state});

  final AppState state;

  @override
  State<NameStep> createState() => _NameStepState();
}

class _NameStepState extends State<NameStep> with ProfileEditor {
  // Empty, not the fallback name, so Continue means a name was picked.
  final _name = PlainTextEditingController();

  @override
  AppState get appState => widget.state;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    final s = widget.state;
    await saveProfile(name: _name.text, description: s.selfDescription, status: s.selfStatus);
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final ready = _name.text.trim().isNotEmpty && !busy;
    return SetupSheet(
      title: 'What should people call you?',
      blurb: 'Your name and picture go to the people you chat with. You can change them later.',
      children: [
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
            label: Text(avatarPreview == null ? 'Add a picture…' : 'Change picture…',
                style: const TextStyle(fontSize: 12.5)),
          ),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          autofocus: isWide(context),
          enabled: !busy,
          maxLength: 40,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(labelText: 'Your name', counterText: ''),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: TextStyle(fontSize: 12.5, color: tc.danger)),
        ],
        const SizedBox(height: 20),
        PrimaryButton(label: 'Continue', busy: busy, onPressed: ready ? _save : null),
      ],
    );
  }
}
