import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'blocked_dialog.dart';
import 'new_chat_dialog.dart';
import 'profile_dialog.dart';
import 'settings_page.dart';
import 'text_input.dart';
import 'thread_view.dart' show showPeerProfileDialog;
import 'toast.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, required this.state, this.fullWidth = false, this.searchFocus});

  final AppState state;
  final bool fullWidth;

  /// Ctrl+F lands here.
  final FocusNode? searchFocus;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _query = PlainTextEditingController();

  AppState get state => widget.state;
  bool get fullWidth => widget.fullWidth;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _query.clear();
    widget.searchFocus?.unfocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final ordered = state.ordered;
    final q = _query.text.trim();
    final hits = q.isEmpty ? const <(Conversation, ChatMessage)>[] : state.search(q);
    return Container(
      width: fullWidth ? double.infinity : 288,
      color: tc.sidebar,
      padding: EdgeInsets.fromLTRB(
          16,
          fullWidth ? MediaQuery.paddingOf(context).top + 12 : 20,
          16,
          16 + (fullWidth ? MediaQuery.paddingOf(context).bottom : 0)),
      child: LayoutBuilder(builder: (context, box) {
        final header = <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(children: [
              SvgPicture.asset('assets/logo.svg', width: 26, height: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Tincan',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700, color: tc.sidebarText)),
              ),
              if (canLockNow(state))
                IconButton(
                  tooltip: 'Lock now (Ctrl+L)',
                  constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
                  onPressed: state.lockNow,
                  icon: Icon(Icons.lock_outline, size: 18, color: tc.sidebarMuted),
                ),
              IconButton(
                tooltip: 'Settings',
                constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
                onPressed: () => showSettingsDialog(context, state),
                icon: Icon(Icons.settings_outlined, size: 18, color: tc.sidebarMuted),
              ),
            ]),
          ),
          if (state.identityConflict) ...[
            const SizedBox(height: 14),
            _ConflictBanner(),
          ],
          const SizedBox(height: 18),
          _ProfileCard(state: state),
          const SizedBox(height: 14),
          _SearchField(
            controller: _query,
            focusNode: widget.searchFocus,
            onChanged: () => setState(() {}),
            onClear: _clearSearch,
          ),
          const SizedBox(height: 14),
          if (state.requests.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('REQUESTS', style: Tc.caps(Tc.brandOrange)),
            ),
            const SizedBox(height: 8),
            // More than one collapses, so request spam can't flood
            // the sidebar.
            if (state.requests.length == 1)
              _RequestTile(state: state, request: state.requests.single)
            else
              _CollapsedRequests(state: state),
            const SizedBox(height: 14),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(children: [
              Expanded(
                child: Text(q.isEmpty ? 'CONVERSATIONS' : 'RESULTS',
                    style: Tc.caps(tc.sidebarFaint)),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
                tooltip: 'Blocked peers',
                onPressed: () => showBlockedDialog(context, state),
                icon: Icon(Icons.block, size: 15, color: tc.sidebarFaint),
              ),
            ]),
          ),
        ];
        final tiles = <Widget>[
          if (q.isNotEmpty) ...[
            if (hits.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text('No messages match.',
                    style: TextStyle(fontSize: 12, color: tc.sidebarMuted)),
              ),
            for (final (c, m) in hits)
              _SearchHit(
                key: ValueKey('hit:${c.id}:${m.id}'),
                convo: c,
                msg: m,
                query: q,
                onTap: () {
                  state.focusMessage(c.id, m.id);
                  _clearSearch();
                },
              ),
          ] else if (state.conversations.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                  'No conversations yet. Tap New chat and paste a friend\'s Tincan ID, or share yours.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: tc.sidebarMuted)),
            )
          else
            for (final c in ordered) _ConversationTile(state: state, convo: c),
        ];
        final newChat = <Widget>[
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => showNewChatDialog(context, state),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New chat',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ];
        // Short windows and large text scroll everything as one list,
        // so the fixed header can never squeeze the conversations away.
        if (box.maxHeight < 560) {
          return ListView(children: [...header, const SizedBox(height: 4), ...tiles, ...newChat]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ...header,
          const SizedBox(height: 4),
          Expanded(child: ListView(children: tiles)),
          ...newChat,
        ]);
      }),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tc.refuseBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded, size: 16, color: tc.refuseInk),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              'This Tincan ID is running on another device. Messages may go to the wrong one.',
              style: TextStyle(fontSize: 12, height: 1.4, color: tc.refuseInk)),
        ),
      ]),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField(
      {required this.controller, this.focusNode, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClear},
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: (_) => onChanged(),
        autocorrect: false,
        style: TextStyle(fontSize: 13, color: tc.sidebarText),
        cursorColor: tc.sidebarText,
        decoration: InputDecoration(
          hintText: 'Search messages',
          hintStyle: TextStyle(fontSize: 13, color: tc.sidebarMuted),
          isDense: true,
          filled: true,
          fillColor: tc.sidebarCard,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          prefixIcon: Icon(Icons.search, size: 17, color: tc.sidebarMuted),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: onClear,
                  icon: Icon(Icons.close, size: 16, color: tc.sidebarMuted),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: tc.sidebarCardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: tc.sidebarCardBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: tc.sidebarMuted),
          ),
        ),
      ),
    );
  }
}

