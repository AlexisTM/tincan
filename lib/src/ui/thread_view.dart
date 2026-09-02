import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'composer.dart';
import 'sidebar.dart';
import 'toast.dart';

class ThreadView extends StatelessWidget {
  const ThreadView({super.key, required this.state, required this.convo, this.onBack});

  final AppState state;
  final Conversation convo;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: convo, builder: (context, _) {
      final gutter = MediaQuery.sizeOf(context).width < 700 ? 12.0 : 28.0;
      final msgs = convo.messages;
      return Column(children: [
        _Header(state: state, convo: convo, onBack: onBack),
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Text('No messages yet — say hi to ${convo.name}.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Tc.inkMuted)),
                )
              : ListView.builder(
                  reverse: true,
                  padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final idx = msgs.length - 1 - i;
                    final msg = msgs[idx];
                    final row = Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _MessageRow(state: state, convo: convo, msg: msg),
                    );
                    if (idx > 0 && sameDay(msgs[idx - 1].ts, msg.ts)) return row;
                    return Column(children: [_DayDivider(day: msg.ts), row]);
                  },
                ),
        ),
        Composer(key: ValueKey(convo.id), state: state, convo: convo),
      ]);
    });
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Row(children: [
        const Expanded(child: Divider(color: Tc.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(formatDay(day), style: const TextStyle(fontSize: 11, color: Tc.inkFaint)),
        ),
        const Expanded(child: Divider(color: Tc.border)),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.convo, this.onBack});

  final AppState state;
  final Conversation convo;
  final VoidCallback? onBack;

  Future<void> _confirmAndBlock(BuildContext context) async {
    if (!await confirmDialog(context,
        title: 'Block this peer?',
        body: '${convo.name} won\'t be able to contact you again — to them you\'ll look offline. You can undo this from the blocked peers list.',
        action: 'Block') ||
        !context.mounted) {
      return;
    }
    showError(context, state.blockPeer(convo.id));
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    if (!await confirmDeleteConversation(context, convo.name) || !context.mounted) return;
    if (onBack != null) onBack!();
    showError(context, state.deleteConversation(convo.id));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
          left: onBack == null ? 20 : 6,
          right: 8,
          top: MediaQuery.paddingOf(context).top),
      height: 64 + MediaQuery.paddingOf(context).top,
      decoration: const BoxDecoration(
        color: Tc.panel,
        border: Border(bottom: BorderSide(color: Tc.border)),
      ),
      child: Row(children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Tc.ink),
          ),
        // One Expanded for everything left of the actions keeps them
        // pinned right whatever it holds.
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => showPeerProfileDialog(context, state, convo),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(children: [
                PeerAvatar(state: state, convo: convo),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(convo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      if (convo.statusText.isNotEmpty)
                        Text(convo.statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: Tc.inkMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: _StatusPill(convo: convo)),
              ]),
            ),
          ),
        ),
        if (convo.blocked)
          OutlinedButton(
            style: Tc.accentOutline,
            onPressed: () => showError(context, state.unblockPeer(convo.id)),
            child: const Text('Unblock'),
          )
        else if (!convo.connected && convo.token != null)
          OutlinedButton(
            style: Tc.accentOutline,
            onPressed: () => showError(context, state.reconnect(convo.id)),
            child: const Text('Reconnect'),
          ),
        PopupMenuButton<String>(
          tooltip: 'Conversation options',
          icon: const Icon(Icons.more_vert, size: 18, color: Tc.inkMuted),
          onSelected: (v) async {
            switch (v) {
              case 'profile':
                showPeerProfileDialog(context, state, convo);
              case 'block':
                await _confirmAndBlock(context);
              case 'delete':
                await _confirmAndDelete(context);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'profile',
              child: Text('View profile', style: TextStyle(fontSize: 13.5)),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete conversation', style: TextStyle(fontSize: 13.5)),
            ),
            if (!convo.blocked)
              const PopupMenuItem(
                value: 'block',
                child: Text('Block peer', style: TextStyle(fontSize: 13.5)),
              ),
          ],
        ),
      ]),
    );
  }
}

