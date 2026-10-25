import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'composer.dart';
import 'emoji_picker.dart';
import 'toast.dart';

const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

bool canCancelTransfer(ChatMessage m) => m.isMedia && m.status == MessageStatus.sending;

bool canRetry(ChatMessage m) => m.outgoing && m.status == MessageStatus.failed;

/// Reply, react, copy, delete, retry, cancel. A popup at [at] on desktop
/// (right-click, hover button), a bottom sheet otherwise.
Future<void> showMessageActions(
  BuildContext context, {
  required AppState state,
  required Conversation convo,
  required ChatMessage msg,
  required ValueChanged<ChatMessage> onReply,
  Offset? at,
}) async {
  final canSend = canSendTo(convo);
  final actions = <(String, IconData, String)>[
    if (canSend) ('reply', Icons.reply, 'Reply'),
    if (msg.kind == MessageKind.text) ('copy', Icons.copy_outlined, 'Copy'),
    if (canRetry(msg)) ('retry', Icons.refresh, 'Retry'),
    if (canCancelTransfer(msg)) ('cancel', Icons.close, 'Cancel transfer'),
    ('delete', Icons.delete_outline, 'Delete for me'),
  ];
  final String? choice;
  if (at != null && !isTouchPlatform) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (canSend) ...[
          _ReactRow(mine: msg.reactionOf('me')),
          const PopupMenuDivider(),
        ],
        for (final (v, icon, label) in actions)
          PopupMenuItem(
            value: v,
            child: _ActionLabel(icon: icon, label: label, danger: v == 'delete'),
          ),
      ],
    );
  } else {
    choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canSend) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _ReactButtons(mine: msg.reactionOf('me'), cell: minTap),
              ),
            ),
            const Divider(),
          ],
          for (final (v, icon, label) in actions)
            ListTile(
              onTap: () => Navigator.of(context).pop(v),
              title: _ActionLabel(icon: icon, label: label, danger: v == 'delete'),
            ),
        ]),
      ),
    );
  }
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'reply':
      onReply(msg);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: msg.body));
      if (context.mounted) showToast(context, 'Copied');
    case 'retry':
      await state.retry(convo.id, msg);
    case 'cancel':
      await state.cancelTransfer(convo.id, msg.id);
    case 'delete':
      final sure = await confirmDialog(context,
          title: 'Delete this message?',
          body: 'It goes from this device only. ${convo.displayName} keeps their copy.',
          action: 'Delete');
      if (!sure) return;
      if (msg.isMedia && (msg.status == MessageStatus.sending || msg.progress.value != null)) {
        await state.cancelTransfer(convo.id, msg.id);
      }
      await state.deleteForMe(convo.id, msg.id);
    case 'react+':
      final emoji = await pickEmoji(context);
      // react toggles, so picking mine again would clear it.
      if (emoji != null && emoji != msg.reactionOf('me')) {
        await state.react(convo.id, msg.id, emoji);
      }
    case final r when r.startsWith('react:'):
      await state.react(convo.id, msg.id, r.substring(6));
  }
}

/// The full picker in a dialog, for a reaction outside the quick row.
Future<String?> pickEmoji(BuildContext context) => showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Center(
          child: EmojiPicker(
            onPick: (e) => Navigator.of(context).pop(e),
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );

class _ActionLabel extends StatelessWidget {
  const _ActionLabel({required this.icon, required this.label, this.danger = false});

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final color = danger ? tc.danger : tc.ink;
    return Row(children: [
      Icon(icon, size: 18, color: danger ? tc.danger : tc.inkMuted),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(fontSize: 13.5, color: color)),
    ]);
  }
}

class _ReactRow extends PopupMenuEntry<String> {
  const _ReactRow({this.mine});

  final String? mine;

  @override
  double get height => 52;

  @override
  bool represents(String? value) => false;

  @override
  State<_ReactRow> createState() => _ReactRowState();
}

class _ReactRowState extends State<_ReactRow> {
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        // showMenu caps its width at 280.
        child: _ReactButtons(mine: widget.mine, cell: 36),
      );
}

