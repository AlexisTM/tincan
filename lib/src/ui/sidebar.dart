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
import 'toast.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.state, this.fullWidth = false});

  final AppState state;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final ordered = state.ordered;
    return Container(
      width: fullWidth ? double.infinity : 288,
      color: Tc.sidebar,
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
              const Expanded(
                child: Text('Tincan',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700, color: Tc.sidebarText)),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => showSettingsDialog(context, state),
                icon: const Icon(Icons.settings_outlined, size: 18, color: Tc.sidebarMuted),
              ),
            ]),
          ),
          const SizedBox(height: 18),
          _ProfileCard(state: state),
          const SizedBox(height: 18),
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
                child: Text('CONVERSATIONS', style: Tc.caps(Tc.sidebarFaint)),
              ),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: 'Blocked peers',
                  onPressed: () => showBlockedDialog(context, state),
                  icon: const Icon(Icons.block, size: 14, color: Tc.sidebarFaint),
                ),
              ),
            ]),
          ),
        ];
        final tiles = <Widget>[
          if (state.conversations.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                  'No conversations yet. Tap New chat and paste a friend\'s address, or share yours.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: Tc.sidebarMuted)),
            )
          else
            for (final c in ordered) _ConversationTile(state: state, convo: c),
        ];
        final newChat = <Widget>[
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => showNewChatDialog(context, state),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New chat',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final addr = state.selfAddress;
    // Copy takes whatever the card shows: the address, or the error.
    final (copyText, copyToast) = switch ((addr, state.startError)) {
      ((final a?, _)) => (a, 'Address copied'),
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
        color: Tc.sidebarCard,
        border: Border.all(color: Tc.sidebarCardBorder),
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
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Tc.sidebarText)),
                  if (state.selfStatus.isNotEmpty)
                    Text(state.selfStatus,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Tc.sidebarMuted)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.edit_outlined,
                    size: 14, color: Tc.sidebarMuted, semanticLabel: 'Edit profile'),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Text('YOUR ADDRESS', style: Tc.caps(Tc.sidebarMuted)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: InkWell(
                // Errors ellipsize into uselessness, so show the whole thing.
                onTap: copyText == null
                    ? null
                    : () => showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(addr != null ? 'Your address' : 'Transport error',
                                style: const TextStyle(fontSize: 16)),
                            content: SelectableText(copyText,
                                style: Tc.mono(12.5, Tc.ink).copyWith(height: 1.5)),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  copy();
                                },
                                child: const Text('Copy'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Close', style: TextStyle(color: Tc.inkMuted)),
                              ),
                            ],
                          ),
                        ),
                child: Text(
                  switch ((addr, state.startError, state.starting)) {
                    ((final a?, _, _)) => a,
                    ((_, final e?, _)) => 'error: $e',
                    _ => 'starting…',
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Tc.mono(12, const Color(0xFFDCE1E8)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  backgroundColor: Tc.sidebarSelected,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                tooltip: 'Copy',
                onPressed: copyText == null ? null : copy,
                icon: const Icon(Icons.copy_outlined, size: 14, color: Tc.sidebarMuted),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _CollapsedRequests extends StatelessWidget {
  const _CollapsedRequests({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF33302A),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showRequestsDialog(context, state),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF4A4436)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.mark_chat_unread_outlined, size: 15, color: Tc.brandOrange),
            const SizedBox(width: 9),
            Expanded(
              child: Text('${state.requests.length} chat requests',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: Tc.sidebarText)),
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
  return showDialog(
    context: context,
    builder: (context) => Dialog(
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(24),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
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
                    icon: const Icon(Icons.close, size: 18, color: Tc.inkMuted),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text(
                    'Refusing is permanent (undoable from blocked peers). Requests from strangers cost nothing to send — accept only people you expect.',
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: Tc.inkMuted)),
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
                            color: const Color(0xFFF3F1EC),
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(children: [
                                AvatarCircle(id: r.peer, initials: r.initials, size: 30),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(r.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      showError(context, state.acceptRequest(r.peer)),
                                  child: const Text('Accept',
                                      style: TextStyle(
                                          color: Tc.directGreenInk,
                                          fontWeight: FontWeight.w600)),
                                ),
                                TextButton(
                                  onPressed: () => refuseRequest(context, state, r),
                                  child: const Text('Refuse',
                                      style: TextStyle(
                                          color: Tc.danger,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ]),
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
          title: 'Refuse permanently?',
          body: '${request.displayName} won\'t be able to contact you again. You can undo this later from the blocked peers list.',
          action: 'Refuse') ||
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
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF33302A),
        border: Border.all(color: const Color(0xFF4A4436)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        AvatarCircle(id: request.peer, initials: request.initials, size: 30),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(request.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: Tc.sidebarText)),
            const Text('wants to chat',
                style: TextStyle(fontSize: 11, color: Tc.sidebarMuted)),
          ]),
        ),
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            padding: EdgeInsets.zero,
            tooltip: 'Accept',
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF275C48)),
            onPressed: () => showError(context, state.acceptRequest(request.peer)),
            icon: const Icon(Icons.check, size: 15, color: Color(0xFFB9E2C8)),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            padding: EdgeInsets.zero,
            tooltip: 'Refuse permanently',
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF5A302B)),
            onPressed: () => refuseRequest(context, state, request),
            icon: const Icon(Icons.close, size: 15, color: Color(0xFFE9B8B2)),
          ),
        ),
      ]),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.state, required this.convo});

  final AppState state;
  final Conversation convo;

  Future<void> _confirmDelete(BuildContext context) async {
    if (!await confirmDeleteConversation(context, convo.name) || !context.mounted) return;
    await showError(context, state.deleteConversation(convo.id));
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: convo, builder: (context, _) => _tile(context));

  Widget _tile(BuildContext context) {
    final selected = convo.id == state.selectedId;
    final last = convo.messages.isEmpty ? null : convo.messages.last;
    final dotColor = !convo.connected
        ? Tc.offline
        : convo.direct == false
            ? Tc.relayAmber
            : const Color(0xFF6FBF8F);
    return Material(
      color: selected ? Tc.sidebarSelected : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => state.select(convo.id),
        onLongPress: () => _confirmDelete(context),
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
                    Expanded(
                      child: Text(convo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Tc.sidebarText)),
                    ),
                    const SizedBox(width: 8),
                    Text(last == null ? '' : formatTime(last.ts),
                        style: const TextStyle(fontSize: 10.5, color: Tc.sidebarFaint)),
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
                        style: const TextStyle(fontSize: 12, color: Tc.sidebarMuted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (convo.unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                            color: Tc.highlight, borderRadius: BorderRadius.circular(999)),
                        child: Text('${convo.unread}',
                            style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Tc.brandNavy)),
                      )
                    else
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                      ),
                  ]),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

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

/// Initials circle, or the profile picture when one is set.
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
    if (path == null) return _initials();
    return ClipOval(
      child: Image.file(File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _initials()),
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
