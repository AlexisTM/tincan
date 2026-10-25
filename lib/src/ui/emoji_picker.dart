import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

const _frequent = ['😍', '🙌', '🔥', '❤️', '😂', '👍', '🫡', '🏔️'];

const _smileys = <(String, String)>[
  ('😀', 'grin happy'), ('😄', 'smile happy'), ('😅', 'sweat smile'), ('😂', 'joy laugh'),
  ('🤣', 'rofl laugh'), ('🥲', 'tear smile'), ('😊', 'blush smile'), ('😍', 'heart eyes love'),
  ('😘', 'kiss love'), ('😎', 'cool sunglasses'), ('🤩', 'star struck wow'), ('🥳', 'party celebrate'),
  ('😤', 'huff determined'), ('😴', 'sleep tired'), ('🤔', 'thinking hmm'), ('👀', 'eyes look'),
  ('😢', 'cry sad'), ('😭', 'sob cry'), ('😡', 'angry mad'), ('🤯', 'mind blown'),
  ('🙃', 'upside down'), ('😉', 'wink'), ('🤗', 'hug'), ('🤫', 'shush quiet'),
];

const _things = <(String, String)>[
  ('👍', 'thumbs up yes'), ('👎', 'thumbs down no'), ('🙌', 'hands celebrate'), ('👋', 'wave hello bye'),
  ('🫡', 'salute'), ('💪', 'strong flex'), ('🙏', 'thanks please'), ('👏', 'clap'),
  ('❤️', 'heart love'), ('💔', 'broken heart'), ('🔥', 'fire lit'), ('✨', 'sparkles'),
  ('🎉', 'party confetti'), ('⚡', 'zap lightning'), ('🏔️', 'mountain'), ('🌄', 'sunrise'),
  ('📷', 'camera photo'), ('🎬', 'movie video'), ('🐈', 'cat'), ('🐕', 'dog'),
  ('☕', 'coffee'), ('🍕', 'pizza'), ('🚀', 'rocket ship'), ('✅', 'check done'),
];

class EmojiPicker extends StatefulWidget {
  const EmojiPicker({super.key, required this.onPick, this.onClose});

  final ValueChanged<String> onPick;
  final VoidCallback? onClose;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final q = _query.trim().toLowerCase();
    final all = [..._smileys, ..._things];
    final results =
        q.isEmpty ? null : all.where((e) => e.$2.contains(q)).map((e) => e.$1).toList();
    // Whole rows of touch-sized cells, as wide as the screen allows.
    final cell = minTap;
    final room = MediaQuery.sizeOf(context).width - 32 - 24;
    final cols = (room / cell).floor().clamp(5, 8);

    return CallbackShortcuts(
      bindings: {
        if (widget.onClose != null)
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose!,
      },
      child: Container(
        width: cols * cell + 24,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tc.field,
          border: Border.all(color: tc.border),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: tc.shadow, blurRadius: 32, offset: const Offset(0, 12))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 13, color: tc.ink),
              decoration: InputDecoration(
                hintText: 'Search emoji',
                hintStyle: TextStyle(fontSize: 13, color: tc.inkFaint),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                filled: true,
                fillColor: tc.fieldFill,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: tc.border),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (results != null) ...[
                    _grid(results.isEmpty ? ['🤷'] : results, cell),
                  ] else ...[
                    _label('FREQUENTLY USED', tc),
                    _grid(_frequent, cell),
                    const SizedBox(height: 8),
                    _label('SMILEYS & PEOPLE', tc),
                    _grid([for (final e in _smileys) e.$1], cell),
                    const SizedBox(height: 8),
                    _label('GESTURES & THINGS', tc),
                    _grid([for (final e in _things) e.$1], cell),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, TincanColors tc) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 1, color: tc.label)),
      );

  Widget _grid(List<String> emoji, double cell) => Wrap(
        children: [
          for (final e in emoji)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => widget.onPick(e),
              child: SizedBox(
                width: cell,
                height: cell,
                child: Center(child: Text(e, style: const TextStyle(fontSize: 20))),
              ),
            ),
        ],
      );
}
