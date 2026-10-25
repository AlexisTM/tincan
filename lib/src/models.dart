import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum MessageKind { text, image, video, file }

/// queued waits in the outbox for the peer; sent left this device and
/// delivered was acked. failed is an outgoing message that can be
/// retried; interrupted is an incoming transfer that broke off, which
/// only the sender can redo.
enum MessageStatus { queued, sending, sent, delivered, failed, interrupted }

MessageKind kindFromWire(String? s) => switch (s) {
      'image' => MessageKind.image,
      'video' => MessageKind.video,
      'file' => MessageKind.file,
      _ => MessageKind.text,
    };

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.outgoing,
    required this.ts,
    required this.kind,
    this.body = '',
    this.path,
    this.name,
    this.size,
    double? progress,
    this.status = MessageStatus.sent,
    this.replyTo,
    Map<String, Set<String>>? reactions,
    this.expiresAt,
  })  : reactions = reactions ?? {},
        _progress = progress == null ? null : ValueNotifier(progress);

  final String id;
  final bool outgoing;
  final DateTime ts;
  MessageKind kind;
  String body;
  String? path; // the sealed copy in the app's store, once there is one
  String? name;
  int? size;
  String? replyTo; // id of the quoted message
  final Map<String, Set<String>> reactions; // emoji -> 'me' or the peer's id
  DateTime? expiresAt; // disappearing messages
  MessageStatus status;

  bool get isMedia => kind != MessageKind.text;

  ValueNotifier<double?>? _progress;

  /// 0..1 while a transfer is running. Its own notifier, so a progress
  /// tick repaints the bubble and not the thread; made on first use.
  ValueNotifier<double?> get progress => _progress ??= ValueNotifier(null);

  /// Sets progress without making a notifier for nothing.
  void setProgress(double? v) {
    if (v == null && _progress == null) return;
    progress.value = v;
  }

  /// The emoji [who] reacted with, if any.
  String? reactionOf(String who) {
    for (final e in reactions.entries) {
      if (e.value.contains(who)) return e.key;
    }
    return null;
  }

  /// One reaction per person: replaces theirs, empty removes it.
  void setReaction(String who, String emoji) {
    reactions.removeWhere((_, whoSet) => whoSet.remove(who) && whoSet.isEmpty);
    if (emoji.isNotEmpty) reactions.putIfAbsent(emoji, () => {}).add(who);
  }

  String get preview => switch (kind) {
        MessageKind.text => body,
        _ => name ?? 'file',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'out': outgoing,
        'ts': ts.millisecondsSinceEpoch,
        'kind': kind.name,
        if (body.isNotEmpty) 'body': body,
        if (path != null) 'path': path,
        if (name != null) 'name': name,
        if (size != null) 'size': size,
        'status': status.name,
        if (replyTo != null) 'reply': replyTo,
        if (reactions.isNotEmpty) 'react': {for (final e in reactions.entries) e.key: e.value.toList()},
        if (expiresAt != null) 'exp': expiresAt!.millisecondsSinceEpoch,
      };

  /// [legacy] history predates acks, so what it calls sent arrived.
  static ChatMessage fromJson(Map<String, dynamic> j, {bool legacy = false}) {
    final out = j['out'] == true;
    final kind = MessageKind.values.asNameMap()[j['kind']] ?? MessageKind.text;
    return ChatMessage(
      id: j['id'] as String? ?? newMessageId(),
      outgoing: out,
      ts: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0),
      kind: kind,
      body: j['body'] as String? ?? '',
      path: j['path'] as String?,
      name: j['name'] as String?,
      size: (j['size'] as num?)?.toInt(),
      replyTo: j['reply'] as String?,
      reactions: {
        for (final e in ((j['react'] as Map?) ?? const {}).entries)
          e.key as String: {for (final w in (e.value as List)) w as String},
      },
      expiresAt: switch (j['exp']) {
        final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      },
      // In-flight transfers don't survive a restart; queued and unacked
      // texts go out again on the next connection.
      status: switch (j['status']) {
        'delivered' => MessageStatus.delivered,
        'sent' when legacy || !out => out ? MessageStatus.delivered : MessageStatus.sent,
        'sent' => MessageStatus.sent,
        'queued' => MessageStatus.queued,
        'sending' when out && (kind == MessageKind.text || j['path'] != null) => MessageStatus.queued,
        'interrupted' => MessageStatus.interrupted,
        _ => out ? MessageStatus.failed : MessageStatus.interrupted,
      },
    );
  }
}

/// Notifies on its own changes (messages, status, progress) so only
/// the widgets showing this conversation repaint.
class Conversation extends ChangeNotifier {
  Conversation({required this.id, required this.name, this.token});

  final String id; // peer's stable node key
  String name; // what the peer calls themselves
  String? nickname; // what we call them, wins over name
  String? token; // how to redial them
  String description = ''; // peer's profile bio
  String statusText = ''; // peer's profile status line
  String? avatarPath; // local file with the peer's profile picture
  String fp = ''; // safety number
  bool verified = false;
  bool muted = false;
  Duration? disappearAfter;

  /// Our timer change hasn't reached the peer yet.
  bool timerPending = false;

