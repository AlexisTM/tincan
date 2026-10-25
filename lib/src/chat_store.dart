import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'bridge.dart';
import 'models.dart';

/// Chat history inside the encrypted store: one file per conversation
/// under chats/, plus a small index, written debounced and only for what
/// changed. Each file keeps a .bak from its last good read. Media lives
/// in the media dir and is only referenced here.
class ChatStore {
  ChatStore(this._bridge, String stateDir, this._conversations, {this.onError})
      : _dir = p.join(stateDir, 'chats'),
        _legacy = p.join(stateDir, 'chats.json');

  final Bridge _bridge;
  final String _dir;
  final String _legacy;

  /// The app's live conversations, read at save time.
  final Map<String, Conversation> _conversations;

  /// Called when [error] changes.
  final VoidCallback? onError;

  /// What each conversation's file holds, by id.
  final _saved = <String, String>{};
  Set<String>? _indexed;
  bool _legacyPending = false;
  bool _loaded = false;
  Timer? _pending;
  Future<void> _writing = Future.value();
  int _failures = 0;
  String? _loadError;
  String? _saveError;

  /// Why some history couldn't be read or saved; null when all is well.
  String? get error => _saveError ?? _loadError;

  String get _indexPath => p.join(_dir, 'index.json');

  @visibleForTesting
  String fileFor(String id) =>
      p.join(_dir, '${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.json');

  static String? _idFromFile(String path) {
    final name = p.basename(path);
    if (!name.endsWith('.json') || name == 'index.json') return null;
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(name.substring(0, name.length - 5))));
    } catch (_) {
      return null;
    }
  }

  /// Reads the history into the conversations. Never throws: a file
  /// that can't be read falls back to its .bak, or is moved aside, and
  /// [error] says so. Saving works either way.
  Future<void> load() async {
    final problems = <String>[];
    await Directory(_dir).create(recursive: true).then((_) {}, onError: (_) {});
    final ids = <String>{};
    try {
      final (index, _) = await _read(_indexPath, problems);
      if (index is Map) ids.addAll((index['ids'] as List? ?? const []).cast<String>());
      if (index != null) _indexed = {...ids};
    } catch (e) {
      problems.add('the chat index ($e)');
    }
    // The index can lag behind, or be lost; the files are the truth.
    try {
      await for (final f in Directory(_dir).list()) {
        if (_idFromFile(f.path) case final id?) ids.add(id);
      }
    } on FileSystemException {
      // No dir yet.
    }
    for (final id in ids) {
      final path = fileFor(id);
      try {
        final (raw, fromBak) = await _read(path, problems, label: 'a chat');
        if (raw is! Map) continue;
        final convo = Conversation.fromJson(raw.cast<String, dynamic>());
        _conversations[convo.id] = convo;
        // One restored from its .bak is rewritten.
        if (!fromBak) _saved[convo.id] = convo.encoded;
      } catch (e) {
        problems.add('a chat ($e)');
        await _moveAside(path);
      }
    }
    try {
      final raw = _decoded(await _bridge.readState(_legacy));
      if (raw is Map) {
        for (final c in (raw['conversations'] as List? ?? const [])) {
          final convo = Conversation.fromJson((c as Map).cast<String, dynamic>(), legacy: true);
          final have = _conversations[convo.id];
          if (have == null) {
            _conversations[convo.id] = convo;
          } else {
            have
              ..mergeFrom(convo)
              ..changed();
          }
        }
        _legacyPending = true;
      }
    } catch (e) {
      // Left where it is, for a later version or by hand.
      problems.add('the old history file ($e)');
    }
    _loaded = true;
    if (problems.isNotEmpty) {
      _loadError = 'Some chat history couldn\'t be read: ${problems.join('; ')}';
      onError?.call();
    }
    if (_legacyPending || _saved.length != _conversations.length) {
      scheduleSave();
    }
    // Every good read becomes the new .bak.
    _writing = _writing.then((_) async {
      for (final id in _saved.keys.toList()) {
        await _bridge.writeState('${fileFor(id)}.bak', _saved[id]!).then((_) {}, onError: (_) {});
      }
      if (_indexed != null) {
        await _bridge.writeState('$_indexPath.bak', _indexJson(_indexed!)).then((_) {}, onError: (_) {});
      }
    });
  }

  /// The file, or its .bak when the file is missing or broken, and
  /// whether it came from the .bak. Null when neither exists.
  Future<(Object?, bool)> _read(String path, List<String> problems, {String? label}) async {
    Object? first;
    try {
      final v = _decoded(await _bridge.readState(path));
      if (v != null) return (v, false);
    } catch (e) {
      first = e;
    }
    final Object? bak;
    try {
      bak = _decoded(await _bridge.readState('$path.bak'));
    } catch (e) {
      throw first ?? e;
    }
    if (bak == null) {
      if (first != null) throw first;
      return (null, false);
    }
    if (first != null) problems.add('${label ?? 'the chat index'} (restored from backup)');
    return (bak, true);
  }

  // Written as JSON text; a store that hands the text back gets it parsed.
  static Object? _decoded(Object? v) => v is String ? jsonDecode(v) : v;

  Future<void> _moveAside(String path) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (final f in [path, '$path.bak']) {
      await File(f).rename('$f.corrupt-$stamp').then((_) {}, onError: (_) {});
    }
  }

  static String _indexJson(Set<String> ids) => jsonEncode({'v': 2, 'ids': ids.toList()});

  /// Bursts of changes collapse into one write, taken from the live
  /// conversations when the timer fires.
  void scheduleSave() {
    if (!_loaded) return;
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 1), flush);
  }

  /// Writes any pending change now. Writes queue behind each other so
  /// an older snapshot can never land after a newer one.
  Future<void> flush() {
    _pending?.cancel();
    _pending = null;
    if (!_loaded) return _writing;
    return _writing = _writing.then((_) => _save());
  }

  Future<void> _save() async {
    // Each conversation caches its own encoding until it changes.
    final snapshot = {for (final c in _conversations.values) c.id: c.encoded};
    Object? failure;
    for (final MapEntry(key: id, value: json) in snapshot.entries) {
      if (_saved[id] == json) continue;
      try {
        await _bridge.writeState(fileFor(id), json);
        _saved[id] = json;
      } catch (e) {
        failure = e;
      }
    }
    for (final id in _saved.keys.where((id) => !snapshot.containsKey(id)).toList()) {
      _saved.remove(id);
      for (final f in [fileFor(id), '${fileFor(id)}.bak']) {
        await File(f).delete().then((_) {}, onError: (_) {});
      }
    }
    final ids = snapshot.keys.toSet();
    if (_indexed == null || !setEquals(_indexed, ids)) {
      try {
        await _bridge.writeState(_indexPath, _indexJson(ids));
        _indexed = ids;
      } catch (e) {
        failure = e;
      }
    }
    if (failure == null && _legacyPending) {
      _legacyPending = false;
      await File(_legacy).delete().then((_) {}, onError: (_) {});
    }
    final before = _saveError;
    if (failure != null) {
      stderr.writeln('tincan: saving chat history: $failure');
      _saveError = 'Chat history isn\'t saving: $failure';
      // What failed stays unsaved, so the retry picks it up.
      final delay = Duration(seconds: 2 << _failures.clamp(0, 5));
      _failures++;
      _pending?.cancel();
      _pending = Timer(delay, flush);
    } else {
      _failures = 0;
      _saveError = null;
    }
    if (before != _saveError) onError?.call();
  }

  void dispose() => unawaited(flush());
}
