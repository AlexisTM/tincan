import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'emoji_picker.dart';
import 'text_input.dart';

class Composer extends StatefulWidget {
  const Composer({super.key, required this.state, required this.convo});

  final AppState state;
  final Conversation convo;

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
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    widget.state.sendText(widget.convo.id, text);
    _controller.clear();
    _focus.requestFocus();
  }

  // Enter sends, Shift+Enter breaks the line. Mobile keyboards send
  // no key events for Enter, so there it always inserts a newline.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (_canSend) _send();
    return KeyEventResult.handled;
  }

  bool get _canSend => widget.convo.connected && !widget.convo.blocked;

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, emoji),
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final convo = widget.convo;
    // Texts flow while a request is pending; the peer buffers them.
    // Files don't.
    final canAttach = _canSend && !convo.remotePending;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 6, 16, 14 + MediaQuery.paddingOf(context).bottom),
      child: Column(children: [
        if (_showEmoji)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: EmojiPicker(onPick: _insertEmoji),
            ),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              style: IconButton.styleFrom(
                backgroundColor: Colors.white,
                side: const BorderSide(color: Tc.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              tooltip: 'Send a file',
              onPressed:
                  canAttach ? () => widget.state.attachAndSendFile(widget.convo.id) : null,
              icon: const Icon(Icons.attach_file, size: 18, color: Tc.inkMuted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Tc.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    enabled: !convo.blocked,
                    // Phones would throw the keyboard up on every thread open.
                    autofocus: MediaQuery.sizeOf(context).width >= 700,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 13.5),
                    // Collapsed still picks up the theme's outline borders.
                    decoration: InputDecoration.collapsed(
                      hintText: convo.blocked
                          ? 'You blocked this peer'
                          : !convo.connected
                              ? 'Not connected — you can send once they\'re back'
                              : convo.remotePending
                                  ? 'Request sent — messages are delivered once accepted'
                                  : 'Message ${convo.name}…',
                      hintStyle: const TextStyle(fontSize: 13.5, color: Tc.inkFaint),
                    ).copyWith(enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
                  ),
                ),
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      backgroundColor:
                          _showEmoji ? const Color(0xFFE2F0EF) : Colors.transparent,
                      shape:
                          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    tooltip: 'Emoji',
                    onPressed: () => setState(() => _showEmoji = !_showEmoji),
                    icon: Icon(Icons.sentiment_satisfied_alt_outlined,
                        size: 19, color: _showEmoji ? Tc.accent : Tc.inkMuted),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 46,
            height: 46,
            child: IconButton(
              style: IconButton.styleFrom(
                backgroundColor: Tc.accent,
                disabledBackgroundColor: const Color(0xFFD8C7B8),
                shape: const CircleBorder(),
              ),
              tooltip: 'Send',
              onPressed: _canSend ? _send : null,
              icon: const Icon(Icons.arrow_upward, size: 19, color: Tc.accentInk),
            ),
          ),
        ]),
      ]),
    );
  }
}
