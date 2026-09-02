import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum MessageKind { text, image, video, file }

/// failed is an outgoing message that can be retried; interrupted is an
/// incoming transfer that broke off, which only the sender can redo.
enum MessageStatus { sending, sent, failed, interrupted }

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
  }) : progress = ValueNotifier(progress);

  final String id;
  final bool outgoing;
  final DateTime ts;
  MessageKind kind;
  String body;
  String? path; // the sealed copy in the app's store, once there is one
  String? name;
  int? size;

  /// 0..1 while a transfer is running. Its own notifier, so a progress
  /// tick repaints the bubble and not the thread.
  final ValueNotifier<double?> progress;
  MessageStatus status;

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
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String? ?? newMessageId(),
        outgoing: j['out'] == true,
        ts: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0),
        kind: MessageKind.values.asNameMap()[j['kind']] ?? MessageKind.text,
        body: j['body'] as String? ?? '',
        path: j['path'] as String?,
        name: j['name'] as String?,
        size: (j['size'] as num?)?.toInt(),
        // In-flight transfers don't survive a restart.
        status: switch (j['status']) {
          'sent' => MessageStatus.sent,
          'interrupted' => MessageStatus.interrupted,
          _ => j['out'] == true ? MessageStatus.failed : MessageStatus.interrupted,
        },
      );
}

/// Notifies on its own changes (messages, status, progress) so only
/// the widgets showing this conversation repaint.
class Conversation extends ChangeNotifier {
  Conversation({required this.id, required this.name, this.token});

  final String id; // peer's stable node key
  String name;
  String? token; // how to redial them; only known for outgoing peers
  String description = ''; // peer's profile bio
  String statusText = ''; // peer's profile status line
  String? avatarPath; // local file with the peer's profile picture

  bool connected = false;
  bool? direct; // null until the first peer-status report
  String pathAddr = '';
  String relay = '';
  int? latencyMs;
  int unread = 0;
  bool remotePending = false; // we dialed them; they haven't accepted yet
  bool blocked = false; // we blocked them
  bool reconnecting = false; // an automatic redial is pending
  String draft = ''; // unsent composer text, kept across thread switches
  final messages = <ChatMessage>[];

  DateTime get lastActivity =>
      messages.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : messages.last.ts;

  ChatMessage? messageById(String id) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].id == id) return messages[i];
    }
    return null;
  }

  String get initials => initialsOf(name);

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
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (token != null) 'token': token,
        if (description.isNotEmpty) 'description': description,
        if (statusText.isNotEmpty) 'statusText': statusText,
        if (avatarPath != null) 'avatarPath': avatarPath,
        'messages': [for (final m in messages) m.toJson()],
      };

  static Conversation fromJson(Map<String, dynamic> j) {
    final c = Conversation(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'peer',
      token: j['token'] as String?,
    );
    c.description = j['description'] as String? ?? '';
    c.statusText = j['statusText'] as String? ?? '';
    c.avatarPath = j['avatarPath'] as String?;
    for (final m in (j['messages'] as List? ?? const [])) {
      c.messages.add(ChatMessage.fromJson((m as Map).cast<String, dynamic>()));
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
    if (name == 'peer' && other.name.isNotEmpty) name = other.name;
  }
}

/// An incoming peer waiting for the user to accept or refuse them.
class ChatRequest {
  ChatRequest({required this.peer, required this.name});

  final String peer;
  final String name;

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
