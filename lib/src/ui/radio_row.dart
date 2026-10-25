import 'package:flutter/material.dart';

import '../theme.dart';

/// A titled radio option with a blurb; sits under a [RadioGroup].
class RadioRow<T> extends StatelessWidget {
  const RadioRow({
    super.key,
    required this.value,
    required this.title,
    required this.blurb,
    required this.onTap,
  });

  final T value;
  final String title;
  final String blurb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Radio<T>(value: value, activeColor: tc.accent),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              if (blurb.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(blurb, style: TextStyle(fontSize: 12, height: 1.45, color: tc.inkMuted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
