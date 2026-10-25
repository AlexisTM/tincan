import 'dart:async';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'emoji_picker.dart';
import 'message_actions.dart';
import 'text_input.dart';
import 'toast.dart';

/// Offline sends wait in the outbox, so only a block stops the composer.
bool canSendTo(Conversation c) => !c.blocked;

/// Texts flow while a request is pending; the peer buffers them. Files don't.
bool canAttach(Conversation c) => canSendTo(c) && !c.remotePending;

String attachBlockedReason(Conversation c) => c.blocked
    ? 'You blocked ${c.displayName}'
    : 'Files can be sent once ${c.displayName} accepts';

/// Sends files picked, pasted or dropped, if this peer can take them now.
Future<void> sendFiles(
    BuildContext context, AppState state, Conversation convo, List<String> paths) async {
  if (paths.isEmpty) return;
  if (!canAttach(convo)) return showToast(context, attachBlockedReason(convo));
  for (final path in paths) {
    await state.sendFile(convo.id, path);
  }
}

final bool _isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

class Composer extends StatefulWidget {
  const Composer({super.key, required this.state, required this.convo, this.reply});

  final AppState state;
  final Conversation convo;

  /// The message being replied to; the thread sets it, send clears it.
  final ValueNotifier<ChatMessage?>? reply;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final PlainTextEditingController _controller =
      PlainTextEditingController(text: widget.convo.draft)
    ..addListener(() => widget.convo.draft = _controller.text);
  late final _focus = FocusNode(onKeyEvent: _onKey);
  bool _showEmoji = false;