class _SearchHit extends StatelessWidget {
  const _SearchHit(
      {super.key, required this.convo, required this.msg, required this.query, required this.onTap});

  final Conversation convo;
  final ChatMessage msg;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final text = msg.kind == MessageKind.text ? msg.body : msg.preview;
    final at = text.toLowerCase().indexOf(query.toLowerCase());
    // Start a little before the match so it's on the first line.
    final from = at > 24 ? at - 20 : 0;
    final end = (at + query.length).clamp(0, text.length);
    final base = TextStyle(fontSize: 12, height: 1.35, color: tc.sidebarMuted);
    final snippet = at < 0
        ? TextSpan(text: text, style: base)
        : TextSpan(style: base, children: [
            TextSpan(text: '${from > 0 ? '…' : ''}${text.substring(from, at)}'),
            TextSpan(
                text: text.substring(at, end),
                style: const TextStyle(fontWeight: FontWeight.w700, color: Tc.brandOrange)),
            TextSpan(text: text.substring(end)),
          ]);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(convo.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: tc.sidebarText)),
              ),
              const SizedBox(width: 8),
              Text(formatTime(msg.ts), style: TextStyle(fontSize: 10.5, color: tc.sidebarFaint)),
            ]),
            const SizedBox(height: 2),
            Text.rich(snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final id = state.selfProfile?.encode();
    // Copy takes whatever the card shows: the Tincan ID, or the error.
    final (copyText, copyToast) = switch ((id, state.startError)) {
      ((final a?, _)) => (a, 'Tincan ID copied'),
      ((_, final e?)) => (e, 'Error copied'),
      _ => (null, ''),
    };
    void copy() {
      Clipboard.setData(ClipboardData(text: copyText!));
      showToast(context, copyToast);
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tc.sidebarCard,
        border: Border.all(color: tc.sidebarCardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => showProfileDialog(context, state),
            child: Row(children: [
              ValueListenableBuilder(
                valueListenable: state.plaintext(state.selfAvatarPath),
                builder: (context, path, _) => AvatarCircle(
                  id: state.selfName,
                  initials: initialsOf(state.selfName),
                  imagePath: path,
                  size: 30,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(state.selfName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600, color: tc.sidebarText)),
                  if (state.selfStatus.isNotEmpty)
                    Text(state.selfStatus,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: tc.sidebarMuted)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(Icons.edit_outlined,
                    size: 14, color: tc.sidebarMuted, semanticLabel: 'Edit profile'),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Text('YOUR TINCAN ID', style: Tc.caps(tc.sidebarMuted)),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: InkWell(
                // Errors ellipsize into uselessness, so show the whole thing.
                onTap: copyText == null
                    ? null
                    : () => showDialog(
                          context: context,
                          builder: (context) => _IdDialog(
                              title: id != null ? 'Your Tincan ID' : 'Transport error',
                              text: copyText,
                              address: id != null ? state.selfAddress : null,
                              onCopy: copy),
                        ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    switch ((id, state.startError, state.starting)) {
                      ((final a?, _, _)) => a,
                      ((_, final e?, _)) => 'error: $e',
                      _ => 'starting…',
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Tc.mono(12, tc.sidebarAddress),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: minTap, minHeight: minTap),
              style: IconButton.styleFrom(
                backgroundColor: tc.sidebarSelected,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              tooltip: 'Copy Tincan ID',
              onPressed: copyText == null ? null : copy,
              icon: Icon(Icons.copy_outlined, size: 15, color: tc.sidebarMuted),
            ),
          ]),
        ],
      ),
    );
  }
}

class _IdDialog extends StatefulWidget {
  const _IdDialog({required this.title, required this.text, this.address, required this.onCopy});

  final String title;
  final String text;
  final String? address;
  final VoidCallback onCopy;

  @override
  State<_IdDialog> createState() => _IdDialogState();
}

class _IdDialogState extends State<_IdDialog> {
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final address = widget.address;
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(widget.text, style: Tc.mono(12.5, tc.ink).copyWith(height: 1.5)),
          if (address != null) ...[
            const SizedBox(height: 8),
            AdvancedToggle(open: _advanced, onTap: () => setState(() => _advanced = !_advanced)),
            if (_advanced) ...[
              Text('Address', style: TextStyle(fontSize: 12, color: tc.inkMuted)),
              const SizedBox(height: 4),
              SelectableText(address, style: Tc.mono(12, tc.inkMuted).copyWith(height: 1.5)),
            ],
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close', style: TextStyle(color: tc.inkMuted)),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onCopy();
          },
          child: const Text('Copy'),
        ),
      ],
    );
  }
}

