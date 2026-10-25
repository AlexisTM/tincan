import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Backup files, opening on another device: plaintext, or sealed under
/// a password the user picks. The account one holds the private key.
/// The chats one zips the history with its media.
///
/// Both are written and read by the transport, which holds the
/// encryption key; only the chat history is assembled here.

const _chatsKind = 'tincan-chats';

/// What a password-sealed backup starts with.
const _sealedMagic = [0x54, 0x43, 0x42, 0x01]; // "TCB\x01"

/// Whether [path] is a password-sealed backup, account or chats.
Future<bool> isSealedBackup(String path) async {
  final f = await File(path).open();
  try {
    final head = await f.read(_sealedMagic.length);
    return listEquals(head, _sealedMagic);
  } finally {
    await f.close();
  }
}

/// First "name.ext", "name (2).ext", … that [taken] doesn't claim.
String _uniqueName(String name, bool Function(String) taken) {
  var candidate = name;
  for (var i = 2; taken(candidate); i++) {
    candidate = p.join(p.dirname(name),
        '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}');
  }
  return candidate;
}

/// Writes a chats backup: the history index and its media, as sealed
/// path and name in the backup.
typedef ChatsWriter = Future<void> Function(String dst, String index, List<(String, String)> media,
    {String password});

/// Reads one back, sealing its media into mediaDir.
typedef ChatsReader = Future<({String index, Map<String, String> media})> Function(
    String src, String mediaDir,
    {String password});

/// Backs up the chat history plus every media file it still has into
/// [outPath], sealed under [password] unless it is empty.
Future<void> exportChats(
  Iterable<Conversation> conversations,
  String outPath, {
  String password = '',
  required ChatsWriter write,
}) async {
  final names = <String, String>{}; // sealed path -> name in the backup
  final used = <String>{};
  final convos = <Map<String, dynamic>>[];
  for (final c in conversations) {
    final j = c.toJson();
    for (final m in (j['messages'] as List).cast<Map<String, dynamic>>()) {
      final path = m['path'] as String?;
      if (path == null) continue;
      var name = names[path];
      if (name == null) {
        if (!await File(path).exists()) {
          m.remove('path');
          continue;
        }
        name = names[path] = _uniqueName('media/${p.basename(path)}', used.contains);
        used.add(name);
      }
      m['path'] = name;
    }
    convos.add(j);
  }
  final index = jsonEncode({'v': 2, 'kind': _chatsKind, 'conversations': convos});
  await write(outPath, index, [for (final e in names.entries) (e.key, e.value)], password: password);
}

/// The conversations in the chats backup at [path], their media sealed
/// into [mediaDir].
Future<List<Conversation>> importChats(
  String path,
  String mediaDir, {
  String password = '',
  required ChatsReader read,
}) async {
  if (password.isEmpty && await isSealedBackup(path)) {
    throw const FormatException('This chats file is sealed; enter its backup password.');
  }
  final got = await read(path, mediaDir, password: password);
  try {
    final index = jsonDecode(got.index) as Map;
    final legacy = (index['v'] as num? ?? 1) < 2;
    final out = [
      for (final cj in (index['conversations'] as List? ?? const []))
        Conversation.fromJson((cj as Map).cast<String, dynamic>(), legacy: legacy),
    ];
    for (final c in out) {
      for (final m in c.messages) {
        if (m.path != null) m.path = got.media[m.path];
      }
    }
    return out;
  } on TypeError catch (e) {
    throw FormatException('Not a Tincan chats file: $e');
  }
}
