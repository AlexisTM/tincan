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

import 'backup.dart' as backup;
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

/// Wire cap on a text body, in UTF-8 bytes.
const maxBodyBytes = 64 * 1024;

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

  /// lockNow ran: the store is shut until [reopen].
  bool locked = false;
  bool _locking = false;
  bool _disposed = false;

  /// Another device is running this identity.
  bool identityConflict = false;

  String? _fatal;
  String? _transportError;
  String? get startError => _fatal ?? _transportError ?? _store?.error;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  ChatStore? _store;
  String? _downloadDir;

  Settings settings = Settings();
  late VaultManager vault;
  LockMode? lockMode;

  bool get canLockNow => lockMode?.lockable ?? false;
  bool get canUpgradeLock => lockMode?.upgradable ?? false;
  late final BackgroundController _background = BackgroundController(settings);

  final conversations = <String, Conversation>{};
  final requests = <ChatRequest>[];
  final blockedPeers = <BlockedPeer>[];
  String? selectedId;
  String? _stateDir;

  /// A message the open thread should scroll to and flash, as (peer, id).
  final focused = ValueNotifier<(String, String)?>(null);

  /// Bumped when a contact-request notification is tapped; the shell
  /// shows the requests.
  final requestsOpened = ValueNotifier<int>(0);

  final _reconnectAttempts = <String, int>{};
  final _jitter = Random();
  final _reconnectTimers = <String, Timer>{};
  final _dialing = <String>{};

  /// Deleted while a redial was in flight; their peer-added is refused.
  final _abandoned = <String>{};
  final _peerErrors = <String, String>{};

  /// Each peer's outbox drain, run one at a time and in order.
  final _drains = <String, Future<void>>{};

  /// Picked files waiting to go out, by message id, until sealed.
  final _sources = <String, String>{};
  Timer? _sweepTimer;
  Timer? _cacheTimer;

  /// Why the last connection to peer was refused, if it was.
  String? peerError(String peer) => _peerErrors[peer];

  /// True until the user picks a display name.
  bool get needsName => !settings.named;

  static const _netifChannel = MethodChannel('tincan/netifs');

  Future<void> _feedInterfaces(List<dynamic>? list) async {
    try {
      if (list == null || list.isEmpty) return;
      await _bridge.setNetInterfaces(jsonEncode(list));
    } catch (e) {
      stderr.writeln('tincan: feeding interfaces: $e');
    }
  }

  /// Plaintext copies of sealed files, wiped on lock, exit and long backgrounding.
  String? _cacheDir;
  String? _dataDir;
  final _decrypted = <String, Future<String?>>{};
  final _media = <String, _Media>{};
  static final _noMedia = ValueNotifier<String?>(null);
  var _cacheGen = 0;

  /// Wiped copies, decrypted again only once something shows them.
  final _stale = <String>{};

  /// The displayable copy of a sealed file, null until it lands or if it
  /// can't be read. Each path has its own notifier, so only what shows
  /// that file repaints.
  ValueListenable<String?> plaintext(String? sealed) {
    if (sealed == null || sealed.isEmpty) return _noMedia;
    if (_media[sealed] case final n?) {
      if (_stale.remove(sealed)) _fill(sealed, n);
      return n;
    }
    final n = _media[sealed] = _Media();
    _fill(sealed, n);
    return n;
  }

  void _fill(String sealed, ValueNotifier<String?> n) {
    final gen = _cacheGen;
    unawaited(decryptForOpen(sealed).then((path) {
      if (gen == _cacheGen) n.value = path;
    }));
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

  /// Drops every plaintext copy. Shown media refills on the next resume
  /// unless [forget], which is for lock.
  Future<void> _wipeCache({bool forget = false}) async {
    _cacheTimer?.cancel();
    _dropCopies(forget);
    // The text kept for stacking goes with the cache; what is shown stays
    // until lock or exit.
    unawaited(_notifier.clearAll(keepShown: !forget));
    if (_cacheDir case final dir?) {
      try {
        await _freshCache(dir);
      } catch (e) {
        debugPrint('tincan: wiping the cache: $e');
      }
    }
    // A decrypt that landed meanwhile wrote into the old dir.
    _dropCopies(forget);
    if (_foreground && !forget) _refillCache();
  }

  void _dropCopies(bool forget) {
    _cacheGen++;
    _decrypted.clear();
    for (final n in _media.values) {
      n.value = null;
    }
    if (forget) _media.clear();
    _stale
      ..clear()
      ..addAll(_media.keys);
  }

  /// Only what is on screen; the rest waits for its next [plaintext].
  void _refillCache() {
    for (final sealed in _stale.toList()) {
      final n = _media[sealed];
      if (n == null || !n.watched) continue;
      _stale.remove(sealed);
      _fill(sealed, n);
    }
  }

  /// Forgets a sealed file's plaintext copy, which goes with it.
  void _forgetPlaintext(String sealed) {
    final copy = _decrypted.remove(sealed);
    _stale.remove(sealed);
    _media.remove(sealed)?.value = null;
    unawaited(copy?.then((path) async {
      if (path != null) await File(path).delete();
    }).then((_) {}, onError: (_) {}));
  }

  Conversation? get selected => selectedId == null ? null : conversations[selectedId];

  List<Conversation> get ordered {
    final list = conversations.values.toList();
    list.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return list;
  }

  static String get _fallbackName =>
      Platform.environment['TINCAN_NAME'] ??
      Platform.environment['USER'] ??
      Platform.environment['USERNAME'] ??
      'me';

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
      _lifecycle = AppLifecycleListener(
        onStateChange: _onLifecycle,
        onExitRequested: () async {
          await _store?.flush();
          await _wipeCache(forget: true);
          return AppExitResponse.exit;
        },
      );
      selfName = _fallbackName;
      if (Platform.isAndroid || Platform.isIOS) {
        // Both redial on network changes. Go can't enumerate interfaces
        // on Android, so there they are fed in first and on every change.
        _netifChannel.setMethodCallHandler((call) async {
          switch (call.method) {
            case 'changed':
              await _feedInterfaces(call.arguments as List?);
            case 'onNetworkChanged':
              dialAll(reset: true);
          }
        });
        if (Platform.isAndroid) {
          await _feedInterfaces(await _netifChannel.invokeMethod<List<dynamic>>('list'));
        }
      }
      await _notifier.init(_openFromNotification);
      unawaited(_notifier.requestPermission());
      _eventSub = _bridge.events.listen(handleEvent);
      await _open();
      if (_notifier.takeLaunchTap() case final tap?) _openFromNotification(tap);
    } catch (e, st) {
      _transportError = 'Transport failed to start: $e';
      debugPrint('tincan: start failed: $e\n$st');
    }
    starting = false;
    notifyListeners();
  }

  /// Loads what the unlocked store holds and brings the transport up.
  Future<void> _open() async {
    await _freshCache(_cacheDir!);
    _stale.clear();
    _store = ChatStore(_bridge, _stateDir!, conversations, onError: notifyListeners);
    final (loaded, _) = await (Settings.load(_bridge, _stateDir!), _store!.load()).wait;
    settings = loaded;
    _background
      ..update(settings)
      ..start();
    sweepExpired();
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(const Duration(minutes: 1), (_) => sweepExpired());
    unawaited(_startTransport());
  }

  void _onLifecycle(AppLifecycleState s) {
    final was = _foreground;
    _foreground = s == AppLifecycleState.resumed;
    // The debounced history write must not die with the app.
    if (!_foreground) unawaited(_store?.flush());
    // The engine can come back with the same widgets, so their notifiers stay.
    if (s == AppLifecycleState.detached) {
      unawaited(_wipeCache());
    } else if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _armCacheWipe();
    }
    if (_foreground && !was) {
      _cacheTimer?.cancel();
      _refillCache();
      if (selectedId != null) unawaited(_notifier.clear(selectedId!));
      dialAll(reset: true);
    }
  }

  /// Plaintext lasts as long as the app keeps receiving in the back.
  void _armCacheWipe() {
    if (_cacheTimer?.isActive ?? false) return;
    final minutes = _background.supported ? settings.backgroundMinutes : 15;
    _cacheTimer = Timer(Duration(minutes: minutes), () => unawaited(_wipeCache()));
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
        relay: settings.relay,
        directOnly: settings.directOnly,
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

  // Lock

  /// Saves and shuts everything until the UI calls [reopen].
  Future<void> lockNow() async {
    if (locked || _locking) return;
    _locking = true;
    final store = _store;
    await store?.flush();
    // Its timers must not fire on the emptied conversations.
    await store?.close();
    _store = null;
    _sweepTimer?.cancel();
    _cancelAllReconnects();
    try {
      await _bridge.lock();
    } catch (e) {
      debugPrint('tincan: locking: $e');
    }
    locked = true;
    _locking = false;
    await _wipeCache(forget: true);
    conversations.clear();
    requests.clear();
    blockedPeers.clear();
    _peerErrors.clear();
    _sources.clear();
    _drains.clear();
    _abandoned.clear();
    _searchMemo = null;
    selectedId = null;
    selfAddress = null;
    focused.value = null;
    identityConflict = false;
    _transportError = null;
    _fatal = null;
    notifyListeners();
  }

  /// Picks up again once the vault is unlocked after [lockNow].
  Future<void> reopen() async {
    if (!locked) return;
    locked = false;
    starting = true;
    notifyListeners();
    try {
      await _open();
    } catch (e) {
      _transportError = 'Transport failed to start: $e';
    }
    starting = false;
    notifyListeners();
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
      await _markNamed();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    } finally {
      await scratch?.delete(recursive: true);
    }
  }

  Future<void> _markNamed() async {
    if (settings.named) return;
    settings.named = true;
    try {
      if (_stateDir case final dir?) await settings.save(_bridge, dir);
    } catch (e) {
      debugPrint('tincan: saving settings: $e');
    }
  }

  /// Persists settings and applies them. Changing the relay restarts
  /// the transport, which changes the address; if the new relay fails
  /// while the old one works, the bridge keeps it. What did apply is
  /// saved even when a later part fails.
  Future<String?> saveSettings(Settings next) async {
    String? err;
    try {
      if (next.relay != settings.relay) {
        handleEvent(await _bridge.setRelay(next.relay));
        settings = settings.copyWith(relay: next.relay);
      }
      if (next.directOnly != settings.directOnly) {
        await _applyDirectOnly(next.directOnly);
        settings = settings.copyWith(directOnly: next.directOnly);
      }
      next.named = next.named || settings.named;
      settings = next;
    } catch (e) {
      err = '$e';
    }
    try {
      if (_stateDir case final dir?) await settings.save(_bridge, dir);
    } catch (e) {
      err ??= '$e';
    }
    _background.update(settings);
    notifyListeners();
    return err;
  }

  /// Chat only over direct paths; the relay just introduces peers.
  Future<String?> setDirectOnly(bool on) => saveSettings(settings.copyWith(directOnly: on));

  Future<void> _applyDirectOnly(bool on) async {
    await _bridge.setDirectOnly(on);
    if (on) return;
    for (final c in conversations.values) {
      if (!c.awaitingDirect) continue;
      c
        ..awaitingDirect = false
        ..repaint();
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

  /// Writes identity, profile and roster to path. Contains the private
  /// key; a password seals it.
  Future<String?> exportAccount(String path, {String password = ''}) async {
    try {
      await _bridge.exportAccount(path, password: password);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Restarts the transport under a restored identity. History stays.
  Future<String?> importAccount(String path, {String password = ''}) async {
    try {
      await _bridge.importAccount(path, password: password);
      handleEvent(await _bridge.restart());
      await _reloadBlocked();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> exportChats(String path, {String password = ''}) async {
    try {
      await backup.exportChats(conversations.values, _bridge.decryptMedia, path,
          password: password, seal: _bridge.sealFile);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> importChats(String path, {String password = ''}) async {
    try {
      final imported = await backup.importChats(path, _downloadDir!, _bridge.importMedia,
          password: password, open: _bridge.openFile);
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

  /// Drops a request without blocking; they can ask again.
  Future<String?> ignoreRequest(String peer) async {
    try {
      await _bridge.ignore(peer);
      requests.removeWhere((r) => r.peer == peer);
      unawaited(_notifier.clear(peer));
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

  /// Drops a conversation, its history and its media. The peer stays
  /// accepted, so either side can start again; blockPeer refuses them
  /// for good.
  Future<String?> deleteConversation(String peer) async {
    try {
      await _bridge.disconnect(peer);
    } on BridgeException catch (e) {
      return e.message;
    } finally {
      if (_dialing.contains(peer)) _abandoned.add(peer);
      final convo = conversations.remove(peer);
      requests.removeWhere((r) => r.peer == peer);
      if (selectedId == peer) selectedId = null;
      _cancelReconnect(peer);
      _store?.scheduleSave();
      notifyListeners();
      if (convo != null) await _deleteMedia(convo.messages);
    }
    return null;
  }

  Future<void> _deleteMedia(Iterable<ChatMessage> msgs) async {
    for (final m in msgs) {
      _sources.remove(m.id);
      final path = m.path;
      if (path == null) continue;
      _forgetPlaintext(path);
      await File(path).delete().then((_) {}, onError: (_) {});
    }
  }

  Future<String?> unblockPeer(String peer) async {
    try {
      await _bridge.unblock(peer);
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  // Per-chat settings

  /// A local name for the peer; null or empty goes back to theirs.
  void setNickname(String peer, String? name) {
    final convo = conversations[peer];
    if (convo == null) return;
    final n = name?.trim();
    convo.nickname = n == null || n.isEmpty ? null : n;
    _changed(convo);
  }

  Future<String?> setVerified(String peer, bool verified) async {
    final convo = conversations[peer];
    if (convo == null) return null;
    try {
      await _bridge.setVerified(peer, verified);
    } on BridgeException catch (e) {
      return e.message;
    }
    convo.verified = verified;
    _changed(convo);
    return null;
  }

  /// Muted chats don't notify.
  void setMuted(String peer, bool muted) {
    final convo = conversations[peer];
    if (convo == null) return;
    convo.muted = muted;
    if (muted) unawaited(_notifier.clear(peer));
    _changed(convo);
  }

  /// Sets the chat's disappearing timer on both sides; null turns it
  /// off. Only messages from now on expire.
  Future<void> setDisappearing(String peer, Duration? d) async {
    final convo = conversations[peer];
    if (convo == null) return;
    convo
      ..disappearAfter = d == null || d <= Duration.zero ? null : d
      ..timerPending = true;
    _changed(convo);
    await _flush(peer);
  }

  DateTime? _expiry(Conversation convo) =>
      convo.disappearAfter == null ? null : DateTime.now().add(convo.disappearAfter!);

  /// Deletes expired messages and their media.
  @visibleForTesting
  void sweepExpired() {
    final now = DateTime.now();
    for (final convo in conversations.values) {
      final gone = [
        for (final m in convo.messages)
          if (m.expiresAt case final at? when !at.isAfter(now)) m,
      ];
      if (gone.isEmpty) continue;
      convo.messages.removeWhere(gone.contains);
      unawaited(_deleteMedia(gone));
      convo.changed();
      _store?.scheduleSave();
    }
  }

  // Messages

  void select(String? id) {
    selectedId = id;
    final convo = conversations[id];
    if (convo != null && convo.unread > 0) {
      convo
        ..unread = 0
        ..changed();
      _store?.scheduleSave();
    }
    if (id != null) unawaited(_notifier.clear(id));
    unawaited(_bridge.setActivePeer(id).then((_) {}, onError: (_) {}));
    notifyListeners();
  }

  /// Opens [peer] and brings [msgId] into view.
  void focusMessage(String peer, String msgId) {
    if (selectedId != peer) select(peer);
    focused.value = (peer, msgId);
  }

  void _openFromNotification(NotificationTap tap) {
    if (locked) return;
    if (!tap.request) {
      if (conversations.containsKey(tap.peer)) select(tap.peer);
    } else if (requests.any((r) => r.peer == tap.peer)) {
      requestsOpened.value++;
    }
  }

  bool _onScreen(String peer) => _foreground && selectedId == peer;

  /// Unless the user is already reading that conversation, or muted it.
  void _notifyIncoming(Conversation convo, ChatMessage msg) {
    if (convo.muted || _onScreen(convo.id)) return;
    final line = switch (msg.kind) {
      MessageKind.text => msg.body,
      MessageKind.image => '📷 Photo',
      MessageKind.video => '🎬 Video',
      _ => '📎 ${msg.name ?? 'File'}',
    };
    unawaited(_notifier.message(convo.id, convo.displayName, line));
  }

  /// Dials a raw tc… address or a shared profile blob. [verified] is for
  /// a QR code scanned in person.
  Future<String?> connect(String input, {bool verified = false}) async {
    final parsed = parseConnectInput(input);
    if (parsed == null) {
      return input.trim().isEmpty
          ? 'Paste a Tincan ID first.'
          : 'That doesn\'t look like a Tincan ID.';
    }
    try {
      final peer = await _bridge.connect(parsed.token);
      final convo = conversations[peer] ??= Conversation(id: peer, name: '');
      convo.token = parsed.token;
      if (parsed.name case final n? when convo.name.isEmpty) convo.name = n;
      if (verified && !convo.verified) {
        try {
          await _bridge.setVerified(peer, true);
          convo.verified = true;
        } on BridgeException catch (e) {
          debugPrint('tincan: marking verified: $e');
        }
      }
      convo.changed();
      _store?.scheduleSave();
      select(peer);
      return null;
    } on BridgeException catch (e) {
      return e.message;
    }
  }

  /// Queues a text; it goes out now if the peer is connected, else when
  /// they are. Returns an error, or null.
  Future<String?> sendText(String peerId, String body, {String? replyTo}) async {
    body = body.trim();
    final convo = conversations[peerId];
    if (body.isEmpty || convo == null) return null;
    if (utf8.encode(body).length > maxBodyBytes) return 'That message is too long.';
    final msg = ChatMessage(
      id: newMessageId(),
      outgoing: true,
      ts: DateTime.now(),
      kind: MessageKind.text,
      body: body,
      status: MessageStatus.queued,
      replyTo: replyTo,
      expiresAt: _expiry(convo),
    );
    convo.messages.add(msg);
    _changed(convo);
    await _flush(peerId);
    return null;
  }

  /// Sends a failed message again under the same id, so the peer never
  /// shows it twice.
  Future<void> retry(String peerId, ChatMessage msg) async {
    final convo = conversations[peerId];
    final src = _sources[msg.id];
    final resendable = msg.resendable || msg.outgoing && src != null && await File(src).exists();
    if (convo == null || msg.status != MessageStatus.failed || !resendable || !convo.messages.contains(msg)) {
      return;
    }
    msg.status = MessageStatus.queued;
    convo.changed();
    _store?.scheduleSave();
    await _flush(peerId);
  }

  /// Toggles my reaction on a message; another emoji replaces it.
  Future<void> react(String peerId, String msgId, String emoji) async {
    final convo = conversations[peerId];
    final msg = convo?.messageById(msgId);
    if (convo == null || msg == null) return;
    final next = msg.reactionOf('me') == emoji ? '' : emoji;
    msg.setReaction('me', next);
    convo.pendingReactions[msgId] = next;
    convo.changed();
    _store?.scheduleSave();
    await _flush(peerId);
  }

  /// Removes a message here only, with its media.
  Future<void> deleteForMe(String peerId, String msgId) async {
    final convo = conversations[peerId];
    final msg = convo?.messageById(msgId);
    if (convo == null || msg == null) return;
    convo.messages.remove(msg);
    convo.pendingReactions.remove(msgId);
    _changed(convo);
    await _deleteMedia([msg]);
  }

  (String, List<(Conversation, int)>, List<(Conversation, ChatMessage)>)? _searchMemo;

  /// Messages matching q in any chat, newest first.
  List<(Conversation, ChatMessage)> search(String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final seen = [for (final c in conversations.values) (c, c.revision)];
    if (_searchMemo case (final memoQ, final memoSeen, final memoHits)
        when memoQ == needle && listEquals(memoSeen, seen)) {
      return memoHits;
    }
    final hits = [
      for (final c in conversations.values)
        for (final m in c.messages)
          if (m.body.toLowerCase().contains(needle) ||
              (m.kind != MessageKind.text && (m.name?.toLowerCase().contains(needle) ?? false)))
            (c, m),
    ];
    hits.sort((a, b) => b.$2.ts.compareTo(a.$2.ts));
    final out = List<(Conversation, ChatMessage)>.unmodifiable(hits);
    _searchMemo = (needle, seen, out);
    return out;
  }

  Future<void> attachAndSendFile(String peerId) async {
    final path = await pickFile(const [mediaTypes, XTypeGroup(label: 'Any file')]);
    if (path == null) return;
    await sendFile(peerId, path);
    // The bridge holds it open by now, or keeps its own sealed copy.
    unawaited(releasePicked(path));
  }

  static MessageKind _kindOf(String path) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (imageExtensions.contains(ext)) return MessageKind.image;
    if (videoExtensions.contains(ext)) return MessageKind.video;
    return MessageKind.file;
  }

  /// Stops a file going either way. An outgoing one fails and can be
  /// retried; an incoming one is interrupted.
  Future<void> cancelTransfer(String peerId, String msgId) async {
    final convo = conversations[peerId];
    final msg = convo?.messageById(msgId);
    if (convo == null || msg == null || !msg.isMedia) return;
    try {
      await _bridge.cancelTransfer(peerId, msgId);
    } catch (e) {
      debugPrint('tincan: cancelling a transfer: $e');
    }
    _markCancelled(msg);
    convo.changed();
    _store?.scheduleSave();
  }

  static void _markCancelled(ChatMessage msg) => msg
    ..setProgress(null)
    ..status = msg.outgoing ? MessageStatus.failed : MessageStatus.interrupted;

  /// Like [sendText]: offline, a sealed copy waits in the outbox.
  Future<void> sendFile(String peerId, String path) async {
    final convo = conversations[peerId];
    if (convo == null) return;
    final msg = ChatMessage(
      id: newMessageId(),
      outgoing: true,
      ts: DateTime.now(),
      kind: _kindOf(path),
      name: p.basename(path),
      status: MessageStatus.queued,
      expiresAt: _expiry(convo),
    );
    _sources[msg.id] = path;
    convo.messages.add(msg);
    _changed(convo);
    await _flush(peerId);
    if (msg.status == MessageStatus.queued && msg.path == null) await _keepCopy(convo, msg);
  }

  /// Seals the picked file into the store, since the original may go.
  /// The source stays listed until then, so a drain meanwhile can use it.
  Future<void> _keepCopy(Conversation convo, ChatMessage msg) async {
    final src = _sources[msg.id];
    if (src == null || msg.path != null) return;
    try {
      final kept = await _bridge.importMedia(src, _downloadDir ?? p.dirname(src), p.basename(src));
      if (msg.path == null) {
        msg.path = kept;
      } else {
        // A drain sent it meanwhile, which made its own sealed copy.
        await File(kept).delete().then((_) {}, onError: (_) {});
      }
      _sources.remove(msg.id);
    } catch (e) {
      debugPrint('tincan: keeping a file: $e');
      if (msg.path == null && msg.status == MessageStatus.queued) msg.status = MessageStatus.failed;
    }
    convo.changed();
    _store?.scheduleSave();
  }

  // Outbox

  /// Sends what waits for peer, in order, behind any drain already
  /// running. [resend] also covers what went out but was never acked.
  Future<void> _flush(String peerId, {bool resend = false}) {
    final next = (_drains[peerId] ?? Future.value()).then((_) => _drain(peerId, resend));
    _drains[peerId] = next;
    return next.whenComplete(() {
      if (identical(_drains[peerId], next)) _drains.remove(peerId);
    });
  }

  static bool _offline(Object e) => e is BridgeException && e.code == 'offline';

  Future<void> _drain(String peerId, bool resend) async {
    final convo = conversations[peerId];
    if (convo == null || !convo.connected) return;
    if (convo.timerPending) {
      try {
        await _bridge.sendTimer(peerId, newMessageId(), convo.disappearAfter?.inSeconds ?? 0);
        convo.timerPending = false;
        convo.changed();
        _store?.scheduleSave();
      } catch (e) {
        debugPrint('tincan: sending timer: $e');
        // Retried next drain; it mustn't hold up the messages.
        if (_offline(e) || !convo.connected) return;
      }
    }
    bool due(ChatMessage m) =>
        m.outgoing &&
        (m.status == MessageStatus.queued ||
            (resend && (m.status == MessageStatus.sending || m.status == MessageStatus.sent)));
    for (final msg in [for (final m in convo.messages) if (due(m)) m]) {
      if (!due(msg) || !convo.messages.contains(msg)) continue;
      if (!convo.connected) return;
      msg.status = MessageStatus.sending;
      convo.changed();
      try {
        if (msg.kind == MessageKind.text) {
          await _bridge.sendText(peerId, msg.id, msg.body, replyTo: msg.replyTo);
          if (msg.status == MessageStatus.sending) msg.status = MessageStatus.sent;
        } else {
          final src = msg.path ?? _sources[msg.id];
          if (src == null) {
            msg.status = MessageStatus.failed;
            convo.changed();
            _store?.scheduleSave();
            continue;
          }
          msg.setProgress(0);
          final meta = await _bridge.sendFile(peerId, msg.id, src);
          _sources.remove(msg.id);
          msg
            ..kind = kindFromWire(meta.kind)
            ..name = meta.name
            ..size = meta.size
            ..path = meta.path;
          // file-done marks it sent.
        }
      } catch (e) {
        msg.setProgress(null);
        final gone = _offline(e) || !convo.connected;
        msg.status = gone ? MessageStatus.queued : MessageStatus.failed;
        convo.changed();
        _store?.scheduleSave();
        // The picked file may go once sendFile returns; a retry needs a copy.
        if (msg.path == null && _sources.containsKey(msg.id)) await _keepCopy(convo, msg);
        if (gone) return;
        continue;
      }
      convo.changed();
      _store?.scheduleSave();
    }
    for (final MapEntry(key: ref, value: emoji) in Map.of(convo.pendingReactions).entries) {
      if (!convo.connected) return;
      try {
        await _bridge.sendReaction(peerId, newMessageId(), ref, emoji);
      } catch (e) {
        debugPrint('tincan: sending a reaction: $e');
        if (_offline(e) || !convo.connected) return;
      }
      if (convo.pendingReactions[ref] == emoji) convo.pendingReactions.remove(ref);
      convo.changed();
      _store?.scheduleSave();
    }
  }

  // Reconnect policy

  Future<String?> reconnect(String peerId) async {
    final convo = conversations[peerId];
    final token = convo?.token;
    if (convo == null) return null;
    if (token == null) return 'They connected to you; they have to reconnect.';
    _cancelReconnect(peerId);
    return _redial(peerId);
  }

  /// 2s, 4s … 64s after each failed redial, then every 5 minutes in front.
  static Duration reconnectDelay(int attempt) =>
      attempt < 6 ? Duration(seconds: 2 << attempt) : const Duration(minutes: 5);

  /// Dials every known peer that isn't connected. [reset] starts their
  /// backoff over: the network or the app just came back.
  void dialAll({bool reset = false}) {
    if (locked) return;
    for (final c in conversations.values.toList()) {
      if (c.connected || c.blocked || c.token == null) continue;
      if (reset) _reconnectAttempts.remove(c.id);
      _reconnectTimers.remove(c.id)?.cancel();
      unawaited(_redial(c.id));
    }
  }

  /// One dial; on failure the next is scheduled. Returns the error.
  Future<String?> _redial(String peerId) async {
    final convo = conversations[peerId];
    final token = convo?.token;
    if (convo == null || token == null || convo.blocked || convo.connected) return null;
    if (_disposed || !_dialing.add(peerId)) return null;
    convo
      ..reconnecting = true
      ..repaint();
    try {
      await _bridge.connect(token);
      return null;
    } catch (e) {
      _abandoned.remove(peerId);
      convo.awaitingDirect = false;
      _reconnectAttempts[peerId] = (_reconnectAttempts[peerId] ?? 0) + 1;
      _scheduleReconnect(peerId);
      convo.repaint();
      return e is BridgeException ? e.message : '$e';
    } finally {
      _dialing.remove(peerId);
    }
  }

  void _scheduleReconnect(String peerId) {
    final convo = conversations[peerId];
    if (convo == null || convo.token == null || convo.blocked || locked || _disposed) return;
    final attempt = _reconnectAttempts[peerId] ?? 0;
    _reconnectTimers.remove(peerId)?.cancel();
    // Slow retries are for when the user is looking; resume redials.
    final slow = attempt >= 6;
    convo.reconnecting = !slow || _foreground;
    if (!convo.reconnecting) return;
    // Spreads redials out; the bridge settles two that cross anyway.
    final jittered = reconnectDelay(attempt) * (1 + _jitter.nextDouble() / 2);
    _reconnectTimers[peerId] = Timer(jittered, () {
      _reconnectTimers.remove(peerId);
      final c = conversations[peerId];
      if (c == null || c.connected) return;
      if (slow && !_foreground) {
        c
          ..reconnecting = false
          ..repaint();
        return;
      }
      unawaited(_redial(peerId));
    });
  }

  void _cancelReconnect(String peerId) {
    _reconnectTimers.remove(peerId)?.cancel();
    _reconnectAttempts.remove(peerId);
  }

  void _cancelAllReconnects() {
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
  }

  @visibleForTesting
  bool hasReconnectTimer(String peerId) => _reconnectTimers.containsKey(peerId);

  // Bridge events

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
    if (locked || _disposed) return;
    var convo = conversations[ev['peer']];
    var app = true; // repaint app-wide, not just convo
    var save = false; // history changed
    switch (ev['type']) {
      case 'server-started' || 'self-profile':
        final started = ev['type'] == 'server-started';
        if (started) {
          _transportError = null;
          stdout.writeln('tincan: listening at ${ev['address']}');
        }
        selfAddress = ev['address'] as String? ?? selfAddress;
        if (ev['name'] case final String n when n.isNotEmpty) selfName = n;
        // Someone who named themselves before onboarding asked.
        if (ev['named'] == true) unawaited(_markNamed());
        selfDescription = ev['description'] as String? ?? selfDescription;
        selfStatus = ev['status'] as String? ?? selfStatus;
        final avatar = ev['avatarPath'] as String? ?? '';
        selfAvatarPath = avatar.isEmpty ? null : avatar;
        plaintext(selfAvatarPath); // decrypt ahead of the first paint
        if (started) dialAll(reset: true);

      case 'transport-error':
        _transportError = 'Transport failed to start: ${ev['error']}';

      case 'identity-conflict':
        identityConflict = true;

      case 'peer-error':
        final id = ev['peer'] as String? ?? '';
        final body = ev['body'] as String? ?? '';
        _peerErrors[id] = body.isNotEmpty ? body : ev['code'] as String? ?? 'Connection refused.';

      case 'peer-added':
        final id = ev['peer'] as String;
        if (_abandoned.remove(id)) {
          unawaited(_bridge.disconnect(id).then((_) {}, onError: (_) {}));
          return;
        }
        final c = convo ??= conversations[id] = Conversation(id: id, name: '');
        final name = ev['name'] as String? ?? '';
        final token = ev['token'] as String? ?? '';
        final fp = ev['fp'] as String? ?? '';
        final verified = ev['verified'] as bool?;
        save = c.name.isEmpty ||
            (name.isNotEmpty && name != c.name) ||
            (token.isNotEmpty && token != c.token) ||
            (fp.isNotEmpty && fp != c.fp) ||
            (verified != null && verified != c.verified);
        if (name.isNotEmpty || c.name.isEmpty) c.name = name.isEmpty ? 'peer' : name;
        if (token.isNotEmpty) c.token = token;
        if (fp.isNotEmpty) c.fp = fp;
        if (verified != null) c.verified = verified;
        c
          ..connected = true
          ..direct = null
          ..blocked = false
          ..remotePending = ev['remotePending'] == true
          ..reconnecting = false
          ..awaitingDirect = false;
        requests.removeWhere((r) => r.peer == id);
        _peerErrors.remove(id);
        _cancelReconnect(id);
        unawaited(_flush(id, resend: true));
        if (id == selectedId) unawaited(_bridge.setActivePeer(id).then((_) {}, onError: (_) {}));

      case 'connect-error':
        // connect itself reports it.
        if (convo == null || !convo.awaitingDirect) return;
        convo.awaitingDirect = false;
        app = false;

      case 'peer-request':
        final id = ev['peer'] as String;
        final request = ChatRequest(
          peer: id,
          name: ev['name'] as String? ?? '',
          fp: ev['fp'] as String? ?? '',
          first: ev['first'] as String? ?? '',
        );
        requests
          ..removeWhere((r) => r.peer == id)
          ..add(request);
        if (!_onScreen(id)) unawaited(_notifier.request(id, request.displayName));

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
        // Cut off mid-send: it goes again, same id, on reconnect.
        for (final m in convo.messages) {
          if (m.resendable && m.status == MessageStatus.sending) {
            m
              ..status = MessageStatus.queued
              ..setProgress(null);
            save = true;
          }
        }
        _scheduleReconnect(convo.id);

      case 'peer-status':
        app = false;
        if (convo == null) return;
        // Direct-only mode: reached, but waiting for a direct path.
        if (ev['held'] case final bool held) {
          if (held == convo.awaitingDirect || held && convo.connected) return;
          convo.awaitingDirect = held;
          break;
        }
        if (!convo.connected) return;
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
        final id = ev['id'] as String? ?? newMessageId();
        // A resend after a lost ack.
        if (convo.messageById(id) != null) return;
        save = true;
        final msg = ChatMessage(
          id: id,
          outgoing: false,
          ts: DateTime.now(),
          kind: MessageKind.text,
          body: ev['body'] as String? ?? '',
          replyTo: ev['reply'] as String?,
          expiresAt: _expiry(convo),
        );
        app = _receive(convo, msg);
        _notifyIncoming(convo, msg);

      case 'react':
        app = false;
        final msg = convo?.messageById(ev['ref'] as String? ?? '');
        if (msg == null) return;
        save = true;
        msg.setReaction(convo!.id, ev['body'] as String? ?? '');

      case 'delivered':
        app = false;
        final msg = convo?.messageById(ev['id'] as String? ?? '');
        if (msg == null || !msg.outgoing || msg.status == MessageStatus.delivered) return;
        save = true;
        msg
          ..status = MessageStatus.delivered
          ..setProgress(null);

      case 'peer-timer':
        app = false;
        if (convo == null) return;
        final secs = (ev['seconds'] as num?)?.toInt() ?? 0;
        save = true;
        convo
          ..disappearAfter = secs > 0 ? Duration(seconds: secs) : null
          ..timerPending = false;

      case 'file-begin':
        if (convo == null) return;
        save = true;
        final id = ev['id'] as String;
        final existing = convo.messageById(id);
        if (existing != null) {
          // The sender resumed a broken transfer.
          app = false;
          existing
            ..status = MessageStatus.sending
            ..setProgress(0);
          break;
        }
        final msg = ChatMessage(
          id: id,
          outgoing: false,
          ts: DateTime.now(),
          kind: kindFromWire(ev['kind'] as String?),
          name: ev['name'] as String?,
          size: (ev['size'] as num?)?.toInt(),
          progress: 0,
          status: MessageStatus.sending,
          expiresAt: _expiry(convo),
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
          ..setProgress(null)
          ..status = msg.status == MessageStatus.delivered ? MessageStatus.delivered : MessageStatus.sent
          ..path = ev['path'] as String? ?? msg.path
          ..name = ev['name'] as String? ?? msg.name
          ..size = (ev['size'] as num?)?.toInt() ?? msg.size;

      case 'transfer-cancelled':
        app = false;
        final msg = convo?.messageById(ev['id'] as String? ?? '');
        if (msg == null) return;
        save = true;
        _markCancelled(msg);

      case 'send-error' || 'recv-error':
        app = false;
        final msg = convo?.messageById(ev['id'] as String);
        if (msg == null) return;
        save = true;
        msg
          ..setProgress(null)
          ..status = switch (ev['type']) {
            'recv-error' => MessageStatus.interrupted,
            // Dropped with the connection: it resumes on reconnect. Go
            // reports it before peer-removed.
            _ when msg.path != null &&
                    (!convo!.connected || '${ev['error']}'.contains('connection closed')) =>
              MessageStatus.queued,
            _ => MessageStatus.failed,
          };

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
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAllReconnects();
    _sweepTimer?.cancel();
    _cacheTimer?.cancel();
    unawaited(_eventSub?.cancel());
    _lifecycle?.dispose();
    _background.dispose();
    _store?.dispose();
    focused.dispose();
    requestsOpened.dispose();
    unawaited(_wipeCache(forget: true));
    super.dispose();
  }
}

class _Media extends ValueNotifier<String?> {
  _Media() : super(null);

  bool get watched => hasListeners;
}