/// Pops `react:` plus the emoji, or `react+` for the full picker.
class _ReactButtons extends StatelessWidget {
  const _ReactButtons({this.mine, required this.cell});

  final String? mine;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final e in quickReactions)
        Semantics(
          button: true,
          selected: e == mine,
          label: 'React $e',
          excludeSemantics: true,
          onTap: () => Navigator.of(context).pop('react:$e'),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => Navigator.of(context).pop('react:$e'),
            child: Container(
              width: cell,
              height: cell,
              alignment: Alignment.center,
              decoration: e == mine
                  ? BoxDecoration(color: tc.accentSoft, shape: BoxShape.circle)
                  : null,
              child: Text(e, style: const TextStyle(fontSize: 20)),
            ),
          ),
        ),
      IconButton(
        constraints: BoxConstraints(minWidth: cell, minHeight: cell),
        padding: EdgeInsets.zero,
        tooltip: 'More reactions',
        onPressed: () => Navigator.of(context).pop('react+'),
        icon: Icon(Icons.add_reaction_outlined, size: 20, color: tc.inkMuted),
      ),
    ]);
  }
}

/// Emoji + count under a bubble; mine is tinted, a tap toggles mine.
class ReactionChips extends StatelessWidget {
  const ReactionChips({super.key, required this.msg, required this.onToggle});

  final ChatMessage msg;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final mine = msg.reactionOf('me');
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final MapEntry(key: emoji, value: who) in msg.reactions.entries)
        if (who.isNotEmpty)
          Semantics(
            container: true,
            button: true,
            selected: emoji == mine,
            label: '$emoji ${who.length}${emoji == mine ? ', yours' : ''}',
            excludeSemantics: true,
            onTap: () => onToggle(emoji),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onToggle(emoji),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: emoji == mine ? tc.accentSoft : tc.field,
                  border: Border.all(color: emoji == mine ? tc.accent : tc.bubbleInBorder),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [BoxShadow(color: tc.shadow, blurRadius: 6, offset: const Offset(0, 2))],
                ),
                child: Text('$emoji ${who.length}',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: emoji == mine ? tc.accent : tc.ink,
                        fontWeight: emoji == mine ? FontWeight.w600 : null)),
              ),
            ),
          ),
    ]);
  }
}

/// Who wrote [m], as a quote heading.
String quoteAuthor(Conversation convo, ChatMessage m) => m.outgoing ? 'You' : convo.displayName;

/// One-line quote of the replied-to message, in a bubble or the composer.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.convo,
    required this.quoted,
    this.onTap,
    this.onDark = false,
  });

  final Conversation convo;
  final ChatMessage? quoted; // null once deleted or expired
  final VoidCallback? onTap;
  final bool onDark; // inside an outgoing bubble

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final q = quoted;
    final ink = onDark ? tc.bubbleOutInk : tc.ink;
    final soft = onDark ? tc.bubbleOutInk.withValues(alpha: 0.8) : tc.inkMuted;
    final body = Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      decoration: BoxDecoration(
        color: onDark ? tc.bubbleOutInk.withValues(alpha: 0.14) : tc.fieldFill,
        border: Border(left: BorderSide(color: onDark ? tc.bubbleOutInk : tc.accent, width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (q != null)
          Text(quoteAuthor(convo, q),
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ink)),
        Text(q == null ? 'Message not available' : _snippet(q),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, height: 1.35, color: soft, fontStyle: q == null ? FontStyle.italic : null)),
      ]),
    );
    if (q == null || onTap == null) return body;
    return Semantics(
      container: true,
      button: true,
      label: 'Quote from ${quoteAuthor(convo, q)}: ${_snippet(q)}. Show it',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap, child: body),
    );
  }

  static String _snippet(ChatMessage m) => switch (m.kind) {
        MessageKind.text => m.body.replaceAll('\n', ' '),
        MessageKind.image => '📷 ${m.name ?? 'Photo'}',
        MessageKind.video => '🎬 ${m.name ?? 'Video'}',
        MessageKind.file => '📎 ${m.name ?? 'File'}',
      };
}