/// Read-only view of a peer's shared profile.
Future<void> showPeerProfileDialog(
    BuildContext context, AppState state, Conversation convo) {
  return showDialog(
    context: context,
    builder: (context) => Dialog(
      child: Container(
        width: 380,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              PeerAvatar(state: state, convo: convo, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(convo.name,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  if (convo.statusText.isNotEmpty)
                    Text(convo.statusText,
                        style: const TextStyle(fontSize: 12.5, color: Tc.inkMuted)),
                ]),
              ),
            ]),
            if (convo.description.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(convo.description, style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
            const SizedBox(height: 14),
            SelectableText(convo.id, style: Tc.mono(11, Tc.inkFaint)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close', style: TextStyle(color: Tc.inkMuted)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.convo});

  final Conversation convo;

  @override
  Widget build(BuildContext context) {
    if (convo.blocked) {
      return _pill(const Color(0xFFF3E4E1), const Color(0xFFE3C6C1),
          Tc.danger, const Color(0xFF8A2E24), 'Blocked');
    }
    if (convo.connected && convo.remotePending) {
      return _pill(Tc.relayAmberBg, Tc.relayAmberBorder, Tc.relayAmber,
          Tc.relayAmberInk, 'Waiting for acceptance…');
    }
    const grey = (Color(0xFFEFEDE8), Tc.border, Tc.offline, Tc.inkMuted);
    final latency = convo.latencyMs == null ? '' : ' · ${convo.latencyMs} ms';
    final ((bg, border, dot, ink), label) = switch ((convo.connected, convo.direct)) {
      (false, _) => (grey, convo.reconnecting ? 'Reconnecting…' : 'Disconnected'),
      (true, null) => (grey, 'Connected'),
      (true, true) => (
          (Tc.directGreenBg, Tc.directGreenBorder, Tc.directGreen, Tc.directGreenInk),
          'Direct${convo.pathAddr.isEmpty ? '' : ' · ${convo.pathAddr}'}$latency'
        ),
      (true, false) => (
          (Tc.relayAmberBg, Tc.relayAmberBorder, Tc.relayAmber, Tc.relayAmberInk),
          'Relay${convo.relay.isEmpty ? '' : ' (${convo.relay})'}$latency'
        ),
    };
    return _pill(bg, border, dot, ink, label);
  }

  Widget _pill(Color bg, Color border, Color dot, Color ink, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Flexible(
          child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Tc.mono(11.5, ink)),
        ),
      ]),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.state, required this.convo, required this.msg});

  final AppState state;
  final Conversation convo;
  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final maxBubble = min(460.0, MediaQuery.sizeOf(context).width * 0.72);
    final time = Text(formatClock(msg.ts), style: const TextStyle(fontSize: 11, color: Tc.inkFaint));
    final bubble = Flexible(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubble),
        child: msg.kind == MessageKind.text
            ? _TextBubble(msg: msg)
            : _MediaBubble(state: state, msg: msg, width: min(280, maxBubble - 12)),
      ),
    );
    final children = msg.outgoing
        ? [time, const SizedBox(width: 10), bubble]
        : [
            PeerAvatar(state: state, convo: convo, size: 30),
            const SizedBox(width: 10),
            bubble,
            const SizedBox(width: 10),
            time,
          ];
    return Column(
      crossAxisAlignment: msg.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: msg.outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: children,
        ),
        if (msg.status == MessageStatus.interrupted)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Text('Transfer interrupted',
                style: TextStyle(fontSize: 11, color: Tc.danger)),
          )
        else if (msg.status == MessageStatus.failed)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => state.retry(convo.id, msg),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Text('Couldn\'t send · tap to retry',
                  style: TextStyle(fontSize: 11, color: Tc.danger)),
            ),
          ),
      ],
    );
  }
}

