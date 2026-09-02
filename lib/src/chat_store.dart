import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bridge.dart';
import 'models.dart';

/// Chat history in one file inside the encrypted store, written
/// debounced. Media lives in the media dir and is only referenced here.
class ChatStore {
  ChatStore(this._bridge, String stateDir, this._conversations)
      : _path = p.join(stateDir, 'chats.json');

  final Bridge _bridge;
  final String _path;

  /// The app's live conversations, read at save time.
  final Map<String, Conversation> _conversations;
  Timer? _pending;
  bool _dirty = false;
  Future<void> _writing = Future.value();
  bool _loaded = false;

  /// Reads the history into the conversations. Throws if it exists but
  /// can't be read; saving stays off until a load succeeds, so a failed
  /// read never overwrites it.
  Future<void> load() async {
    final raw = await _bridge.readState(_path);
    if (raw != null) {
      for (final c in ((raw as Map)['conversations'] as List? ?? const [])) {
        final convo = Conversation.fromJson((c as Map).cast<String, dynamic>());
        _conversations[convo.id] = convo;
      }
    }
    _loaded = true;
  }

  /// Bursts of changes collapse into one write, taken from the live
  /// conversations when the timer fires.
  void scheduleSave() {
    if (!_loaded) return;
    _dirty = true;
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 1), flush);
  }

  /// Writes any pending change now. Writes queue behind each other so
  /// an older snapshot can never land after a newer one.
  Future<void> flush() {
    _pending?.cancel();
    _pending = null;
    if (!_dirty) return _writing;
    _dirty = false;
    // Each conversation caches its own encoding until it changes.
    final json = '{"v":1,"conversations":[${_conversations.values.map((c) => c.encoded).join(',')}]}';
    return _writing = _writing.then((_) async {
      try {
        await _bridge.writeState(_path, json);
      } catch (e) {
        stderr.writeln('tincan: saving chat history: $e');
      }
    });
  }

  void dispose() => unawaited(flush());
}
