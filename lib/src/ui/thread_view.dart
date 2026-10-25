import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../files.dart';
import '../models.dart';
import '../theme.dart';
import 'composer.dart';
import 'image_viewer.dart';
import 'media_video.dart';
import 'message_actions.dart';
import 'sidebar.dart';
import 'toast.dart';

/// Consecutive messages from one side closer than this share a header.
const _groupGap = Duration(minutes: 5);

const _timerChoices = <(Duration?, String)>[
  (null, 'Off'),
  (Duration(hours: 1), '1 hour'),
  (Duration(days: 1), '1 day'),
  (Duration(days: 7), '1 week'),
];

String _timerLabel(Duration d) {
  for (final (c, label) in _timerChoices) {
    if (c == d) return label;
  }
  if (d.inDays >= 1) return '${d.inDays} d';
  if (d.inHours >= 1) return '${d.inHours} h';
  return '${max(1, d.inMinutes)} min';
}

class ThreadView extends StatefulWidget {
  const ThreadView({
    super.key,
    required this.state,
    required this.convo,
    this.onBack,
  });

  final AppState state;
  final Conversation convo;
  final VoidCallback? onBack;

  @override
  State<ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<ThreadView> {
  bool _dragging = false;
  final _reply = ValueNotifier<ChatMessage?>(null);
  final _scroll = ScrollController();
  final _flash = ValueNotifier<String?>(null);
  final _keys = <String, GlobalKey>{};
  final _mounted = <String>{};
  int _scrollGen = 0;
  Timer? _flashTimer;

  bool _searching = false;
  final _query = TextEditingController();
  List<String> _hits = const []; // message ids, newest first
  int _hit = 0;

  @override
  void initState() {
    super.initState();
    widget.state.focused.addListener(_onFocus);
    _onFocus();
  }

  @override
  void didUpdateWidget(ThreadView old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.focused.removeListener(_onFocus);
      widget.state.focused.addListener(_onFocus);
    }
    if (old.convo.id == widget.convo.id) return;
    _scrollGen++;
    _reply.value = null;
    _keys.clear();
    _mounted.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _closeSearch();
    _onFocus();
  }

