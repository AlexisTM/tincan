import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../files.dart';
import '../models.dart' show initialsOf;
import '../theme.dart';
import 'sidebar.dart' show AvatarCircle;
import 'text_input.dart';
import 'unlock_screen.dart' show SetupSheet;

/// What peers will call you. Shown after setup, and to anyone who never
/// picked a name; the only way past it is to give one.
class NameStep extends StatefulWidget {
  const NameStep({super.key, required this.state});

  final AppState state;

  @override
  State<NameStep> createState() => _NameStepState();
}

class _NameStepState extends State<NameStep> {
  late final _name = PlainTextEditingController(text: widget.state.selfName);
  String? _picture;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    unawaited(releasePicked(_picture));
    super.dispose();
  }

  Future<void> _pickPicture() async {
    final path = await pickFile(const [imageTypes], mimeTypes: const ['image/*']);
    if (path == null) return;
    if (!mounted) return unawaited(releasePicked(path));
    unawaited(releasePicked(_picture));
    setState(() => _picture = path);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = widget.state;
    final err = await s.saveProfile(
      name: _name.text,
      description: s.selfDescription,
      status: s.selfStatus,
      newAvatarSource: _picture,
    );
    if (!mounted || err == null) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final ready = _name.text.trim().isNotEmpty && !_busy;
    return SetupSheet(
      title: 'What should people call you?',
      blurb: 'Your name and picture go to the people you chat with. You can change them later.',
      children: [
        Row(children: [
          AvatarCircle(
              id: widget.state.selfName,
              initials: initialsOf(_name.text),
              imagePath: _picture,
              size: 56),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickPicture,
            icon: const Icon(Icons.image_outlined, size: 15),
            label: Text(_picture == null ? 'Add a picture…' : 'Change picture…',
                style: const TextStyle(fontSize: 12.5)),
          ),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          autofocus: MediaQuery.sizeOf(context).width >= 700,
          enabled: !_busy,
          maxLength: 40,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(labelText: 'Your name', counterText: ''),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: TextStyle(fontSize: 12.5, color: tc.danger)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: ready ? _save : null,
          child: busyOr(
              _busy,
              const Text('Continue', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              size: 18),
        ),
      ],
    );
  }
}
