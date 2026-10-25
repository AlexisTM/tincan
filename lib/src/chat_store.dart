import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  /// The revision each conversation's file holds, by id.
  final _saved = <String, int>{};

  /// Ids with a file on disk, which a delete has to remove.
  final _onDisk = <String>{};

  /// Files that failed for a reason that may pass; left alone and
  /// read again on the next save.
  final _unreadable = <String>{};

  /// What couldn't be read, by what it is about; dropped once repaired.
  final _problems = <String, String>{};
  Set<String>? _indexed;
  bool _legacyPending = false;
  bool _loaded = false;
  bool _closed = false;
  Timer? _pending;
  bool _backingOff = false;
  Future<void> _writing = Future.value();
  int _failures = 0;
  String? _saveError;

  /// Why some history couldn't be read or saved; null when all is well.
  String? get error =>
      _saveError ??
      (_problems.isEmpty ? null : 'Some chat history couldn\'t be read: ${_problems.values.join('; ')}');

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

  /// Reads the history into the conversations. Never throws: a broken
  /// file falls back to its .bak, or is moved aside, one that can't be
  /// read right now is left for later, and [error] says so.
  Future<void> load() async {
    final ids = <String>{};
    try {
      final (index, fromBak) = await _readIndex();
      if (index is Map) ids.addAll((index['ids'] as List? ?? const []).cast<String>());
      // One restored from its .bak stays unset, so the next save rewrites it.
      if (index != null && !fromBak) _indexed = {...ids};
    } catch (e) {
      _problems['index'] = 'the chat index ($e)';
    }
    // The index can lag behind, or be lost; the files are the truth.
    try {
      for (final name in await _bridge.listState(_dir)) {
        if (_idFromFile(name) case final id?) ids.add(id);
      }
    } catch (e) {
      _problems['dir'] = 'the chat folder ($e)';
    }
    // Sized to the bridge's worker pool.
    final all = ids.toList();
    for (var i = 0; i < all.length; i += 3) {
      final batch = await Future.wait(all.sublist(i, min(i + 3, all.length)).map(_loadChat));
      for (final c in batch) {
        if (c != null) _conversations[c.id] = c;
      }
    }
    try {
      final raw = await _bridge.readState(_legacy);
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
      _problems['legacy'] = 'the old history file ($e)';
    }
    _loaded = true;
    if (_problems.isNotEmpty) onError?.call();
    if (_legacyPending || _conversations.values.any((c) => _saved[c.id] != c.revision)) {
      scheduleSave();
    }
    // Every good read becomes the new .bak, unless the .bak has it already.
    _writing = _writing.then((_) async {
      for (final id in _saved.keys.toList()) {
        final c = _conversations[id];
        if (c == null || !await _bakStale(fileFor(id))) continue;
        await _quietly(_bridge.writeState('${fileFor(id)}.bak', c.encoded));
      }
      if (_indexed case final ids? when await _bakStale(_indexPath)) {
        await _quietly(_bridge.writeState('$_indexPath.bak', _indexJson(ids)));
      }
    });
  }

  /// Unless the .bak was written after the file last changed.
  static Future<bool> _bakStale(String path) async {
    final (file, bak) = await (FileStat.stat(path), FileStat.stat('$path.bak')).wait;
    return bak.type == FileSystemEntityType.notFound || !bak.modified.isAfter(file.modified);
  }

  /// The index, or its .bak when the index is missing or broken, and
  /// whether it came from the .bak. Null when neither exists.
  Future<(Object?, bool)> _readIndex() async {
    Object? first;
    try {
      final v = await _bridge.readState(_indexPath);
      if (v != null) return (v, false);
    } catch (e) {
      first = e;
    }
    final Object? bak;
    try {
      bak = await _bridge.readState('$_indexPath.bak');
    } catch (e) {
      throw first ?? e;
    }
    if (bak == null) {
      if (first != null) throw first;
      return (null, false);
    }
    if (first != null) _problems['index'] = 'the chat index (restored from backup)';
    return (bak, true);
  }

  /// One chat's file, or its .bak when the file is missing or broken for
  /// good. Null when there is nothing to show.
  Future<Conversation?> _loadChat(String id) async {
    final path = fileFor(id);
    _Broken? broken;
    Conversation? convo;
    try {
      convo = await _readChat(path);
    } on _Broken catch (e) {
      broken = e;
    } catch (e) {
      return _cantRead(id, e);
    }
    var fromBak = false;
    if (convo == null) {
      try {
        convo = await _readChat('$path.bak');
        fromBak = convo != null;
      } on _Broken catch (e) {
        _problems['aside:$id'] = 'a chat (${broken ?? e})';
        if (broken != null) await _moveAside(path);
        await _moveAside('$path.bak');
        return null;
      } catch (e) {
        return _cantRead(id, e);
      }
    }
    if (convo == null) {
      if (broken != null) {
        _problems['aside:$id'] = 'a chat ($broken)';
        await _moveAside(path);
      }
      return null;
    }
    _onDisk.add(id);
    // One restored from its .bak stays unsaved, so it gets rewritten.
    if (!fromBak) {
      _saved[id] = convo.revision;
    } else if (broken != null) {
      _problems['chat:$id'] = 'a chat (restored from backup)';
    }
    return convo;
  }

  Conversation? _cantRead(String id, Object e) {
    _unreadable.add(id);
    _problems['chat:$id'] = 'a chat ($e)';
    return null;
  }

  /// Null when there is no file; throws [_Broken] when it will never read.
  Future<Conversation?> _readChat(String path) async {
    final Object? raw;
    try {
      raw = await _bridge.readState(path);
    } catch (e) {
      if (_isBroken(e)) throw _Broken(e);
      rethrow;
    }
    if (raw == null) return null;
    try {
      if (raw is! Map) throw const FormatException('not a chat');
      return Conversation.fromJson(raw.cast<String, dynamic>());
    } catch (e) {
      throw _Broken(e);
    }
  }

  // Go's words for a seal or JSON that won't ever open; anything else,
  // a locked vault or a dead worker say, may pass.
  static const _brokenSeal = [
    'message authentication failed',
    'not a sealed file',
    'ciphertext truncated',
    'MarshalJSON',
  ];

  static bool _isBroken(Object e) =>
      e is FormatException || e is BridgeException && _brokenSeal.any(e.message.contains);

  Future<void> _moveAside(String path) => _quietly(
      _bridge.renameState(path, '$path.corrupt-${DateTime.now().millisecondsSinceEpoch}'));

  static Future<void> _quietly(Future<Object?> f) => f.then((_) {}, onError: (_) {});

  /// Whether path is gone.
  Future<bool> _delete(String path) =>
      _bridge.deleteState(path).then((_) => true, onError: (_) => false);

  static String _indexJson(Set<String> ids) => jsonEncode({'v': 2, 'ids': ids.toList()});

  /// Bursts of changes collapse into one write, taken from the live
  /// conversations when the timer fires.
  void scheduleSave() {
    if (!_loaded || _closed) return;
    // A failure streak keeps its backoff; the retry takes this change too.
    if (_backingOff && (_pending?.isActive ?? false)) return;
    _pending?.cancel();
    _backingOff = false;
    _pending = Timer(const Duration(seconds: 1), flush);
  }

  /// Writes any pending change now. Writes queue behind each other so
  /// an older snapshot can never land after a newer one.
  Future<void> flush() {
    _pending?.cancel();
    _pending = null;
    _backingOff = false;
    if (!_loaded || _closed) return _writing;
    return _writing = _writing.then((_) => _save());
  }

  /// Reads again what failed before, folding it into the live chat.
  Future<void> _retryUnreadable() async {
    for (final id in _unreadable.toList()) {
      _unreadable.remove(id);
      _problems.remove('chat:$id');
      final c = await _loadChat(id);
      if (c == null) continue;
      final live = _conversations[c.id];
      if (live == null) {
        _conversations[c.id] = c;
      } else {
        live
          ..mergeFrom(c)
          ..changed();
      }
    }
  }

  Future<void> _save() async {
    final before = error;
    await _retryUnreadable();
    final live = _conversations.values.toList();
    final ids = {for (final c in live) c.id};
    Object? failure;
    for (final c in live) {
      final rev = c.revision;
      if (_saved[c.id] == rev) continue;
      // Its file holds history this copy lacks.
      if (_unreadable.contains(c.id)) {
        failure ??= 'a chat couldn\'t be read yet';
        continue;
      }
      try {
        await _bridge.writeState(fileFor(c.id), c.encoded);
        _saved[c.id] = rev;
        _onDisk.add(c.id);
        _problems.remove('chat:${c.id}');
      } catch (e) {
        failure = e;
      }
    }
    for (final id in _onDisk.where((id) => !ids.contains(id)).toList()) {
      if (await _delete(fileFor(id)) && await _delete('${fileFor(id)}.bak')) {
        _onDisk.remove(id);
        _saved.remove(id);
        _problems.remove('chat:$id');
      } else {
        failure ??= 'couldn\'t delete a chat';
      }
    }
    if (_indexed == null || !setEquals(_indexed, ids)) {
      try {
        await _bridge.writeState(_indexPath, _indexJson(ids));
        _indexed = ids;
        _problems.remove('index');
      } catch (e) {
        failure = e;
      }
    }
    if (failure == null && _legacyPending) {
      _legacyPending = false;
      await _quietly(_bridge.deleteState(_legacy));
    }
    if (failure != null) {
      stderr.writeln('tincan: saving chat history: $failure');
      _saveError = 'Chat history isn\'t saving: $failure';
      // What failed stays unsaved, so the retry picks it up.
      final delay = Duration(seconds: 2 << _failures.clamp(0, 5));
      _failures++;
      _pending?.cancel();
      if (!_closed) {
        _pending = Timer(delay, flush);
        _backingOff = true;
      }
    } else {
      _failures = 0;
      _saveError = null;
    }
    if (before != error) onError?.call();
  }

  /// Stops saving for good; completes once queued writes land. The
  /// conversations must not change before then.
  Future<void> close() {
    _closed = true;
    _pending?.cancel();
    _pending = null;
    return _writing;
  }

  void dispose() {
    unawaited(flush());
    unawaited(close());
  }
}

/// A file that will never read: a bad seal or bad JSON.
class _Broken implements Exception {
  _Broken(this.error);
  final Object error;

  @override
  String toString() => '$error';
}