  // The focus may land before this thread is built, so wait a frame.
  void _onFocus() {
    final f = widget.state.focused.value;
    if (f == null || f.$1 != widget.convo.id) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.state.focused.value != f) return;
      widget.state.focused.value = null;
      unawaited(_scrollTo(f.$2));
    });
  }

  @override
  void dispose() {
    widget.state.focused.removeListener(_onFocus);
    _flashTimer?.cancel();
    _reply.dispose();
    _scroll.dispose();
    _flash.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final paths = [
      for (final f in details.files)
        if (f is! DropItemDirectory && f.path.isNotEmpty) f.path
    ];
    if (await sendFiles(context, widget.state, widget.convo, paths)) _reply.value = null;
  }

  void _rowMounted(String id) => _mounted.add(id);

  void _rowUnmounted(String id) {
    _mounted.remove(id);
    _keys.remove(id);
  }

  /// Scrolls the lazily built list until [id] is on screen, then flashes it.
  Future<void> _scrollTo(String id) async {
    final gen = ++_scrollGen;
    final msgs = widget.convo.messages;
    final index = {for (var j = 0; j < msgs.length; j++) msgs[j].id: j};
    final target = index[id];
    if (target == null) return;
    for (var i = 0; i < 400 && mounted && gen == _scrollGen; i++) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        _flashTimer?.cancel();
        _flash.value = id;
        _flashTimer = Timer(const Duration(milliseconds: 1400), () => _flash.value = null);
        await Scrollable.ensureVisible(ctx,
            alignment: 0.5, duration: const Duration(milliseconds: 250));
        return;
      }
      if (!_scroll.hasClients) return;
      var oldest = -1;
      for (final m in _mounted) {
        final j = index[m];
        if (j != null && (oldest < 0 || j < oldest)) oldest = j;
      }
      // Reversed list: older messages sit further along.
      final older = oldest < 0 || target < oldest;
      final pos = _scroll.position;
      final step = pos.viewportDimension * 0.8;
      final to = (pos.pixels + (older ? step : -step)).clamp(0.0, pos.maxScrollExtent);
      if (to == pos.pixels) return;
      _scroll.jumpTo(to);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    if (!_searching) return;
    setState(() {
      _searching = false;
      _query.clear();
      _hits = const [];
      _hit = 0;
    });
  }

  List<String> _matches(String q) {
    final needle = q.trim().toLowerCase();
    final msgs = widget.convo.messages;
    if (needle.isEmpty) return const [];
    return [
      for (var i = msgs.length - 1; i >= 0; i--)
        if (msgs[i].body.toLowerCase().contains(needle) ||
            (msgs[i].isMedia && (msgs[i].name?.toLowerCase().contains(needle) ?? false)))
          msgs[i].id
    ];
  }

  void _search(String q) {
    setState(() {
      _hits = _matches(q);
      _hit = 0;
    });
    if (_hits.isNotEmpty) unawaited(_scrollTo(_hits.first));
  }

  // Messages arrive, expire and get deleted under an open search.
  void _refreshHits() {
    final hits = _matches(_query.text);
    if (listEquals(hits, _hits)) return;
    final at = _hits.isEmpty ? null : _hits[_hit];
    final keep = at == null ? -1 : hits.indexOf(at);
    _hits = hits;
    _hit = keep < 0 ? 0 : keep;
  }

  void _step(int by) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + by) % _hits.length);
    unawaited(_scrollTo(_hits[_hit]));
  }

  @override
  Widget build(BuildContext context) {
    final convo = widget.convo;
    final peerError = widget.state.peerError(convo.id);
    final thread = ListenableBuilder(listenable: convo, builder: (context, _) {
      final tc = TincanColors.of(context);
      final gutter = isWide(context) ? 28.0 : 12.0;
      final msgs = convo.messages;
      if (_searching) _refreshHits();
      return Column(children: [
        _Header(
            state: widget.state, convo: convo, onBack: widget.onBack, onSearch: _openSearch),
        if (_searching) _searchBar(tc),
        if (peerError != null) _ErrorBanner(text: peerError),
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No messages yet. Say hi to ${convo.displayName}.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: tc.inkMuted)),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final idx = msgs.length - 1 - i;
                    final msg = msgs[idx];
                    final next = idx + 1 < msgs.length ? msgs[idx + 1] : null;
                    final groupedWithNext = next != null &&
                        next.outgoing == msg.outgoing &&
                        sameDay(next.ts, msg.ts) &&
                        next.ts.difference(msg.ts) < _groupGap;
                    final row = Padding(
                      key: _keys.putIfAbsent(msg.id, GlobalKey.new),
                      padding: EdgeInsets.only(
                          bottom: (groupedWithNext ? 3 : 14) + (msg.reactions.isEmpty ? 0 : 6)),
                      child: _Tracked(
                        id: msg.id,
                        onMount: _rowMounted,
                        onUnmount: _rowUnmounted,
                        child: ValueListenableBuilder(
                          valueListenable: _flash,
                          builder: (context, flash, child) => AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            decoration: BoxDecoration(
                              color: flash == msg.id
                                  ? tc.highlight.withValues(alpha: 0.14)
                                  : tc.highlight.withValues(alpha: 0),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: child,
                          ),
                          child: _MessageRow(
                            state: widget.state,
                            convo: convo,
                            msg: msg,
                            lastInGroup: !groupedWithNext,
                            showStatus: !groupedWithNext || next.status != msg.status,
                            onReply: (m) => _reply.value = m,
                            onJump: (id) => widget.state.focusMessage(convo.id, id),
                          ),
                        ),
                      ),
                    );
                    if (idx > 0 && sameDay(msgs[idx - 1].ts, msg.ts)) return row;
                    return Column(children: [_DayDivider(day: msg.ts), row]);
                  },
                ),
        ),
        Composer(key: ValueKey(convo.id), state: widget.state, convo: convo, reply: _reply),
      ]);
    });
    if (isTouchPlatform) return thread;
    final tc = TincanColors.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _dropped,
      child: Stack(children: [
        thread,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: tc.accentSoft.withValues(alpha: 0.85),
                  border: Border.all(color: tc.accent, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text('Drop to send to ${convo.displayName}',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600, color: tc.accent)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _searchBar(TincanColors tc) {
    final count = _query.text.trim().isEmpty
        ? ''
        : _hits.isEmpty
            ? 'No matches'
            : '${_hit + 1} of ${_hits.length}';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      decoration: BoxDecoration(
        color: tc.panel,
        border: Border(bottom: BorderSide(color: tc.border)),
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
          const SingleActivator(LogicalKeyboardKey.enter): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _step(-1),
        },
        child: Row(children: [
          Icon(Icons.search, size: 18, color: tc.inkMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _query,
              autofocus: true,
              onChanged: _search,
              style: TextStyle(fontSize: 13.5, color: tc.ink),
              decoration: InputDecoration.collapsed(
                hintText: 'Search in this chat',
                hintStyle: TextStyle(fontSize: 13.5, color: tc.inkFaint),
              ).copyWith(enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
            ),
          ),
          Semantics(
            liveRegion: true,
            child: Text(count, style: TextStyle(fontSize: 12, color: tc.inkMuted)),
          ),
          IconButton(
            tooltip: 'Older match',
            onPressed: _hits.isEmpty ? null : () => _step(1),
            icon: Icon(Icons.keyboard_arrow_up, color: tc.inkMuted),
          ),
          IconButton(
            tooltip: 'Newer match',
            onPressed: _hits.isEmpty ? null : () => _step(-1),
            icon: Icon(Icons.keyboard_arrow_down, color: tc.inkMuted),
          ),
          IconButton(
            tooltip: 'Close search',
            onPressed: _closeSearch,
            icon: Icon(Icons.close, size: 18, color: tc.inkMuted),
          ),
        ]),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: tc.dangerBg,
          border: Border(bottom: BorderSide(color: tc.dangerBorder)),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 16, color: tc.dangerInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.35, color: tc.dangerInk)),
          ),
        ]),
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Row(children: [
        Expanded(child: Divider(color: tc.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(formatDay(day), style: TextStyle(fontSize: 11, color: tc.inkFaint)),
        ),
        Expanded(child: Divider(color: tc.border)),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.convo, this.onBack, required this.onSearch});

  final AppState state;
  final Conversation convo;
  final VoidCallback? onBack;
  final VoidCallback onSearch;

  Future<void> _confirmAndBlock(BuildContext context) async {
    if (!await confirmBlock(context, convo.displayName) || !context.mounted) return;
    showError(context, state.blockPeer(convo.id));
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    if (!await confirmDeleteConversation(context, convo.displayName) || !context.mounted) return;
    if (onBack != null) onBack!();
    showError(context, state.deleteConversation(convo.id));
  }

  Future<void> _pickTimer(BuildContext context) async {
    final tc = TincanColors.of(context);
    final picked = await showDialog<(Duration?,)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Disappearing messages', style: TextStyle(fontSize: 17)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('New messages in this chat vanish from both devices after this long.',
                style: TextStyle(fontSize: 12.5, height: 1.45, color: tc.inkMuted)),
          ),
          for (final (d, label) in _timerChoices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop((d,)),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minTap),
                child: Row(children: [
                  Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
                  if (convo.disappearAfter == d)
                    Icon(Icons.check, size: 18, color: tc.accent, semanticLabel: 'Current'),
                ]),
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked.$1 == convo.disappearAfter) return;
    await state.setDisappearing(convo.id, picked.$1);
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final narrow = !isWide(context);
    final timer = convo.disappearAfter;
    return Container(
      padding: EdgeInsets.only(
          left: onBack == null ? 20 : 6,
          right: 8,
          top: MediaQuery.paddingOf(context).top),
      constraints: BoxConstraints(minHeight: 64 + MediaQuery.paddingOf(context).top),
      decoration: BoxDecoration(
        color: tc.panel,
        border: Border(bottom: BorderSide(color: tc.border)),
      ),
      child: Row(children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            tooltip: 'Back',
            icon: Icon(Icons.arrow_back_ios_new, size: 18, color: tc.ink),
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
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: Text(convo.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                        if (convo.verified) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.verified, size: 15, color: tc.accent, semanticLabel: 'Verified'),
                        ],
                        if (convo.muted) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.notifications_off_outlined,
                              size: 14, color: tc.inkFaint, semanticLabel: 'Muted'),
                        ],
                        if (timer != null) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Messages disappear after ${_timerLabel(timer)}',
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.timer_outlined, size: 14, color: tc.inkMuted),
                              const SizedBox(width: 2),
                              Text(_timerLabel(timer),
                                  style: TextStyle(fontSize: 11.5, color: tc.inkMuted)),
                            ]),
                          ),
                        ],
                      ]),
                      if (convo.statusText.isNotEmpty)
                        Text(convo.statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: tc.inkMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: _StatusPill(convo: convo, showPath: !narrow)),
              ]),
            ),
          ),
        ),
        if (convo.blocked)
          OutlinedButton(
            style: tc.accentOutline,
            onPressed: () => showError(context, state.unblockPeer(convo.id)),
            child: const Text('Unblock'),
          )
        else if (!convo.connected && convo.token != null)
          OutlinedButton(
            style: tc.accentOutline,
            onPressed: () => showError(context, state.reconnect(convo.id)),
            child: const Text('Reconnect'),
          ),
        PopupMenuButton<String>(
          tooltip: 'Conversation options',
          icon: Icon(Icons.more_vert, size: 18, color: tc.inkMuted),
          onSelected: (v) async {
            switch (v) {
              case 'profile':
                await showPeerProfileDialog(context, state, convo);
              case 'search':
                onSearch();
              case 'timer':
                await _pickTimer(context);
              case 'mute':
                state.setMuted(convo.id, !convo.muted);
              case 'block':
                await _confirmAndBlock(context);
              case 'delete':
                await _confirmAndDelete(context);
            }
          },
          itemBuilder: (context) => [
            _item('profile', 'Contact info'),
            _item('search', 'Search in chat'),
            _item('timer', 'Disappearing messages'),
            _item('mute', convo.muted ? 'Unmute' : 'Mute'),
            _item('delete', 'Delete conversation'),
            if (!convo.blocked) _item('block', 'Block peer'),
          ],
        ),
      ]),
    );
  }

  static PopupMenuItem<String> _item(String value, String label) =>
      PopupMenuItem(value: value, child: Text(label, style: const TextStyle(fontSize: 13.5)));
}

