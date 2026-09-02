import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Backup files, both plaintext because they have to open on another
/// device. The account one holds the private key; treat it like a
/// password. The chats one zips the history with its media.
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

/// Zips the chat history plus every referenced media file into
/// [outPath], decrypting each one through [decrypt] on the way out.
/// Streams through disk so big media never sits in memory.
Future<void> exportChats(
  Iterable<Conversation> conversations,
  Future<void> Function(String src, String dst) decrypt,
  String outPath,
) async {
  final scratch = await Directory.systemTemp.createTemp('tincan-export-');
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
    final index = jsonEncode({'v': 1, 'kind': _chatsKind, 'conversations': convos});
    await _zipInIsolate(outPath, files, index);
  } finally {
    await scratch.delete(recursive: true);
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
/// mediaDir through [seal], which picks a free name and returns it.
Future<List<Conversation>> importChats(
  String zipPath,
  String mediaDir,
  Future<String> Function(String src, String dir, String name) seal,
) async {
  final scratch = await Directory.systemTemp.createTemp('tincan-import-');
  try {
    final (index, media) = await _unzipInIsolate(zipPath, scratch.path);
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
      out.add(Conversation.fromJson(map));
    }
    return out;
  } finally {
    await scratch.delete(recursive: true);
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
