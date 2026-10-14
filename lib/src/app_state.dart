import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'backup.dart';
import 'background.dart';
import 'bridge.dart';
import 'chat_store.dart';
import 'files.dart';
import 'images.dart';
import 'models.dart';
import 'notifier.dart';
import 'profile.dart';
import 'settings.dart';
import 'vault.dart';

class AppState extends ChangeNotifier {
  AppState(this._bridge, {Notifier? notifier}) : _notifier = notifier ?? SystemNotifier();

  final Bridge _bridge;
  final Notifier _notifier;

  /// Whether the user is looking at the app. The engine only ever
  /// starts with its window up.
  bool _foreground = true;

  @visibleForTesting
  set foreground(bool v) => _foreground = v;

  String? selfAddress;
  String selfName = '';
  String selfDescription = '';
  String selfStatus = '';
  String? selfAvatarPath; // sealed, under stateDir/avatars
  bool starting = true;
  String? _fatal;
  String? _transportError;
  String? _historyError;
  String? get startError => _fatal ?? _transportError ?? _historyError;
  AppLifecycleListener? _lifecycle;
  ChatStore? _store;
  String? _downloadDir;

  Settings settings = Settings();
  late VaultManager vault;
  LockMode? lockMode;
  late final BackgroundController _background = BackgroundController(settings);

  final conversations = <String, Conversation>{};
  final requests = <ChatRequest>[];
  final blockedPeers = <BlockedPeer>[];
  String? selectedId;
  String? _stateDir;

  final _reconnectAttempts = <String, int>{};
  final _jitter = Random();
  final _reconnectTimers = <String, Timer>{};

  /// Dials in flight, by peer, completed with an error or null.
  final _dials = <String, Completer<String?>>{};

  /// Each peer's latest dial outcome, numbered: events come by another
  /// isolate and can beat connect's own reply.
  final _outcomes = <String, (int, String?)>{};
  var _outcomeSeq = 0;

  static const _netifChannel = MethodChannel('tincan/netifs');

  Future<void> _feedInterfaces(List<dynamic>? list) async {
    try {
      if (list == null || list.isEmpty) return;
      await _bridge.setNetInterfaces(jsonEncode(list));
    } catch (e) {
      stderr.writeln('tincan: feeding interfaces: $e');
    }
  }

  /// Decrypted copies of sealed files live here, wiped every launch so
  /// plaintext never outlives the session. Sealed paths never change
  /// content (avatars are named by it), so a copy is made only once.
  String? _cacheDir;
  String? _dataDir;
  final _decrypted = <String, Future<String?>>{};
  final _media = <String, ValueNotifier<String?>>{};
  static final _noMedia = ValueNotifier<String?>(null);

  /// The displayable copy of a sealed file, null until it lands or if it
  /// can't be read. Each path has its own notifier, so only what shows
  /// that file repaints.
  ValueListenable<String?> plaintext(String? sealed) {
    if (sealed == null || sealed.isEmpty) return _noMedia;
    return _media.putIfAbsent(sealed, () {
      final n = ValueNotifier<String?>(null);
      unawaited(decryptForOpen(sealed).then((path) => n.value = path));
      return n;
    });
  }

  /// What [plaintext] holds right now.
  String? plaintextPath(String? sealed) => plaintext(sealed).value;

  /// Decrypts a sealed file into the cache, once; null if it can't be.
  Future<String?> decryptForOpen(String sealed) => _decrypted[sealed] ??= _decrypt(sealed);

  Future<String?> _decrypt(String sealed) async {
    final cache = _cacheDir, data = _dataDir;
    if (cache == null || data == null) return null;
    // Mirrors the store's layout, so the copy keeps its file name for
    // whatever app opens it.
    final dst = p.join(cache, p.isWithin(data, sealed) ? p.relative(sealed, from: data) : p.basename(sealed));
    try {
      await _bridge.decryptMedia(sealed, dst);
      return dst;
    } catch (e) {
      debugPrint('tincan: decrypting $sealed: $e');
      return null;
    }
  }

  Conversation? get selected => selectedId == null ? null : conversations[selectedId];

  List<Conversation> get ordered {
    final list = conversations.values.toList();
    list.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return list;
  }