/// The peer's profile, with our nickname for them and the safety number.
Future<void> showPeerProfileDialog(
    BuildContext context, AppState state, Conversation convo) {
  return showTincanDialog(
    context,
    (context) => Dialog(child: _PeerProfile(state: state, convo: convo)),
  );
}

class _PeerProfile extends StatefulWidget {
  const _PeerProfile({required this.state, required this.convo});

  final AppState state;
  final Conversation convo;

  @override
  State<_PeerProfile> createState() => _PeerProfileState();
}

class _PeerProfileState extends State<_PeerProfile> {
  late final _nickname = TextEditingController(text: widget.convo.nickname ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  void _rename() {
    widget.state.setNickname(widget.convo.id, _nickname.text);
    _nickname.text = widget.convo.nickname ?? '';
    showToast(context, widget.convo.nickname == null ? 'Name cleared' : 'Renamed');
  }

  Future<void> _verify(bool on) async {
    setState(() => _busy = true);
    final error = await widget.state.setVerified(widget.convo.id, on);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, error ?? (on ? 'Marked as verified' : 'No longer verified'));
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final state = widget.state;
    return ListenableBuilder(
      listenable: widget.convo,
      builder: (context, _) {
        final convo = widget.convo;
        return Container(
          width: 420,
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  PeerAvatar(state: state, convo: convo, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(convo.displayName,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                        if (convo.verified) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.verified, size: 17, color: tc.accent, semanticLabel: 'Verified'),
                        ],
                      ]),
                      if (convo.nickname != null)
                        Text('Calls themselves ${convo.name}',
                            style: TextStyle(fontSize: 12.5, color: tc.inkMuted)),
                      if (convo.statusText.isNotEmpty)
                        Text(convo.statusText,
                            style: TextStyle(fontSize: 12.5, color: tc.inkMuted)),
                    ]),
                  ),
                ]),
                if (convo.description.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(convo.description, style: const TextStyle(fontSize: 13, height: 1.5)),
                ],
                const SizedBox(height: 18),
                Text('YOUR NAME FOR THEM', style: Tc.caps(tc.label)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _nickname,
                      onSubmitted: (_) => _rename(),
                      style: TextStyle(fontSize: 13.5, color: tc.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: convo.name,
                        hintStyle: TextStyle(fontSize: 13.5, color: tc.inkFaint),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                      style: tc.accentOutline, onPressed: _rename, child: const Text('Rename')),
                ]),
                const SizedBox(height: 18),
                Text('CONNECTION', style: Tc.caps(tc.label)),
                const SizedBox(height: 4),
                Text(_linkDetail(convo, withPath: true),
                    style: TextStyle(fontSize: 12.5, color: tc.inkMuted)),
                const SizedBox(height: 18),
                Text('SAFETY NUMBER', style: Tc.caps(tc.label)),
                const SizedBox(height: 4),
                if (convo.fp.isEmpty)
                  Text('Shown once you have connected.',
                      style: TextStyle(fontSize: 12.5, color: tc.inkMuted))
                else ...[
                  Row(children: [
                    Expanded(
                      child: SelectableText(convo.fp,
                          style: Tc.mono(16, tc.ink, weight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: 'Copy safety number',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: convo.fp));
                        showToast(context, 'Safety number copied');
                      },
                      icon: Icon(Icons.copy_outlined, size: 16, color: tc.inkMuted),
                    ),
                  ]),
                  Text('Compare this number with your contact in person or on a call.',
                      style: TextStyle(fontSize: 12, height: 1.45, color: tc.inkMuted)),
                  const SizedBox(height: 10),
                  if (convo.verified)
                    Row(children: [
                      Icon(Icons.verified, size: 16, color: tc.accent),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('Verified',
                            style: TextStyle(fontSize: 13, color: tc.accent, fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _verify(false),
                        child: Text('Unverify', style: TextStyle(color: tc.inkMuted)),
                      ),
                    ])
                  else
                    OutlinedButton.icon(
                      style: tc.accentOutline,
                      onPressed: _busy ? null : () => _verify(true),
                      icon: const Icon(Icons.verified_outlined, size: 16),
                      label: const Text('Mark as verified'),
                    ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Close', style: TextStyle(color: tc.inkMuted)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Direct · 203.0.113.7:41641 · 14 ms, for tooltips and the profile.
String _linkDetail(Conversation c, {required bool withPath}) {
  if (c.blocked) return 'Blocked';
  if (!c.connected) return c.reconnecting ? 'Reconnecting' : 'Not connected';
  if (c.awaitingDirect) return 'Connected through the relay, waiting for a direct path';
  final latency = c.latencyMs == null ? '' : ' · ${c.latencyMs} ms';
  return switch (c.direct) {
    true => 'Direct${withPath && c.pathAddr.isNotEmpty ? ' · ${c.pathAddr}' : ''}$latency',
    false => 'Relayed${c.relay.isEmpty ? '' : ' via ${c.relay}'}$latency',
    null => 'Connected$latency',
  };
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.convo, required this.showPath});

  final Conversation convo;
  final bool showPath;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final grey = (tc.fieldFill, tc.border, tc.offline, tc.inkMuted);
    final amber = (tc.relayAmberBg, tc.relayAmberBorder, tc.relayAmber, tc.relayAmberInk);
    final ((bg, border, dot, ink), label) = switch (convo) {
      Conversation(blocked: true) =>
        ((tc.dangerBg, tc.dangerBorder, tc.danger, tc.dangerInk), 'Blocked'),
      Conversation(connected: true, remotePending: true) => (amber, 'Waiting for acceptance…'),
      Conversation(connected: true, awaitingDirect: true) => (amber, 'Waiting for a direct path'),
      Conversation(connected: false) =>
        (grey, convo.reconnecting ? 'Reconnecting…' : 'Disconnected'),
      Conversation(direct: true) =>
        ((tc.directGreenBg, tc.directGreenBorder, tc.directGreen, tc.directGreenInk), 'Direct'),
      Conversation(direct: false) => (amber, 'Relayed'),
      _ => (grey, 'Connected'),
    };
    return Tooltip(
      message: _linkDetail(convo, withPath: showPath),
      child: Container(
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ink)),
          ),
        ]),
      ),
    );
  }
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.state,
    required this.convo,
    required this.msg,
    required this.lastInGroup,
    required this.showStatus,
    required this.onReply,
    required this.onJump,
  });

  final AppState state;
  final Conversation convo;
  final ChatMessage msg;

  /// Only the last of a run shows the avatar and the time.
  final bool lastInGroup;
  final bool showStatus;
  final ValueChanged<ChatMessage> onReply;
  final ValueChanged<String> onJump;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _hover = false;

  ChatMessage get msg => widget.msg;

  void _actions(Offset? at) => unawaited(showMessageActions(context,
      state: widget.state, convo: widget.convo, msg: msg, onReply: widget.onReply, at: at));

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final state = widget.state;
    final convo = widget.convo;
    final maxBubble = min(460.0, MediaQuery.sizeOf(context).width * 0.72);
    final status = msg.outgoing ? _statusIcon(tc) : null;
    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (msg.expiresAt != null) ...[
        Icon(Icons.timer_outlined, size: 11, color: tc.inkFaint, semanticLabel: 'Disappearing'),
        const SizedBox(width: 3),
      ],
      if (widget.lastInGroup)
        Text(formatClock(msg.ts), style: TextStyle(fontSize: 11, color: tc.inkFaint)),
      if (status != null) ...[
        if (widget.lastInGroup) const SizedBox(width: 4),
        status,
      ],
    ]);
    final quoted = msg.replyTo == null ? null : convo.messageById(msg.replyTo!);
    final body = msg.kind == MessageKind.text
        ? _TextBubble(
            msg: msg,
            tail: widget.lastInGroup,
            quote: msg.replyTo == null
                ? null
                : ReplyQuote(
                    convo: convo,
                    quoted: quoted,
                    onDark: msg.outgoing,
                    onTap: quoted == null ? null : () => widget.onJump(quoted.id),
                  ),
          )
        : _MediaBubble(state: state, convo: convo, msg: msg, width: min(280, maxBubble - 12));
    final bubble = Flexible(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubble),
        child: GestureDetector(
          onLongPress: () => _actions(null),
          onSecondaryTapUp: (d) => _actions(d.globalPosition),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: msg.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              body,
              if (msg.reactions.isNotEmpty)
                Transform.translate(
                  offset: const Offset(0, -8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ReactionChips(
                        msg: msg, onToggle: (e) => state.react(convo.id, msg.id, e)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final hoverButton = isTouchPlatform
        ? null
        : Visibility(
            visible: _hover,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: ExcludeFocus(
              excluding: !_hover,
              child: Builder(
                builder: (context) => IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Message actions',
                  onPressed: () {
                    final box = context.findRenderObject()! as RenderBox;
                    _actions(box.localToGlobal(box.size.bottomCenter(Offset.zero)));
                  },
                  icon: Icon(Icons.more_horiz, size: 18, color: tc.inkMuted),
                ),
              ),
            ),
          );
    final children = msg.outgoing
        ? [?hoverButton, meta, const SizedBox(width: 8), bubble]
        : [
            if (widget.lastInGroup)
              PeerAvatar(state: state, convo: convo, size: 30)
            else
              const SizedBox(width: 30),
            const SizedBox(width: 10),
            bubble,
            const SizedBox(width: 8),
            meta,
            ?hoverButton,
          ];
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: msg.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: msg.outgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: children,
          ),
          if (msg.status == MessageStatus.interrupted)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 3),
              child: Text('Transfer interrupted',
                  style: TextStyle(fontSize: 11, color: tc.danger)),
            )
          else if (msg.status == MessageStatus.failed)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => state.retry(convo.id, msg),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minTap),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.refresh, size: 14, color: tc.danger),
                    const SizedBox(width: 4),
                    Text('Couldn\'t send · tap to retry',
                        style: TextStyle(fontSize: 11.5, color: tc.danger)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Clock while queued, arrow while sending, check once sent, double
  /// check once delivered. A run shows sent/delivered once, unless it differs.
  Widget? _statusIcon(TincanColors tc) {
    Icon icon(IconData i, String label, [Color? color]) =>
        Icon(i, size: 13, color: color ?? tc.inkFaint, semanticLabel: label);
    return switch (msg.status) {
      MessageStatus.queued => icon(Icons.schedule, 'Waiting to send'),
      MessageStatus.sending => icon(Icons.arrow_upward, 'Sending'),
      MessageStatus.failed => icon(Icons.error_outline, 'Not sent', tc.danger),
      MessageStatus.sent when widget.showStatus => icon(Icons.check, 'Sent'),
      MessageStatus.delivered when widget.showStatus => icon(Icons.done_all, 'Delivered', tc.accent),
      _ => null,
    };
  }
}