/// "Advanced" disclosure row; the caller shows what it hides.
class AdvancedToggle extends StatelessWidget {
  const AdvancedToggle({super.key, required this.open, required this.onTap, this.label = 'Advanced'});

  final bool open;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minTap),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: tc.inkMuted),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12.5, color: tc.inkMuted)),
        ]),
      ),
    );
  }
}

class _CollapsedRequests extends StatelessWidget {
  const _CollapsedRequests({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Material(
      color: tc.requestBg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showRequestsDialog(context, state),
        child: Container(
          constraints: BoxConstraints(minHeight: minTap),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            border: Border.all(color: tc.requestBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.mark_chat_unread_outlined, size: 15, color: Tc.brandOrange),
            const SizedBox(width: 9),
            Expanded(
              child: Text('${state.requests.length} chat requests',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: tc.sidebarText)),
            ),
            const Text('Review',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Tc.brandOrange)),
          ]),
        ),
      ),
    );
  }
}

Future<void> showRequestsDialog(BuildContext context, AppState state) {
  return showTincanDialog(
    context,
    (context) => Dialog(
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(24),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final tc = TincanColors.of(context);
            if (state.requests.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).maybePop();
              });
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('${state.requests.length} chat requests',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, size: 18, color: tc.inkMuted),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                    'Ignore drops a request; they can ask again. Block is permanent until you undo it from blocked peers. Accept only people you expect, and compare the safety number with them.',
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: tc.inkMuted)),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in state.requests)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Material(
                            color: tc.fieldFill,
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: _RequestBody(state: state, request: r, onSidebar: false),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

Future<void> refuseRequest(BuildContext context, AppState state, ChatRequest request) async {
  if (!await confirmDialog(context,
          title: 'Block ${request.displayName}?',
          body: 'They won\'t be able to contact you again. You can undo this later from the blocked peers list.',
          action: 'Block') ||
      !context.mounted) {
    return;
  }
  await showError(context, state.blockPeer(request.peer));
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.state, required this.request});

  final AppState state;
  final ChatRequest request;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        color: tc.requestBg,
        border: Border.all(color: tc.requestBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: _RequestBody(state: state, request: request, onSidebar: true),
    );
  }
}