  /// Our reactions made offline, by message id; empty removes.
  final pendingReactions = <String, String>{};

  bool connected = false;
  bool? direct; // null until the first peer-status report
  String pathAddr = '';
  String relay = '';
  int? latencyMs;
  int unread = 0;
  bool remotePending = false; // we dialed them; they haven't accepted yet
  bool blocked = false; // we blocked them
  bool reconnecting = false; // an automatic redial is pending
  bool awaitingDirect = false; // direct-only mode: reached, waiting for a direct path
  String draft = ''; // unsent composer text, kept across thread switches
  final messages = <ChatMessage>[];

  String get displayName => switch (nickname) {
        final n? when n.isNotEmpty => n,
        _ => name.isEmpty ? 'peer' : name,
      };

  DateTime get lastActivity =>
      messages.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : messages.last.ts;

  ChatMessage? messageById(String id) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].id == id) return messages[i];
    }
    return null;
  }

  String get initials => initialsOf(displayName);

  String? _encoded;

  /// This conversation as the history file stores it, encoded once per
  /// change rather than on every save.
  String get encoded => _encoded ??= jsonEncode(toJson());

  /// Repaints, and marks what history stores as changed.
  void changed() {
    _encoded = null;
    notifyListeners();
  }

  /// Repaints for what history doesn't store: connection state.
  void repaint() => notifyListeners();

  void markOffline() {
    connected = false;
    direct = null;
    latencyMs = null;
    awaitingDirect = false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (nickname != null) 'nickname': nickname,
        if (token != null) 'token': token,
        if (description.isNotEmpty) 'description': description,
        if (statusText.isNotEmpty) 'statusText': statusText,
        if (avatarPath != null) 'avatarPath': avatarPath,
        if (fp.isNotEmpty) 'fp': fp,
        if (verified) 'verified': true,
        if (muted) 'muted': true,
        if (unread > 0) 'unread': unread,
        if (disappearAfter != null) 'disappear': disappearAfter!.inSeconds,
        if (timerPending) 'timerPending': true,
        if (pendingReactions.isNotEmpty) 'pendingReact': pendingReactions,
        'messages': [for (final m in messages) m.toJson()],
      };

  static Conversation fromJson(Map<String, dynamic> j, {bool legacy = false}) {
    final c = Conversation(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'peer',
      token: j['token'] as String?,
    );
    c.nickname = j['nickname'] as String?;
    c.description = j['description'] as String? ?? '';
    c.statusText = j['statusText'] as String? ?? '';
    c.avatarPath = j['avatarPath'] as String?;
    c.fp = j['fp'] as String? ?? '';
    c.verified = j['verified'] == true;
    c.muted = j['muted'] == true;
    c.unread = (j['unread'] as num?)?.toInt() ?? 0;
    c.disappearAfter = switch (j['disappear']) {
      final num s when s > 0 => Duration(seconds: s.toInt()),
      _ => null,
    };
    c.timerPending = j['timerPending'] == true;
    for (final e in ((j['pendingReact'] as Map?) ?? const {}).entries) {
      c.pendingReactions[e.key as String] = e.value as String;
    }
    for (final m in (j['messages'] as List? ?? const [])) {
      c.messages.add(ChatMessage.fromJson((m as Map).cast<String, dynamic>(), legacy: legacy));
    }
    return c;
  }

  /// Folds in another copy of this conversation, by message id.
  void mergeFrom(Conversation other) {
    final have = {for (final m in messages) m.id};
    for (final m in other.messages) {
      if (!have.contains(m.id)) messages.add(m);
    }
    messages.sort((a, b) => a.ts.compareTo(b.ts));
    token ??= other.token;
    nickname ??= other.nickname;
    if (name == 'peer' && other.name.isNotEmpty) name = other.name;
  }
}

/// An incoming peer waiting for the user to accept or refuse them.
class ChatRequest {
  ChatRequest({required this.peer, required this.name, this.fp = '', this.first = ''});

  final String peer;
  final String name;
  final String fp; // safety number
  final String first; // their first message, if they sent one

  String get initials => initialsOf(name);
  String get displayName => name.isEmpty ? _shortKey(peer) : name;
}

class BlockedPeer {
  const BlockedPeer({required this.peer, required this.name});

  final String peer;
  final String name;

  String get displayName => name.isEmpty ? shortKey : name;
  String get shortKey => _shortKey(peer);
}

String _shortKey(String peer) => peer.length > 16 ? '${peer.substring(0, 16)}…' : peer;

final _rng = Random();

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, min(2, parts.first.length)).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

String newMessageId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rng.nextInt(1 << 20).toRadixString(36)}';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String formatClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Compact stamp for lists: clock today, weekday this week, date beyond.
String formatTime(DateTime t) {
  final now = DateTime.now();
  if (sameDay(t, now)) return formatClock(t);
  if (now.difference(t).inDays < 7) return _weekdays[t.weekday - 1];
  return '${t.day} ${_months[t.month - 1]}';
}

/// Day heading inside a thread.
String formatDay(DateTime t) {
  final now = DateTime.now();
  if (sameDay(t, now)) return 'Today';
  if (sameDay(t, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  final date = '${_weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
  return t.year == now.year ? date : '$date ${t.year}';
}