class _TextBubble extends StatelessWidget {
  const _TextBubble({required this.msg, required this.tail, this.quote});

  final ChatMessage msg;
  final bool tail;
  final Widget? quote;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final out = msg.outgoing;
    final corner = tail ? 5.0 : 16.0;
    // Plain Text: long-press and right-click open the message menu, which has Copy.
    final text = Text(
      msg.body,
      style: TextStyle(fontSize: 13.5, height: 1.45, color: out ? tc.bubbleOutInk : tc.ink),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: out ? tc.bubbleOut : tc.bubbleIn,
        border: out ? null : Border.all(color: tc.bubbleInBorder),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(out ? 16 : corner),
          bottomRight: Radius.circular(out ? corner : 16),
        ),
      ),
      child: quote == null
          ? text
          : IntrinsicWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                quote!,
                const SizedBox(height: 6),
                text,
              ]),
            ),
    );
  }
}

class _MediaBubble extends StatelessWidget {
  const _MediaBubble({
    required this.state,
    required this.convo,
    required this.msg,
    required this.width,
  });

  final AppState state;
  final Conversation convo;
  final ChatMessage msg;
  final double width;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final out = msg.outgoing;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: out ? tc.mediaOut : tc.bubbleIn,
        border: Border.all(color: out ? tc.mediaOutBorder : tc.bubbleInBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder(
            valueListenable: msg.progress,
            builder: (context, progress, _) => _mediaBody(context, tc, progress),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 6, 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(msg.name ?? 'file',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Tc.mono(11, tc.inkMuted)),
              ),
              const SizedBox(width: 12),
              Text(msg.size == null ? '' : formatSize(msg.size!),
                  style: Tc.mono(11, tc.inkFaint)),
            ]),
          ),
        ],
      ),
    );
  }

  bool get _settled =>
      msg.status != MessageStatus.sending &&
      msg.status != MessageStatus.failed &&
      msg.status != MessageStatus.interrupted;

  Widget _mediaBody(BuildContext context, TincanColors tc, double? progress) {
    final sealed = msg.path;
    if (progress != null || sealed == null || !_settled) {
      return _placeholder(tc, progress: progress);
    }
    if (msg.kind == MessageKind.video) {
      return VideoBubble(key: ValueKey(sealed), state: state, msg: msg, width: width);
    }
    if (msg.kind != MessageKind.image) {
      // Decrypted only when opened: files can be big.
      return _placeholder(tc, done: true, onOpen: () => showError(context, openSealed(sealed, state.decryptForOpen)));
    }
    return ValueListenableBuilder(
      valueListenable: state.plaintext(sealed),
      builder: (context, path, _) => path == null
          ? _placeholder(tc)
          : ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Semantics(
                image: true,
                button: true,
                label: 'Image ${msg.name ?? ''}, open',
                child: InkWell(
                  onTap: () => showImageViewer(context, path: path, name: msg.name ?? 'image'),
                  child: Image.file(
                    File(path),
                    width: width,
                    cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _placeholder(tc, broken: true),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _placeholder(TincanColors tc,
      {double? progress, bool done = false, bool broken = false, VoidCallback? onOpen}) {
    final isVideo = msg.kind == MessageKind.video;
    final onDark = tc.sidebarText;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: width,
        height: width * 0.565,
        color: isVideo ? tc.videoBg : tc.mediaPlaceholder,
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
                  color: tc.accent,
                  backgroundColor: isVideo ? tc.sidebarCardBorder : tc.border,
                  semanticsLabel: msg.outgoing ? 'Sending' : 'Receiving',
                ),
                const SizedBox(height: 8),
                Text('${(progress * 100).round()}%',
                    style: Tc.mono(11, isVideo ? onDark : tc.inkMuted)),
              ]),
            )
          else if (broken)
            Icon(Icons.broken_image_outlined, size: 28, color: tc.inkFaint)
          else if (done)
            IconButton(
              onPressed: onOpen,
              tooltip: 'Open file',
              icon: Icon(Icons.insert_drive_file_outlined, size: 32, color: tc.inkMuted),
            )
          else
            Icon(Icons.hourglass_empty, size: 24, color: isVideo ? onDark : tc.inkFaint),
          if (progress != null && canCancelTransfer(msg))
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: 'Cancel transfer',
                onPressed: () => state.cancelTransfer(convo.id, msg.id),
                icon: Icon(Icons.close, size: 18, color: isVideo ? onDark : tc.inkMuted),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Reports when a row enters and leaves the built list.
class _Tracked extends StatefulWidget {
  const _Tracked({required this.id, required this.onMount, required this.onUnmount, required this.child});

  final String id;
  final ValueChanged<String> onMount;
  final ValueChanged<String> onUnmount;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  void initState() {
    super.initState();
    widget.onMount(widget.id);
  }

  @override
  void dispose() {
    widget.onUnmount(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