/// The first 8 digits, enough to compare out loud.
String shortSafetyNumber(String fp) => fp.split(' ').take(2).join(' ');

/// Who is asking, what they said and their safety number, then Accept,
/// Ignore (they can ask again) or Block (for good).
class _RequestBody extends StatelessWidget {
  const _RequestBody({required this.state, required this.request, required this.onSidebar});

  final AppState state;
  final ChatRequest request;
  final bool onSidebar;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final ink = onSidebar ? tc.sidebarText : tc.ink;
    final muted = onSidebar ? tc.sidebarMuted : tc.inkMuted;
    Widget action(String label, Color color, VoidCallback onTap) => TextButton(
          style: TextButton.styleFrom(
            foregroundColor: color,
            minimumSize: Size(0, minTap),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        AvatarCircle(id: request.peer, initials: request.initials, size: 30),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(request.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink)),
            Text(
                request.fp.isEmpty
                    ? 'wants to chat'
                    : 'Safety number ${shortSafetyNumber(request.fp)}',
                style: TextStyle(fontSize: 11, color: muted)),
          ]),
        ),
      ]),
      if (request.first.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('"${request.first}"',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.35, color: ink)),
        ),
      Wrap(alignment: WrapAlignment.end, children: [
        action('Accept', onSidebar ? tc.acceptInk : tc.directGreenInk,
            () => showError(context, state.acceptRequest(request.peer))),
        action('Ignore', muted, () => showError(context, state.ignoreRequest(request.peer))),
        action('Block', onSidebar ? tc.refuseInk : tc.danger,
            () => refuseRequest(context, state, request)),
      ]),
    ]);
  }
}

/// Words for a conversation's link state, for screen readers and tooltips.
String linkLabel(Conversation c) => c.blocked
    ? 'blocked'
    : !c.connected
        ? (c.reconnecting ? 'reconnecting' : 'offline')
        : switch (c.direct) {
            true => 'direct',
            false => 'relayed',
            null => 'connected',
          };

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.state, required this.convo});

  final AppState state;
  final Conversation convo;

  Future<void> _confirmDelete(BuildContext context) async {
    if (!await confirmDeleteConversation(context, convo.displayName) || !context.mounted) return;
    await showError(context, state.deleteConversation(convo.id));
  }

  Future<void> _confirmBlock(BuildContext context) async {
    if (!await confirmBlock(context, convo.displayName) || !context.mounted) return;
    await showError(context, state.blockPeer(convo.id));
  }

  Future<void> _menu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'profile', child: Text('View profile')),
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        PopupMenuItem(value: 'mute', child: Text(convo.muted ? 'Unmute' : 'Mute')),
        if (!convo.blocked) const PopupMenuItem(value: 'block', child: Text('Block peer')),
        const PopupMenuItem(value: 'delete', child: Text('Delete conversation')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'profile':
        await showPeerProfileDialog(context, state, convo);
      case 'rename':
        await showRenameDialog(context, state, convo);
      case 'mute':
        state.setMuted(convo.id, !convo.muted);
      case 'block':
        await _confirmBlock(context);
      case 'delete':
        await _confirmDelete(context);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: convo, builder: (context, _) => _tile(context));

  Widget _tile(BuildContext context) {
    final tc = TincanColors.of(context);
    final selected = convo.id == state.selectedId;
    final last = convo.messages.isEmpty ? null : convo.messages.last;
    final dotColor = !convo.connected
        ? tc.offline
        : convo.direct == false
            ? tc.relayAmber
            : tc.online;
    final link = linkLabel(convo);
    Offset? pressAt;
    return Material(
      color: selected ? tc.sidebarSelected : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: Semantics(
        selected: selected,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => state.select(convo.id),
          onTapDown: (d) => pressAt = d.globalPosition,
          onLongPress: () => _menu(context, pressAt ?? Offset.zero),
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              PeerAvatar(state: state, convo: convo, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(convo.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: tc.sidebarText)),
                      ),
                      if (convo.verified)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(Icons.verified, size: 13, color: tc.online, semanticLabel: 'verified'),
                        ),
                      if (convo.muted)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(Icons.notifications_off_outlined,
                              size: 13, color: tc.sidebarFaint, semanticLabel: 'muted'),
                        ),
                      const Spacer(),
                      const SizedBox(width: 8),
                      Text(last == null ? '' : formatTime(last.ts),
                          style: TextStyle(fontSize: 10.5, color: tc.sidebarFaint)),
                    ]),
                    const SizedBox(height: 2),
                    Row(children: [
                      Expanded(
                        child: Text(
                          last == null
                              ? (convo.connected ? 'Connected' : 'Not connected')
                              : '${last.outgoing ? 'You: ' : ''}${last.preview}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: tc.sidebarMuted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (convo.unread > 0)
                        Semantics(
                          label: '$link, ${convo.unread} unread',
                          excludeSemantics: true,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: tc.highlight, borderRadius: BorderRadius.circular(999)),
                            child: Text('${convo.unread}',
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Tc.brandNavy)),
                          ),
                        )
                      else
                        Semantics(
                          label: link,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                          ),
                        ),
                    ]),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Local name for a contact; empty goes back to the one they picked.
