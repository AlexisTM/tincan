import 'package:flutter/widgets.dart';

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