  @override
  void dispose() {
    widget.reply?.removeListener(_replyChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= 700;

  @override
  void initState() {
    super.initState();
    widget.reply?.addListener(_replyChanged);
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.reply == widget.reply) return;
    old.reply?.removeListener(_replyChanged);
    widget.reply?.addListener(_replyChanged);
  }

  void _replyChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.reply?.value != null) _focus.requestFocus();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final reply = widget.reply?.value;
    _controller.clear();
    widget.reply?.value = null;
    if (_showEmoji) setState(() => _showEmoji = false);
    _focus.requestFocus();
    final error = await widget.state.sendText(widget.convo.id, text, replyTo: reply?.id);
    if (error == null || !mounted) return;
    // Put it back so nothing typed is lost.
    if (_controller.text.isEmpty) {
      _controller.text = text;
      widget.reply?.value ??= reply;
    }
    showToast(context, error);
  }

  // Enter sends, Shift+Enter breaks the line, Esc closes the emoji
  // picker. Mobile keyboards send no key events for Enter, so there it
  // always inserts a newline.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.escape && _showEmoji) {
      setState(() => _showEmoji = false);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && widget.reply?.value != null) {
      widget.reply!.value = null;
      return KeyEventResult.handled;
    }
    if (_isDesktop &&
        e.logicalKey == LogicalKeyboardKey.keyV &&
        (keys.isControlPressed || keys.isMetaPressed) &&
        !keys.isShiftPressed) {
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    if (e.logicalKey != LogicalKeyboardKey.enter || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (canSendTo(widget.convo)) unawaited(_send());
    return KeyEventResult.handled;
  }

  /// Images and copied files go out as files; anything else pastes as text.
  Future<void> _paste() async {
    final image = await Pasteboard.image.catchError((_) => null);
    if (image != null && image.isNotEmpty) return _sendImageBytes(image, 'png');
    final files = await Pasteboard.files().catchError((_) => <String>[]);
    final local = [for (final f in files) if (File(f).existsSync()) f];
    if (local.isNotEmpty) {
      if (mounted) await sendFiles(context, widget.state, widget.convo, local);
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _replaceSelection(text);
  }

  Future<void> _sendImageBytes(Uint8List bytes, String ext) async {
    if (!mounted) return;
    if (!canAttach(widget.convo)) return showToast(context, attachBlockedReason(widget.convo));
    final ok = await _confirmImage(bytes);
    if (!ok || !mounted) return;
    final dir = await Directory.systemTemp.createTemp('tincan-paste-');
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, 'pasted-$stamp.$ext'));
    try {
      await file.writeAsBytes(bytes, flush: true);
      await widget.state.sendFile(widget.convo.id, file.path);
    } finally {
      // The bridge keeps its own sealed copy.
      await dir.delete(recursive: true).catchError((_) => dir);
    }
  }

  Future<bool> _confirmImage(Uint8List bytes) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send to ${widget.convo.displayName}?', style: const TextStyle(fontSize: 17)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 360),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Send')),
        ],
      ),
    );
    return sure == true;
  }

  void _replaceSelection(String insert) {
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  void _insertEmoji(String emoji) {
    _replaceSelection(emoji);
    // On a phone that would throw the keyboard over the picker.
    if (_wide) _focus.requestFocus();
  }

  void _toggleEmoji() {
    final open = !_showEmoji;
    setState(() => _showEmoji = open);
    if (open && !_wide) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final convo = widget.convo;
    final canSend = canSendTo(convo);
    final attach = canAttach(convo);
    final banner = convo.blocked ? null : _offlineBanner(tc, convo);
    final reply = widget.reply?.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 6, 16, 14 + MediaQuery.paddingOf(context).bottom),
      child: Column(children: [
        if (_showEmoji)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: EmojiPicker(
                  onPick: _insertEmoji, onClose: () => setState(() => _showEmoji = false)),
            ),
          ),
        ?banner,
        if (reply != null) _replyBar(tc, reply),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(
            constraints: BoxConstraints(minWidth: max(44, minTap), minHeight: max(44, minTap)),
            style: IconButton.styleFrom(
              backgroundColor: tc.field,
              disabledBackgroundColor: tc.fieldFill,
              side: BorderSide(color: tc.border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            tooltip: 'Send a file',
            onPressed: attach ? () => widget.state.attachAndSendFile(widget.convo.id) : null,
            icon: Icon(Icons.attach_file, size: 18, color: attach ? tc.inkMuted : tc.disabledInk),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              decoration: BoxDecoration(
                color: tc.field,
                border: Border.all(color: tc.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    enabled: !convo.blocked,
                    // Phones would throw the keyboard up on every thread open.
                    autofocus: _wide,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    style: TextStyle(fontSize: 13.5, color: tc.ink),
                    // Images from a phone keyboard's clipboard or GIF row.
                    contentInsertionConfiguration: ContentInsertionConfiguration(
                      allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
                      onContentInserted: (c) {
                        final data = c.data;
                        if (data == null || data.isEmpty) return;
                        final ext = c.mimeType.split('/').last.replaceAll('jpeg', 'jpg');
                        unawaited(_sendImageBytes(data, ext));
                      },
                    ),
                    // Collapsed still picks up the theme's outline borders.
                    decoration: InputDecoration.collapsed(
                      hintText: convo.blocked
                          ? 'You blocked this peer'
                          : convo.remotePending
                              ? 'Request sent. Messages are delivered once accepted'
                              : 'Message ${convo.displayName}…',
                      hintStyle: TextStyle(fontSize: 13.5, color: tc.inkFaint),
                    ).copyWith(
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none),
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
                  style: IconButton.styleFrom(
                    backgroundColor: _showEmoji ? tc.accentSoft : Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  ),
                  tooltip: _showEmoji ? 'Close emoji' : 'Emoji',
                  onPressed: convo.blocked ? null : _toggleEmoji,
                  icon: Icon(Icons.sentiment_satisfied_alt_outlined,
                      size: 20, color: _showEmoji ? tc.accent : tc.inkMuted),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            constraints: BoxConstraints(minWidth: max(46, minTap), minHeight: max(46, minTap)),
            style: IconButton.styleFrom(
              backgroundColor: tc.accent,
              disabledBackgroundColor: tc.disabled,
              shape: const CircleBorder(),
            ),
            tooltip: canSend ? 'Send' : 'You blocked ${convo.displayName}',
            onPressed: canSend ? () => unawaited(_send()) : null,
            icon: Icon(Icons.arrow_upward, size: 19, color: canSend ? tc.accentInk : tc.disabledInk),
          ),
        ]),
      ]),
    );
  }

  Widget _replyBar(TincanColors tc, ChatMessage reply) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(Icons.reply, size: 18, color: tc.inkMuted),
          const SizedBox(width: 8),
          Expanded(child: ReplyQuote(convo: widget.convo, quoted: reply)),
          IconButton(
            constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
            tooltip: 'Cancel reply',
            onPressed: () => widget.reply?.value = null,
            icon: Icon(Icons.close, size: 18, color: tc.inkMuted),
          ),
        ]),
      );

  /// Stays up while typing, unlike the hint.
  Widget? _offlineBanner(TincanColors tc, Conversation convo) {
    final text = _offlineReason(convo);
    if (text == null) return null;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tc.relayAmberBg,
          border: Border.all(color: tc.relayAmberBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: tc.relayAmberInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: tc.relayAmberInk)),
          ),
        ]),
      ),
    );
  }
}

String? _offlineReason(Conversation c) => switch (c) {
      Conversation(connected: true, awaitingDirect: true) =>
        'Waiting for a direct path. Messages will send once there is one.',
      Conversation(connected: true) => null,
      _ => 'Offline. Messages will send when ${c.displayName} is back.',
    };