Future<void> showRenameDialog(BuildContext context, AppState state, Conversation convo) =>
    showDialog<void>(context: context, builder: (_) => _RenameDialog(state: state, convo: convo));

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.state, required this.convo});

  final AppState state;
  final Conversation convo;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = PlainTextEditingController(text: widget.convo.nickname ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final v = _name.text.trim();
    widget.state.setNickname(widget.convo.id, v.isEmpty ? null : v);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final theirs = widget.convo.name;
    return AlertDialog(
      title: const Text('Rename', style: TextStyle(fontSize: 17)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Only you see this. They call themselves "$theirs".',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: tc.inkMuted)),
        const SizedBox(height: 10),
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          autocorrect: false,
          onSubmitted: (_) => _done(),
          decoration: InputDecoration(labelText: 'Name', hintText: theirs, counterText: ''),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: tc.inkMuted))),
        FilledButton(onPressed: _done, child: const Text('Save')),
      ],
    );
  }
}

Future<bool> confirmBlock(BuildContext context, String name) => confirmDialog(context,
    title: 'Block this peer?',
    body: '$name won\'t be able to contact you again; to them you\'ll look offline. You can undo this from the blocked peers list.',
    action: 'Block');

class PeerAvatar extends StatelessWidget {
  const PeerAvatar({
    super.key,
    required this.state,
    required this.convo,
    this.size = 36,
  });

  final AppState state;
  final Conversation convo;
  final double size;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: state.plaintext(convo.avatarPath),
        builder: (context, path, _) => AvatarCircle(
          id: convo.id,
          initials: convo.initials,
          imagePath: path,
          size: size,
        ),
      );
}

/// Initials circle, or the profile picture when one is set. Decorative:
/// the name always sits next to it.
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    required this.id,
    required this.initials,
    this.imagePath,
    this.size = 34,
  });

  final String id;
  final String initials;
  final String? imagePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    return ExcludeSemantics(
      child: path == null
          ? _initials()
          : ClipOval(
              child: Image.file(File(path),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => _initials()),
            ),
    );
  }

  Widget _initials() {
    final swatch = Tc.avatarColor(id);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
      child: Text(initials,
          style: TextStyle(
              fontSize: size * 0.37,
              fontWeight: FontWeight.w600,
              color: Tc.onAvatar(swatch))),
    );
  }
}
