import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Backup files, opening on another device: plaintext, or sealed under
/// a password the user picks. The account one holds the private key.
/// The chats one zips the history with its media.
///
/// The account side lives in the transport, which holds the encryption
/// key; only the chat history is assembled here.

const _chatsKind = 'tincan-chats';

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
/// [password] the zip is sealed through [seal].
Future<void> exportChats(
  Iterable<Conversation> conversations,
  Future<void> Function(String src, String dst) decrypt,
  String outPath, {
  String password = '',
  FileCrypt? seal,
}) async {
  if (password.isNotEmpty && seal == null) throw ArgumentError('seal is required with a password');
  final scratch = await Directory.systemTemp.createTemp('tincan-export-');
  var done = false;
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
      await _zipInIsolate(outPath, files, index);
    } else {
      final zip = p.join(scratch.path, 'chats.zip');
      await _zipInIsolate(zip, files, index);
      await seal!(zip, outPath, password);
    }
    done = true;
  } finally {
    await scratch.delete(recursive: true).then((_) {}, onError: (_) {});
    if (!done) await File(outPath).delete().then((_) {}, onError: (_) {});
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
/// [password] backup is opened through [open] first.
Future<List<Conversation>> importChats(
  String zipPath,
  String mediaDir,
  Future<String> Function(String src, String dir, String name) seal, {
  String password = '',
  FileCrypt? open,
}) async {
  if (password.isNotEmpty && open == null) throw ArgumentError('open is required with a password');
  final scratch = await Directory.systemTemp.createTemp('tincan-import-');
  try {
    var zip = zipPath;
    if (password.isNotEmpty) {
      zip = p.join(scratch.path, 'chats.zip');
      await open!(zipPath, zip, password);
    }
    final (Map index, media) = await _unzipInIsolate(zip, scratch.path).catchError(
        (Object e) => throw FormatException(password.isEmpty
            ? 'Not a Tincan chats file, or it needs its password.'
            : 'Not a Tincan chats file: $e'),
        test: (e) => e is! FileSystemException);
    final legacy = (index['v'] as num? ?? 1) < 2;
    final restored = <String, String>{}; // archive name -> sealed path
    for (final (name, tmp) in media) {
      restored[name] = await seal(tmp, mediaDir, p.basename(name));
      await File(tmp).delete();
    }

    final out = <Conversation>[];
    for (final cj in (index['conversations'] as List? ?? const [])) {
      final map = (cj as Map).cast<String, dynamic>();
      for (final m in (map['messages'] as List? ?? const []).cast<Map>()) {
        final path = m['path'] as String?;
        if (path != null) {
          final abs = restored[path];
          if (abs != null) {
            m['path'] = abs;
          } else {
            m.remove('path');
          }
        }
      }
      out.add(Conversation.fromJson(map, legacy: legacy));
    }
    return out;
  } finally {
    await scratch.delete(recursive: true).then((_) {}, onError: (_) {});
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