  Future<void> init({
    required String stateDir,
    required String downloadDir,
    required VaultManager vault,
  }) async {
    try {
      _stateDir = stateDir;
      _downloadDir = downloadDir;
      this.vault = vault;
      lockMode = vault.mode;
      _dataDir = p.dirname(stateDir);
      _cacheDir = p.join(_dataDir!, 'cache');
      await _freshCache(_cacheDir!);
      _store = ChatStore(_bridge, stateDir, conversations);
      final (loaded, historyError) = await (
        Settings.load(_bridge, stateDir),
        // The store won't save until a load succeeds, so the file is safe.
        _store!.load().then<String?>((_) => null,
            onError: (Object e) => 'Chat history couldn\'t be read: $e'),
      ).wait;
      settings = loaded;
      _historyError = historyError;
      _background
        ..update(settings)
        ..start();
      // The debounced history write must not die with the app.
      _lifecycle = AppLifecycleListener(
        onStateChange: (s) {
          _foreground = s == AppLifecycleState.resumed;
          if (!_foreground) unawaited(_store?.flush());
          if (_foreground && selectedId != null) unawaited(_notifier.clear(selectedId!));
        },
        onExitRequested: () async {
          await _store?.flush();
          return AppExitResponse.exit;
        },
      );
      selfName = Platform.environment['TINCAN_NAME'] ??
          Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          'me';
      if (Platform.isAndroid) {
        // Go can't enumerate interfaces on Android; feed them in first,
        // then again on every network change.
        _netifChannel.setMethodCallHandler((call) async {
          if (call.method == 'changed') await _feedInterfaces(call.arguments as List?);
        });
        await _feedInterfaces(await _netifChannel.invokeMethod<List<dynamic>>('list'));
      }
      await _notifier.init(_openFromNotification);
      unawaited(_notifier.requestPermission());
      _bridge.events.listen(handleEvent);
      unawaited(_startTransport());
    } catch (e, st) {
      _transportError = 'Transport failed to start: $e';
      debugPrint('tincan: start failed: $e\n$st');
    }
    starting = false;
    notifyListeners();
  }

  /// Swaps in an empty cache, deleting the old one and any a crash left
  /// behind without holding up the launch.
  static Future<void> _freshCache(String dir) async {
    final cache = Directory(dir);
    if (await cache.exists()) {
      await cache.rename('$dir.old-${DateTime.now().microsecondsSinceEpoch}');
    }
    await cache.create(recursive: true);
    final stale = cache.parent
        .list()
        .where((e) => p.basename(e.path).startsWith('${p.basename(dir)}.old-'));
    unawaited(stale
        .forEach((e) => e.delete(recursive: true).then((_) {}, onError: (_) {}))
        .then((_) {}, onError: (_) {}));
  }

  /// The bridge retries a start that fails (launching offline, say) on
  /// its own and reports how that goes as events.
  Future<void> _startTransport() async {
    try {
      handleEvent(await _bridge.start(
        stateDir: _stateDir!,
        downloadDir: _downloadDir!,
        name: selfName,
        derpHost: settings.derpHost,
        derpMapUrl: settings.derpMapUrl,
      ));
    } catch (e, st) {
      _transportError = 'Transport failed to start: $e';
      // Only print reaches logcat on Android.
      debugPrint('tincan: transport start failed: $e\n$st');
    }
    try {
      await _reloadBlocked();
    } catch (e) {
      debugPrint('tincan: listing blocked peers: $e');
    }
    notifyListeners();
  }

  /// Go's roster is the authority on who is blocked.
  Future<void> _reloadBlocked() async {
    blockedPeers
      ..clear()
      ..addAll([
        for (final (peer, bname) in await _bridge.listBlocked())
          BlockedPeer(peer: peer, name: bname),
      ]);
    final ids = {for (final b in blockedPeers) b.peer};
    for (final c in conversations.values) {
      c.blocked = ids.contains(c.id);
    }
  }

  // Profile

  /// Persists the profile and pushes it to connected peers.
  /// newAvatarSource is any image file, downscaled into the picture.
  Future<String?> saveProfile({
    required String name,
    required String description,
    required String status,
    String? newAvatarSource,
  }) async {
    name = name.trim();
    if (name.isEmpty) return 'Pick a display name.';
    Directory? scratch;
    try {
      // The picture is downscaled to a scratch file the transport reads
      // once and then stores encrypted.
      var prepared = '';
      if (newAvatarSource != null) {
        scratch = await Directory.systemTemp.createTemp('tincan-avatar-');
        prepared = p.join(scratch.path, 'avatar.jpg');
        final err = await downscaleAvatar(newAvatarSource, prepared);
        if (err != null) return err;
      }
      await _bridge.setProfile(
        name: name,
        description: description.trim(),
        status: status.trim(),
        avatarPath: prepared,
        avatarChanged: newAvatarSource != null,
      );
      selfName = name;
      selfDescription = description.trim();
      selfStatus = status.trim();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    } finally {
      await scratch?.delete(recursive: true);
    }
  }

