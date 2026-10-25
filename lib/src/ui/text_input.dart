import 'package:flutter/material.dart';

import '../theme.dart';

/// A controller that doesn't underline the composing region.
///
/// Flutter underlines whatever the keyboard is still composing, and some
/// keyboards keep the whole current word composing until you hit space,
/// so everything you type looks like a spelling mistake.
class PlainTextEditingController extends TextEditingController {
  PlainTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) =>
      TextSpan(style: style, text: text);
}

InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );

/// A password box with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    required this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onSubmitted;
  final bool enabled;
  final bool autofocus;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: !_shown,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      autocorrect: false,
      enableSuggestions: false,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: _inputDecoration(widget.label).copyWith(
        suffixIcon: IconButton(
          tooltip: _shown ? 'Hide password' : 'Show password',
          onPressed: () => setState(() => _shown = !_shown),
          icon: Icon(_shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 19, color: tc.inkMuted),
        ),
      ),
    );
  }
}