class _TextBubble extends StatelessWidget {
  const _TextBubble({required this.msg});

  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final out = msg.outgoing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: out ? Tc.bubbleOut : Tc.bubbleIn,
        border: out ? null : Border.all(color: Tc.bubbleInBorder),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(out ? 16 : 5),
          bottomRight: Radius.circular(out ? 5 : 16),
        ),
      ),
      child: SelectableText(
        msg.body,
        style: TextStyle(fontSize: 13.5, height: 1.45, color: out ? Tc.bubbleOutInk : Tc.ink),
      ),
    );
  }
}

class _MediaBubble extends StatelessWidget {
  const _MediaBubble({required this.state, required this.msg, required this.width});

  final AppState state;
  final ChatMessage msg;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Tc.bubbleIn,
        border: Border.all(color: Tc.bubbleInBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder(
            valueListenable: msg.progress,
            builder: (context, progress, _) => _mediaBody(context, progress),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 6, 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(msg.name ?? 'file',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Tc.mono(11, Tc.inkMuted)),
              ),
              const SizedBox(width: 12),
              Text(msg.size == null ? '' : formatSize(msg.size!),
                  style: Tc.mono(11, Tc.inkFaint)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _mediaBody(BuildContext context, double? progress) {
    final sealed = msg.path;
    if (progress != null || sealed == null || msg.status != MessageStatus.sent) {
      return _placeholder(progress: progress);
    }
    if (msg.kind != MessageKind.image) {
      // Decrypted only when opened: videos and files can be big.
      return _placeholder(done: true, onOpen: () => showError(context, _open(sealed)));
    }
    return ValueListenableBuilder(
      valueListenable: state.plaintext(sealed),
      builder: (context, path, _) => path == null
          ? _placeholder()
          : ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: InkWell(
                onTap: () => showError(context, openExternal(path)),
                child: Image.file(
                  File(path),
                  width: width,
                  cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _placeholder(broken: true),
                ),
              ),
            ),
    );
  }

  Future<String?> _open(String sealed) async {
    final path = await state.decryptForOpen(sealed);
    return path == null ? 'Couldn\'t decrypt this file.' : openExternal(path);
  }

  Widget _placeholder({double? progress, bool done = false, bool broken = false, VoidCallback? onOpen}) {
    final isVideo = msg.kind == MessageKind.video;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: width,
        height: width * 0.565,
        color: isVideo ? const Color(0xFF23282F) : const Color(0xFFEFEDE8),
        child: Stack(alignment: Alignment.center, children: [
          if (progress != null)
            Positioned(
              left: 20,
              right: 20,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(999),
                  color: Tc.accent,
                  backgroundColor: isVideo ? const Color(0xFF3A4049) : Tc.border,
                ),
                const SizedBox(height: 8),
                Text('${(progress * 100).round()}%',
                    style: Tc.mono(11, isVideo ? Tc.sidebarText : Tc.inkMuted)),
              ]),
            )
          else if (broken)
            const Icon(Icons.broken_image_outlined, size: 28, color: Tc.inkFaint)
          else if (isVideo && done)
            IconButton(
              onPressed: onOpen,
              tooltip: 'Play video',
              style: IconButton.styleFrom(
                backgroundColor: const Color(0x8C0F0C09),
                side: const BorderSide(color: Color(0xD9FFF7EE), width: 1.5),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 28, color: Color(0xFFF4FBFA)),
            )
          else if (done)
            IconButton(
              onPressed: onOpen,
              tooltip: 'Open file',
              icon: const Icon(Icons.insert_drive_file_outlined, size: 32, color: Tc.inkMuted),
            )
          else
            const Icon(Icons.hourglass_empty, size: 24, color: Tc.inkFaint),
        ]),
      ),
    );
  }
}

/// Opens a file with the platform's default handler; the error to
/// show, if it couldn't.
Future<String?> openExternal(String path) async {
  const failed = 'No app could open this file.';
  try {
    return (await OpenFilex.open(path)).type == ResultType.done ? null : failed;
  } catch (_) {
    return failed;
  }
}