  /// Persists settings and applies them. Changing the relay restarts
  /// the transport, which changes the address; if the new relay fails
  /// while the old one works, the bridge keeps it and nothing is saved.
  Future<String?> saveSettings(Settings next) async {
    try {
      if (next.derpHost != settings.derpHost || next.derpMapUrl != settings.derpMapUrl) {
        handleEvent(await _bridge.setDerp(host: next.derpHost, mapUrl: next.derpMapUrl));
      }
      settings = next;
      if (_stateDir case final dir?) await next.save(_bridge, dir);
      _background.update(next);
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> changeLock(LockMode mode, String password) async {
    final err = await vault.changeLock(mode, password: password);
    if (err == null) {
      lockMode = mode;
      notifyListeners();
    }
    return err;
  }

  /// Desktop keeps running while its window is open, so it has no policy.
  bool get supportsBackgroundPolicy => _background.supported;

  // Backup & restore

  /// Writes identity, profile and roster to path. Contains the private key.
  Future<String?> saveAccount(String path) async {
    try {
      await _bridge.exportAccount(path);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Restarts the transport under a restored identity. History stays.
  Future<String?> restoreAccount(String path) async {
    try {
      await _bridge.importAccount(path);
      handleEvent(await _bridge.restart());
      await _reloadBlocked();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> saveChats(String path) async {
    try {
      await exportChats(conversations.values, _bridge.decryptMedia, path);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> restoreChats(String path) async {
    try {
      final imported = await importChats(path, _downloadDir!, _bridge.importMedia);
      for (final c in imported) {
        final existing = conversations[c.id];
        if (existing == null) {
          conversations[c.id] = c;
        } else {
          existing
            ..mergeFrom(c)
            ..changed();
        }
      }
      _store?.scheduleSave();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Name and address to share: the QR code, the blob, the vCard.
  ShareableProfile? get selfProfile => switch (selfAddress) {
        final addr? => ShareableProfile(name: selfName, address: addr),
        null => null,
      };

  /// Swaps in a fresh address. The old one is dead and connections drop.
  Future<String?> regenerateAddress() async {
    try {
      handleEvent(await _bridge.resetIdentity());
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  // Requests & blocking

  Future<String?> acceptRequest(String peer) async {
    try {
      await _bridge.accept(peer);
      requests.removeWhere((r) => r.peer == peer);
      notifyListeners();
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  /// Refuses a peer for good. Undo from the blocked-peers list.
  Future<String?> blockPeer(String peer) async {
    try {
      await _bridge.block(peer);
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  /// Drops a conversation and its history. The peer stays accepted, so
  /// either side can start again; blockPeer refuses them for good.
  Future<String?> deleteConversation(String peer) async {
    try {
      await _bridge.disconnect(peer);
    } on BridgeException catch (e) {
      return e.message;
    } finally {
      conversations.remove(peer);
      requests.removeWhere((r) => r.peer == peer);
      if (selectedId == peer) selectedId = null;
      _cancelReconnect(peer);
      _store?.scheduleSave();
      notifyListeners();
    }
    return null;
  }

  Future<String?> unblockPeer(String peer) async {
    try {
      await _bridge.unblock(peer);
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  void select(String? id) {
    selectedId = id;
    conversations[id]?.unread = 0;
    if (id != null) unawaited(_notifier.clear(id));
    notifyListeners();
  }

  void _openFromNotification(String peer) {
    if (conversations.containsKey(peer)) select(peer);
  }

  /// Unless the user is already reading that conversation.
  void _notifyIncoming(Conversation convo, ChatMessage msg) {
    if (_foreground && selectedId == convo.id) return;
    final line = switch (msg.kind) {
      MessageKind.text => msg.body,
      MessageKind.image => '📷 Photo',
      MessageKind.video => '🎬 Video',
      _ => '📎 ${msg.name ?? 'File'}',
    };
    unawaited(_notifier.message(convo.id, convo.name, line));
  }

  /// Dials a raw tc… address or a shared profile blob.
  Future<String?> connect(String input) async {
    final parsed = parseConnectInput(input);
    if (parsed == null) {
      return input.trim().isEmpty
          ? 'Paste an address or shared profile first.'
          : 'That doesn\'t look like a Tincan address or profile.';
    }
    try {
      final peer = await _dial(parsed.token);
      final convo = conversations[peer];
      if (convo != null) {
        convo.token = parsed.token;
        if (parsed.name case final n? when convo.name.isEmpty) convo.name = n;
        convo.changed();
        _store?.scheduleSave();
      }
      select(peer);
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  /// Dials token and waits for the outcome, returning the peer's id.
  Future<String> _dial(String token) async {
    final since = _outcomeSeq;
    final peer = await _bridge.connect(token);
    final err = switch (_outcomes[peer]) {
      (final seq, final err) when seq > since => err,
      _ => await (_dials[peer] ??= Completer()).future,
    };
    if (err != null) throw BridgeException(err);
    return peer;
  }

  void _settleDial(String peer, String? err) {
    _outcomes[peer] = (++_outcomeSeq, err);
    _dials.remove(peer)?.complete(err);
  }

  Future<void> sendText(String peerId, String body) async {
    body = body.trim();
    final convo = conversations[peerId];
    if (body.isEmpty || convo == null) return;
    final msg = ChatMessage(
      id: newMessageId(),
      outgoing: true,
      ts: DateTime.now(),
      kind: MessageKind.text,
      body: body,
      status: MessageStatus.sending,
    );
    convo.messages.add(msg);
    _changed(convo);
    try {
      await _bridge.sendText(peerId, msg.id, body);
      msg.status = MessageStatus.sent;
    } catch (_) {
      msg.status = MessageStatus.failed;
    }
    convo.changed();
    _store?.scheduleSave();
  }

  /// Resends a failed message as a fresh one at the end of the thread.
  Future<void> retry(String peerId, ChatMessage msg) async {
    final convo = conversations[peerId];
    final resendable = msg.kind == MessageKind.text || msg.path != null;
    if (convo == null ||
        msg.status != MessageStatus.failed ||
        !resendable ||
        !convo.messages.remove(msg)) {
      return;
    }
    if (msg.kind == MessageKind.text) {
      await sendText(peerId, msg.body);
    } else {
      await sendFile(peerId, msg.path!);
    }
  }

  Future<void> attachAndSendFile(String peerId) async {
    final path = await pickFile(const [mediaTypes, XTypeGroup(label: 'Any file')]);
    if (path == null) return;
    await sendFile(peerId, path);
    // The bridge holds it open by now, and keeps its own sealed copy.
    unawaited(releasePicked(path));
  }

  Future<void> sendFile(String peerId, String path) async {
    final convo = conversations[peerId];
    if (convo == null) return;
    final id = newMessageId();
    final msg = ChatMessage(
      id: id,
      outgoing: true,
      ts: DateTime.now(),
      kind: MessageKind.file,
      name: p.basename(path),
      progress: 0,
      status: MessageStatus.sending,
    );
    convo.messages.add(msg);
    _changed(convo);
    try {
      final meta = await _bridge.sendFile(peerId, id, path);
      msg
        ..kind = kindFromWire(meta.kind)
        ..name = meta.name
        ..size = meta.size
        ..path = meta.path;
    } catch (_) {
      msg.status = MessageStatus.failed;
      msg.progress.value = null;
    }
    convo.changed();
    _store?.scheduleSave();
  }

  Future<String?> reconnect(String peerId) async {
    final token = conversations[peerId]?.token;
    if (token == null) return 'This peer connected to you; they have to reconnect.';
    return connect(token);
  }

  // Reconnect policy

  /// Delay before redialing a dropped peer, given how many redials have
  /// already failed. Null means give up and leave it to the Reconnect
  /// button: 2s, 4s … 64s, about two minutes in all.
  static Duration? reconnectDelay(int attempt) =>
      attempt < 6 ? Duration(seconds: 2 << attempt) : null;

  void _scheduleReconnect(String peerId) {
    final convo = conversations[peerId];
    final token = convo?.token;
    if (convo == null || token == null || convo.blocked) return;
    final attempt = _reconnectAttempts[peerId] ?? 0;
    final delay = reconnectDelay(attempt);
    _reconnectTimers.remove(peerId)?.cancel();
    convo.reconnecting = delay != null;
    if (delay == null) return;
    // Spreads redials out; the bridge settles two that cross anyway.
    final jittered = delay * (1 + _jitter.nextDouble() / 2);
    _reconnectTimers[peerId] = Timer(jittered, () async {
      _reconnectTimers.remove(peerId);
      if (conversations[peerId]?.connected ?? true) return;
      _reconnectAttempts[peerId] = attempt + 1;
      try {
        // Not connect(): a background redial mustn't change the selection.
        await _dial(token);
      } on BridgeException {
        _scheduleReconnect(peerId);
        conversations[peerId]?.repaint();
      }
    });
  }

  void _cancelReconnect(String peerId) {
    _reconnectTimers.remove(peerId)?.cancel();
    _reconnectAttempts.remove(peerId);
  }

  // Bridge events

  static DateTime _evTs(Map<String, dynamic> ev) => switch (ev['ts']) {
        final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => DateTime.now(),
      };

  /// Whether no conversation sorts above c.
  bool _isNewest(Conversation c) =>
      conversations.values.every((o) => !o.lastActivity.isAfter(c.lastActivity));

  /// Adds an incoming message, reporting whether the list reorders.
  bool _receive(Conversation convo, ChatMessage msg) {
    final wasNewest = _isNewest(convo);
    convo.messages.add(msg);
    if (convo.id != selectedId) convo.unread++;
    return !wasNewest || !_isNewest(convo);
  }

  @visibleForTesting
  void handleEvent(Map<String, dynamic> ev) {
    var convo = conversations[ev['peer']];
    var app = true; // repaint app-wide, not just convo
    var save = false; // history changed
    switch (ev['type']) {
      case 'server-started' || 'self-profile':
        if (ev['type'] == 'server-started') {
          _transportError = null;
          stdout.writeln('tincan: listening at ${ev['address']}');
        }
        selfAddress = ev['address'] as String? ?? selfAddress;
        if (ev['name'] case final String n when n.isNotEmpty) selfName = n;
        selfDescription = ev['description'] as String? ?? selfDescription;
        selfStatus = ev['status'] as String? ?? selfStatus;
        final avatar = ev['avatarPath'] as String? ?? '';
        selfAvatarPath = avatar.isEmpty ? null : avatar;
        plaintext(selfAvatarPath); // decrypt ahead of the first paint

      case 'transport-error':
        _transportError = 'Transport failed to start: ${ev['error']}';

      case 'peer-added':
        final id = ev['peer'] as String;
        final c = convo ??= conversations[id] = Conversation(id: id, name: '');
        final name = ev['name'] as String? ?? '';
        final token = ev['token'] as String? ?? '';
        save = c.name.isEmpty ||
            (name.isNotEmpty && name != c.name) ||
            (token.isNotEmpty && token != c.token);
        if (name.isNotEmpty || c.name.isEmpty) c.name = name.isEmpty ? 'peer' : name;
        if (token.isNotEmpty) c.token = token;
        c
          ..connected = true
          ..direct = null
          ..blocked = false
          ..remotePending = ev['remotePending'] == true
          ..reconnecting = false;
        requests.removeWhere((r) => r.peer == id);
        _cancelReconnect(id);
        _settleDial(id, null);

      case 'connect-error':
        _settleDial(ev['peer'] as String, ev['error'] as String? ?? 'Couldn\'t connect.');
        return;

      case 'peer-request':
        final id = ev['peer'] as String;
        final request = ChatRequest(peer: id, name: ev['name'] as String? ?? '');
        requests
          ..removeWhere((r) => r.peer == id)
          ..add(request);
        if (!_foreground) unawaited(_notifier.request(id, request.displayName));

      case 'peer-request-gone':
        requests.removeWhere((r) => r.peer == ev['peer']);
        unawaited(_notifier.clear(ev['peer'] as String));

      case 'peer-pending' || 'peer-accepted':
        convo?.remotePending = ev['type'] == 'peer-pending';
        app = false;

      case 'peer-blocked':
        final id = ev['peer'] as String;
        requests.removeWhere((r) => r.peer == id);
        blockedPeers
          ..removeWhere((b) => b.peer == id)
          ..add(BlockedPeer(peer: id, name: ev['name'] as String? ?? ''));
        _cancelReconnect(id);
        convo
          ?..markOffline()
          ..blocked = true
          ..reconnecting = false;

      case 'peer-unblocked':
        blockedPeers.removeWhere((b) => b.peer == ev['peer']);
        convo?.blocked = false;

      case 'peer-profile':
        app = false;
        if (convo == null) return;
        final name = switch (ev['name']) {
          final String n when n.isNotEmpty => n,
          _ => convo.name,
        };
        final token = switch (ev['token']) {
          final String t when t.isNotEmpty => t,
          _ => convo.token,
        };
        final description = ev['description'] as String? ?? convo.description;
        final status = ev['status'] as String? ?? convo.statusText;
        // Profiles travel whole, so an empty path means no picture.
        final avatar = switch (ev['avatarPath']) {
          final String a when a.isNotEmpty => a,
          _ => null,
        };
        save = name != convo.name ||
            token != convo.token ||
            description != convo.description ||
            status != convo.statusText ||
            avatar != convo.avatarPath;
        if (!save) return;
        convo
          ..name = name
          ..token = token
          ..description = description
          ..statusText = status
          ..avatarPath = avatar;

      case 'peer-removed':
        app = false;
        if (convo == null) return;
        convo.markOffline();
        _scheduleReconnect(convo.id);

      case 'peer-status':
        app = false;
        if (convo == null || !convo.connected) return;
        final direct = ev['direct'] == true;
        final addr = ev['addr'] as String? ?? '';
        final relay = ev['relay'] as String? ?? '';
        final latency = switch (ev['latencyMs']) {
          final num ms when ms > 0 => ms.toInt(),
          _ => convo.latencyMs,
        };
        if (direct == convo.direct &&
            addr == convo.pathAddr &&
            relay == convo.relay &&
            latency == convo.latencyMs) {
          return;
        }
        convo
          ..direct = direct
          ..pathAddr = addr
          ..relay = relay
          ..latencyMs = latency;

      case 'message':
        if (convo == null) return;
        save = true;
        final msg = ChatMessage(
          id: ev['id'] as String? ?? newMessageId(),
          outgoing: false,
          ts: _evTs(ev),
          kind: MessageKind.text,
          body: ev['body'] as String? ?? '',
        );
        app = _receive(convo, msg);
        _notifyIncoming(convo, msg);

      case 'file-begin':
        if (convo == null) return;
        save = true;
        final msg = ChatMessage(
          id: ev['id'] as String,
          outgoing: false,
          ts: _evTs(ev),
          kind: kindFromWire(ev['kind'] as String?),
          name: ev['name'] as String?,
          size: (ev['size'] as num?)?.toInt(),
          progress: 0,
          status: MessageStatus.sending,
        );
        app = _receive(convo, msg);
        _notifyIncoming(convo, msg);

      case 'file-progress':
        final msg = convo?.messageById(ev['id'] as String);
        final size = (ev['size'] as num?)?.toInt() ?? 0;
        if (msg != null && size > 0) {
          msg.progress.value = ((ev['done'] as num).toInt() / size).clamp(0.0, 1.0);
        }
        return;

      case 'file-done':
        app = false;
        final msg = convo?.messageById(ev['id'] as String);
        if (msg == null) return;
        save = true;
        msg
          ..progress.value = null
          ..status = MessageStatus.sent
          ..path = ev['path'] as String? ?? msg.path
          ..name = ev['name'] as String? ?? msg.name
          ..size = (ev['size'] as num?)?.toInt() ?? msg.size;

      case 'send-error' || 'recv-error':
        app = false;
        final msg = convo?.messageById(ev['id'] as String);
        if (msg == null) return;
        save = true;
        msg
          ..progress.value = null
          ..status = ev['type'] == 'send-error'
              ? MessageStatus.failed
              : MessageStatus.interrupted;

      case 'fatal':
        _fatal = ev['error'] as String? ?? 'bridge crashed';
    }
    if (save) {
      convo?.changed();
      _store?.scheduleSave();
    } else {
      convo?.repaint();
    }
    if (app) notifyListeners();
  }

  /// Repaints and saves after a local change that can reorder the list.
  void _changed(Conversation convo) {
    convo.changed();
    _store?.scheduleSave();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _lifecycle?.dispose();
    _background.dispose();
    _store?.dispose();
    super.dispose();
  }
}
