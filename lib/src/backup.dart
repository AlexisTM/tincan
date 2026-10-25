import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Backup files, opening on another device: plaintext, or sealed under
/// a password the user picks. The account one holds the private key.
/// The chats one zips the history with its media.
///
/// The account side lives in the transport, which holds the encryption
/// key; only the chat history is assembled here.

const _chatsKind = 'tincan-chats';

/// What the bridge's SealFile writes first.
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

/// Scratch dirs hold decrypted history; a killed run leaves them behind.
bool _sweptScratch = false;

Future<Directory> _scratch(String prefix) async {
  if (!_sweptScratch) {
    _sweptScratch = true;
    try {
      await for (final e in Directory.systemTemp.list()) {
        final name = p.basename(e.path);
        if (e is Directory && (name.startsWith('tincan-export-') || name.startsWith('tincan-import-'))) {
          await e.delete(recursive: true).then((_) {}, onError: (Object err) {
            debugPrint('tincan: removing stale ${e.path}: $err');
          });
        }
      }
    } catch (e) {
      debugPrint('tincan: sweeping backup scratch: $e');
    }
  }
  return Directory.systemTemp.createTemp(prefix);
}

Future<void> _dropScratch(Directory scratch) => scratch.delete(recursive: true).then((_) {},
    onError: (Object e) => debugPrint('tincan: removing ${scratch.path}: $e'));

/// First "name.ext", "name (2).ext", … that [taken] doesn't claim.
String _uniqueName(String name, bool Function(String) taken) {
  var candidate = name;
  for (var i = 2; taken(candidate); i++) {
    candidate = p.join(p.dirname(name),
        '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}');
  }
  return candidate;
}

/// Password-wraps a file, or unwraps one.
typedef FileCrypt = Future<void> Function(String src, String dst, String password);

/// Zips the chat history plus every referenced media file into
/// [outPath], decrypting each one through [decrypt] on the way out.
/// Streams through disk so big media never sits in memory. With a
/// [password] the zip is sealed through [seal]. [outPath] is only
/// replaced once the new file is complete.
Future<void> exportChats(
  Iterable<Conversation> conversations,
  Future<void> Function(String src, String dst) decrypt,
  String outPath, {
  String password = '',
  required FileCrypt seal,
}) async {
  final scratch = await _scratch('tincan-export-');
  final partial = File('$outPath.part');
  try {
    final mediaNames = <String, String>{}; // sealed path -> archive name
    final used = <String>{};
    final files = <(String, String)>[]; // plaintext copy, archive name
    final convos = <Map<String, dynamic>>[];
    for (final c in conversations) {
      final j = c.toJson();
      for (final m in (j['messages'] as List).cast<Map<String, dynamic>>()) {
        final path = m['path'] as String?;
        if (path == null) continue;
        var archiveName = mediaNames[path];
        if (archiveName == null) {
          if (!await File(path).exists()) {
            m.remove('path');
            continue;
          }
          archiveName = _uniqueName('media/${p.basename(path)}', used.contains);
          used.add(archiveName);
          final tmp = p.join(scratch.path, '${files.length}');
          await decrypt(path, tmp);
          files.add((tmp, archiveName));
          mediaNames[path] = archiveName;
        }
        m['path'] = archiveName;
      }
      convos.add(j);
    }
    final index = jsonEncode({'v': 2, 'kind': _chatsKind, 'conversations': convos});
    if (password.isEmpty) {
      await _zipInIsolate(partial.path, files, index);
    } else {
      final zip = p.join(scratch.path, 'chats.zip');
      await _zipInIsolate(zip, files, index);
      await seal(zip, partial.path, password);
    }
    await partial.rename(outPath);
  } finally {
    await _dropScratch(scratch);
    if (await partial.exists()) await partial.delete().then((_) {}, onError: (_) {});
  }
}

// Top-level so the isolate closure captures only these arguments.
Future<void> _zipInIsolate(String outPath, List<(String, String)> files, String index) =>
    Isolate.run(() => _zip(outPath, files, index));

Future<void> _zip(String outPath, List<(String, String)> files, String index) async {
  final zip = ZipFileEncoder()..create(outPath);
  try {
    for (final (tmp, name) in files) {
      // Media is compressed already; deflating it again only costs time.
      final input = InputFileStream(tmp);
      zip.addArchiveFile(ArchiveFile.stream(name, input)..compression = CompressionType.none);
      await input.close();
      await File(tmp).delete();
    }
    final bytes = utf8.encode(index);
    zip.addArchiveFile(ArchiveFile('chats.json', bytes.length, bytes));
  } finally {
    await zip.close();
  }
}

/// Unpacks the chats zip at [zipPath], sealing each media file into
/// mediaDir through [seal], which picks a free name and returns it. A
/// sealed backup is opened through [open] with [password] first.
Future<List<Conversation>> importChats(
  String zipPath,
  String mediaDir,
  Future<String> Function(String src, String dir, String name) seal, {
  String password = '',
  required FileCrypt open,
}) async {
  final sealed = await isSealedBackup(zipPath);
  if (sealed && password.isEmpty) {
    throw const FormatException('This chats file is sealed; enter its backup password.');
  }
  final scratch = await _scratch('tincan-import-');
  try {
    var zip = zipPath;
    if (sealed) {
      zip = p.join(scratch.path, 'chats.zip');
      await open(zipPath, zip, password);
    }
    final (Map index, media) = await _unzipInIsolate(zip, scratch.path).catchError(
        (Object e) => throw FormatException('Not a Tincan chats file: $e'),
        test: (e) => e is! FileSystemException);
    if (sealed) await File(zip).delete();

    final List<Conversation> out;
    try {
      final legacy = (index['v'] as num? ?? 1) < 2;
      out = [
        for (final cj in (index['conversations'] as List? ?? const []))
          Conversation.fromJson((cj as Map).cast<String, dynamic>(), legacy: legacy),
      ];
    } on TypeError catch (e) {
      throw FormatException('Not a Tincan chats file: $e');
    }

    final restored = <String, String>{}; // archive name -> sealed path
    for (final (name, tmp) in media) {
      restored[name] = await seal(tmp, mediaDir, p.basename(name));
      await File(tmp).delete();
    }
    for (final c in out) {
      for (final m in c.messages) {
        if (m.path != null) m.path = restored[m.path];
      }
    }
    return out;
  } finally {
    await _dropScratch(scratch);
  }
}

Future<(Map, List<(String, String)>)> _unzipInIsolate(String zipPath, String scratch) =>
    Isolate.run(() => _unzip(zipPath, scratch));

/// The index, and each media entry's archive name with where it was
/// extracted to.
Future<(Map, List<(String, String)>)> _unzip(String zipPath, String scratch) async {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final indexFile = archive.findFile('chats.json');
    if (indexFile == null) {
      throw const FormatException('not a Tincan chats file');
    }
    final index = jsonDecode(utf8.decode(indexFile.content));
    if (index is! Map || index['kind'] != _chatsKind) {
      throw const FormatException('not a Tincan chats file');
    }
    final media = <(String, String)>[];
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith('media/')) continue;
      final tmp = p.join(scratch, '${media.length}');
      final out = OutputFileStream(tmp);
      f.writeContent(out);
      await out.close();
      media.add((f.name, tmp));
    }
    return (index, media);
  } finally {
    await input.close();
  }
}
