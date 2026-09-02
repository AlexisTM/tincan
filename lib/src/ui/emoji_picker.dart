import 'package:flutter/material.dart';

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
  const EmojiPicker({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final all = [..._smileys, ..._things];
    final results =
        q.isEmpty ? null : all.where((e) => e.$2.contains(q)).map((e) => e.$1).toList();

    return Container(
      width: 296,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE6DCC9)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x24503C14), blurRadius: 32, offset: Offset(0, 12)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 32,
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Search emoji',
                hintStyle: const TextStyle(fontSize: 12, color: Tc.inkFaint),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                filled: true,
                fillColor: const Color(0xFFF3F1EC),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Tc.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (results != null) ...[
            _grid(results.isEmpty ? ['🤷'] : results),
          ] else ...[
            _label('FREQUENTLY USED'),
            _grid(_frequent),
            const SizedBox(height: 8),
            _label('SMILEYS & PEOPLE'),
            _grid([for (final e in _smileys) e.$1]),
            const SizedBox(height: 8),
            _label('GESTURES & THINGS'),
            _grid([for (final e in _things) e.$1]),
          ],
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: Tc.label)),
      );

  Widget _grid(List<String> emoji) => Wrap(
        children: [
          for (final e in emoji)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => widget.onPick(e),
              child: SizedBox(
                width: 34,
                height: 30,
                child: Center(child: Text(e, style: const TextStyle(fontSize: 17))),
              ),
            ),
        ],
      );
}
