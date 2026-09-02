import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/ui/text_input.dart';

void main() {
  test('the composing region is not underlined', () {
    final c = PlainTextEditingController()
      ..value = const TextEditingValue(
        text: 'hello there',
        selection: TextSelection.collapsed(offset: 11),
        composing: TextRange(start: 6, end: 11),
      );

    final span = c.buildTextSpan(
      context: _FakeContext(),
      style: const TextStyle(fontSize: 14),
      withComposing: true,
    );

    // A plain span, not the split one Flutter builds to underline the
    // word the keyboard is still composing.
    expect(span.children, isNull);
    expect(span.text, 'hello there');
    expect(span.style?.decoration, isNot(TextDecoration.underline));
  });

  test('a stock controller does underline it (what we are avoiding)', () {
    final c = TextEditingController()
      ..value = const TextEditingValue(
        text: 'hello there',
        selection: TextSelection.collapsed(offset: 11),
        composing: TextRange(start: 6, end: 11),
      );
    final span = c.buildTextSpan(
      context: _FakeContext(),
      style: const TextStyle(fontSize: 14),
      withComposing: true,
    );
    final underlined = (span.children ?? [])
        .whereType<TextSpan>()
        .any((s) => s.style?.decoration == TextDecoration.underline);
    expect(underlined, isTrue);
  });
}

/// buildTextSpan only needs a BuildContext for theming lookups it does
/// not perform on these paths.
class _FakeContext extends StatelessElement {
  _FakeContext() : super(const _FakeWidget());
}

class _FakeWidget extends StatelessWidget {
  const _FakeWidget();
  @override
  Widget build(BuildContext context) => const SizedBox();
}
