import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/app_state.dart';
import 'package:tincan/src/bridge.dart';
import 'package:tincan/src/chat_store.dart';
import 'package:tincan/src/models.dart';
import 'package:tincan/src/notifier.dart';
import 'package:tincan/src/settings.dart';
import 'package:tincan/src/vault.dart';

class FakeBridge implements Bridge {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final sentTexts = <(String, String, String)>[];
  bool failSends = false;
  BridgeException? sendError;

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String relay = '',
    bool directOnly = false,
  }) async {
    startedDirectOnly = directOnly;
    return {'type': 'server-started', 'address': 'tcTESTADDR'};
  }

  bool? startedDirectOnly;
  final directOnlyCalls = <bool>[];
  final cancels = <(String, String)>[];

  @override
  Future<void> setDirectOnly(bool on) async => directOnlyCalls.add(on);

  @override
  Future<void> cancelTransfer(String peer, String id) async => cancels.add((peer, id));

  @override
  Future<String> connect(String token) async => 'nodekey:peer1';

  @override
  Future<void> sendText(String peer, String id, String body, {String? replyTo}) async {
    if (failSends) throw sendError ?? BridgeException('peer gone');
    sentTexts.add((peer, id, body));
    if (replyTo != null) replies[id] = replyTo;
  }

  final replies = <String, String>{};
  final reactions = <(String, String, String, String)>[];
  final timers = <(String, String, int)>[];

  @override
  Future<void> sendReaction(String peer, String id, String ref, String emoji) async {
    if (failSends) throw BridgeException('peer gone');
    reactions.add((peer, id, ref, emoji));
  }

  @override
  Future<void> sendTimer(String peer, String id, int seconds) async {
    if (failSends) throw BridgeException('peer gone');
    timers.add((peer, id, seconds));
  }

  final sentFiles = <(String, String)>[];

  @override
  Future<FileMeta> sendFile(String peer, String id, String path) async {
    sentFiles.add((peer, id));
    return const FileMeta('pic.png', 'image', 42, '/media/pic.png');
  }

  final accepted = <String>[];
  final blocked = <String>[];
  final unblocked = <String>[];

  final profiles = <Map<String, String>>[];

  @override
  Future<void> setProfile({
    required String name,
    String description = '',
    String status = '',
    String avatarPath = '',
    bool avatarChanged = false,
  }) async {
    profiles.add({'name': name, 'description': description, 'status': status});
  }

  @override
  Future<Map<String, dynamic>> resetIdentity() async =>
      {'type': 'server-started', 'address': 'tcNEWADDR'};

  @override
  Future<Map<String, dynamic>> restart() async =>
      {'type': 'server-started', 'address': 'tcRESTORED'};

  @override
  Future<void> setNetInterfaces(String json) async {}

  final states = <String, Object>{};

  @override
  Future<({bool exists, String mode})> vaultStatus(String stateDir) async =>
      (exists: true, mode: 'password');

  @override
  Future<void> vaultCreate({
    required String stateDir,
    required String secret,
    required String mode,
  }) async {}

  @override
  Future<void> vaultUnlock({required String stateDir, required String secret}) async {}

  @override
  Future<void> vaultChangeSecret({required String secret, required String mode}) async {}

  // Like the real bridge, hands back parsed JSON.
  @override
  Future<Object?> readState(String path) async => switch (states[path]) {
        final String text => jsonDecode(text),
        final v => v,
      };

  @override
  Future<void> writeState(String path, Object json) async => states[path] = json;

  @override
  Future<void> deleteState(String path) async => states.remove(path);

  @override
  Future<List<String>> listState(String dir) async => [
        for (final k in states.keys)
          if (k.startsWith('$dir/') && !k.substring(dir.length + 1).contains('/'))
            k.substring(dir.length + 1),
      ];

  @override
  Future<void> renameState(String src, String dst) async {
    if (states.remove(src) case final v?) states[dst] = v;
  }

  @override
  Future<void> decryptMedia(String src, String dst) async {}

  @override
  Future<String> importMedia(String src, String dir, String name) async => '$dir/$name';

  @override
  Future<void> exportAccount(String dst, {String password = ''}) async {}

  @override
  Future<void> importAccount(String src, {String password = ''}) async {}

  @override
  Future<void> sealFile(String src, String dst, String password) async {}

  @override
  Future<void> openFile(String src, String dst, String password) async {}

  final ignored = <String>[];
  final verified = <String, bool>{};
  String? activePeer;
  int locks = 0;

  @override
  Future<void> ignore(String peer) async => ignored.add(peer);

  @override
  Future<void> setVerified(String peer, bool v) async => verified[peer] = v;

  @override
  Future<void> setActivePeer(String? peer) async => activePeer = peer;

  final calls = <String>[];

  /// Runs as the transport stops, before the fake says it has.
  void Function()? onStop;

  @override
  Future<void> stopTransport() async {
    calls.add('stop');
    onStop?.call();
    await pumpEventQueue();
  }

  @override
  Future<void> lock() async {
    calls.add('lock');
    locks++;
  }



  final disconnected = <String>[];

  String? relay;
  final relayCalls = <String>[];

  @override
  Future<Map<String, dynamic>> setRelay(String host) async {
    relayCalls.add(host);
    if (host == 'bad.example') throw BridgeException('no such relay');
    relay = host;
    return {'type': 'server-started', 'address': 'tcRELAY'};
  }

  @override
  Future<void> disconnect(String peer) async => disconnected.add(peer);

  @override
  Future<void> accept(String peer) async => accepted.add(peer);

  @override
  Future<void> block(String peer) async => blocked.add(peer);

  @override
  Future<void> unblock(String peer) async => unblocked.add(peer);

  @override
  Future<List<(String, String)>> listBlocked() async => const [];
}

class FakeNotifier implements Notifier {
  final shown = <(String, String, String)>[];
  final cleared = <String>[];

  NotificationTap? launch;
  int clearedAll = 0;

  @override
  Future<void> init(void Function(NotificationTap tap) onOpen) async {}

  @override
  NotificationTap? takeLaunchTap() {
    final tap = launch;
    launch = null;
    return tap;
  }

  @override
  Future<void> clearAll({bool keepShown = false}) async => clearedAll++;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> message(String peer, String title, String line) async =>
      shown.add((peer, title, line));

  @override
  Future<void> request(String peer, String name) async => shown.add((peer, 'request', name));

  @override
  Future<void> clear(String peer) async => cleared.add(peer);
}

/// Records dials, and fails them on demand.
class _DialBridge extends FakeBridge {
  final dialed = <String>[];
  String? failWith;

  @override
  Future<String> connect(String token) async {
    dialed.add(token);
    if (failWith case final err?) throw BridgeException(err);
    return 'nodekey:peer1';
  }
}

/// A store whose reads and writes can break.
class _FlakyBridge extends FakeBridge {
  int failWrites = 0;
  final unreadable = <String>{};

  @override
  Future<Object?> readState(String path) async {
    if (unreadable.contains(path)) throw BridgeException('chacha20poly1305: message authentication failed');
    return super.readState(path);
  }

  @override
  Future<void> writeState(String path, Object json) async {
    if (failWrites > 0) {
      failWrites--;
      throw BridgeException('disk full');
    }
    await super.writeState(path, json);
  }
}

void main() {
  late FakeBridge bridge;
  late FakeNotifier notifier;
  late AppState state;

  setUp(() {
    bridge = FakeBridge();
    notifier = FakeNotifier();
    state = AppState(bridge, notifier: notifier);
  });

  tearDown(() => state.dispose());

  ChatMessage text(String id, String body, {bool out = false, DateTime? ts}) => ChatMessage(
      id: id, outgoing: out, ts: ts ?? DateTime(2026), kind: MessageKind.text, body: body);

  test('peer lifecycle drives conversation state', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'outgoing': true, 'token': 'tcX'});
    final convo = state.conversations['nk:1']!;
    expect(convo.connected, isTrue);
    expect(convo.name, 'nia');
    expect(convo.token, 'tcX');
    expect(state.selectedId, isNull); // only the user selects

    state.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'direct': true, 'addr': '1.2.3.4:99', 'latencyMs': 14});
    expect(convo.direct, isTrue);
    expect(convo.latencyMs, 14);

    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1', 'reason': 'EOF'});
    expect(convo.connected, isFalse);
    expect(convo.direct, isNull);
  });

  test('incoming text lands in the right conversation and counts unread', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:2', 'name': 'sam'});
    state.select('nk:2');
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1000, 'body': 'hey', 'reply': 'm0'});
    final convo = state.conversations['nk:1']!;
    expect(convo.messages.single.body, 'hey');
    expect(convo.messages.single.outgoing, isFalse);
    expect(convo.messages.single.replyTo, 'm0');
    expect(convo.unread, 1);
    expect(state.conversations['nk:2']!.unread, 0);
  });

  test('incoming messages are stamped when they arrive, not when sent', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    final before = DateTime.now();
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1000, 'body': 'hey'});
    expect(state.conversations['nk:1']!.messages.single.ts.isBefore(before), isFalse);
  });

  test('a resent message is shown once', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'hey'});
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'hey'});
    final convo = state.conversations['nk:1']!;
    expect(convo.messages, hasLength(1));
    expect(convo.unread, 1);
    expect(notifier.shown, hasLength(1));
  });

  test('file receive: begin, progress, done; a resumed transfer reuses its bubble', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({
      'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'ts': 1000,
      'name': 'ridge.jpg', 'size': 100, 'kind': 'image',
    });
    final msg = state.conversations['nk:1']!.messageById('f1')!;
    expect(msg.kind, MessageKind.image);
    expect(msg.progress.value, 0);

    state.handleEvent({'type': 'file-progress', 'peer': 'nk:1', 'id': 'f1', 'done': 50, 'size': 100});
    expect(msg.progress.value, 0.5);
    state.handleEvent({'type': 'recv-error', 'peer': 'nk:1', 'id': 'f1'});
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'name': 'ridge.jpg', 'size': 100, 'kind': 'image'});
    expect(state.conversations['nk:1']!.messages, [msg]);

    state.handleEvent({
      'type': 'file-done', 'peer': 'nk:1', 'id': 'f1',
      'path': '/tmp/ridge.jpg', 'name': 'ridge.jpg', 'size': 100,
    });
    expect(msg.progress.value, isNull);
    expect(msg.path, '/tmp/ridge.jpg');
    expect(msg.status, MessageStatus.sent);
  });

  test('sendText goes out at once when connected and marks failures', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await state.sendText('nk:1', 'hello');
    final convo = state.conversations['nk:1']!;
    expect(convo.messages.single.status, MessageStatus.sent);
    expect(bridge.sentTexts.single.$3, 'hello');

    bridge.failSends = true;
    await state.sendText('nk:1', 'again');
    expect(convo.messages.last.status, MessageStatus.failed);
    expect(await state.sendText('nk:1', 'x' * (maxBodyBytes + 1)), isNotNull);
  });

  test('offline texts queue, then flush in order on reconnect and get delivered', () async {
    state.conversations['nk:1'] = Conversation(id: 'nk:1', name: 'nia', token: 'tcX');
    await state.sendText('nk:1', 'one');
    await state.sendText('nk:1', 'two', replyTo: 'm0');
    final convo = state.conversations['nk:1']!;
    expect(convo.messages.map((m) => m.status), [MessageStatus.queued, MessageStatus.queued]);
    expect(bridge.sentTexts, isEmpty);

    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await pumpEventQueue();
    expect(bridge.sentTexts.map((t) => t.$3), ['one', 'two']);
    expect(bridge.replies[convo.messages.last.id], 'm0');
    expect(convo.messages.map((m) => m.status), [MessageStatus.sent, MessageStatus.sent]);

    state.handleEvent({'type': 'delivered', 'peer': 'nk:1', 'id': convo.messages.first.id});
    expect(convo.messages.first.status, MessageStatus.delivered);
  });

  test('unacked messages go again under the same id after a reconnect', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await state.sendText('nk:1', 'acked');
    await state.sendText('nk:1', 'lost');
    final convo = state.conversations['nk:1']!;
    state.handleEvent({'type': 'delivered', 'peer': 'nk:1', 'id': convo.messages.first.id});
    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    bridge.sentTexts.clear();
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await pumpEventQueue();
    expect(bridge.sentTexts.single.$2, convo.messages.last.id);
  });

  test('retry resends a failed text under its own id', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    bridge.failSends = true;
    await state.sendText('nk:1', 'hello');
    final convo = state.conversations['nk:1']!;
    final msg = convo.messages.single;
    bridge.failSends = false;
    await state.retry('nk:1', msg);
    expect(convo.messages.single.status, MessageStatus.sent);
    expect(bridge.sentTexts.last.$2, msg.id);
  });

  test('chat requests buffer until accepted, ignored or refused', () async {
    state.handleEvent({'type': 'peer-request', 'peer': 'nk:1', 'name': 'nia', 'fp': '1234 5678', 'first': 'hi!'});
    expect(state.requests.single.name, 'nia');
    expect(state.requests.single.first, 'hi!');
    expect(state.requests.single.fp, '1234 5678');
    expect(state.conversations, isEmpty);

    await state.acceptRequest('nk:1');
    expect(bridge.accepted, ['nk:1']);
    expect(state.requests, isEmpty);
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(state.conversations['nk:1']!.connected, isTrue);

    state.handleEvent({'type': 'peer-request', 'peer': 'nk:3', 'name': 'dee'});
    expect(await state.ignoreRequest('nk:3'), isNull);
    expect(bridge.ignored, ['nk:3']);
    expect(bridge.blocked, isEmpty);
    expect(state.requests, isEmpty);

    state.handleEvent({'type': 'peer-request', 'peer': 'nk:2', 'name': 'sam'});
    await state.blockPeer('nk:2');
    expect(bridge.blocked, ['nk:2']);
    state.handleEvent({'type': 'peer-blocked', 'peer': 'nk:2', 'name': 'sam'});
    expect(state.requests, isEmpty);
    expect(state.blockedPeers.single.name, 'sam');

    state.handleEvent({'type': 'peer-unblocked', 'peer': 'nk:2'});
    expect(state.blockedPeers, isEmpty);
  });

  test('blocking a live conversation disconnects and is undoable', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'peer-blocked', 'peer': 'nk:1', 'name': 'nia'});
    final convo = state.conversations['nk:1']!;
    expect(convo.blocked, isTrue);
    expect(convo.connected, isFalse);
    state.handleEvent({'type': 'peer-unblocked', 'peer': 'nk:1'});
    expect(convo.blocked, isFalse);
  });

  test('remote pending gates until the peer accepts', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'outgoing': true});
    final convo = state.conversations['nk:1']!;
    state.handleEvent({'type': 'peer-pending', 'peer': 'nk:1'});
    expect(convo.remotePending, isTrue);
    state.handleEvent({'type': 'peer-accepted', 'peer': 'nk:1'});
    expect(convo.remotePending, isFalse);
  });

  test('peer-profile updates name, bio, status, and picture; a nickname wins', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'fp': '0000 1111', 'verified': true});
    state.handleEvent({
      'type': 'peer-profile', 'peer': 'nk:1',
      'name': 'Nia O.', 'description': 'ridge person', 'status': 'offline sundays',
      'avatarPath': '/tmp/a.img',
    });
    final convo = state.conversations['nk:1']!;
    expect(convo.name, 'Nia O.');
    expect(convo.fp, '0000 1111');
    expect(convo.verified, isTrue);
    expect(convo.description, 'ridge person');
    expect(convo.statusText, 'offline sundays');
    expect(convo.avatarPath, '/tmp/a.img');

    state.setNickname('nk:1', ' Nia from climbing ');
    state.handleEvent({'type': 'peer-profile', 'peer': 'nk:1', 'name': 'Totally Someone Else'});
    expect(convo.displayName, 'Nia from climbing');
    state.setNickname('nk:1', '');
    expect(convo.displayName, 'Totally Someone Else');
  });

  test('deleting a conversation disconnects, forgets it and its media', () async {
    final dir = Directory.systemTemp.createTempSync('tc-del-');
    addTearDown(() => dir.delete(recursive: true));
    final media = File('${dir.path}/pic.jpg')..writeAsStringSync('x');
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'name': 'pic.jpg', 'kind': 'image'});
    state.handleEvent({'type': 'file-done', 'peer': 'nk:1', 'id': 'f1', 'path': media.path});
    expect(await state.deleteConversation('nk:1'), isNull);
    expect(bridge.disconnected, ['nk:1']);
    expect(state.conversations, isEmpty);
    expect(state.selectedId, isNull);
    expect(media.existsSync(), isFalse);
  });

  test('delete for me drops one message and its media', () async {
    final dir = Directory.systemTemp.createTempSync('tc-del-');
    addTearDown(() => dir.delete(recursive: true));
    final media = File('${dir.path}/pic.jpg')..writeAsStringSync('x');
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'keep'});
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'name': 'pic.jpg', 'kind': 'image'});
    state.handleEvent({'type': 'file-done', 'peer': 'nk:1', 'id': 'f1', 'path': media.path});
    await state.deleteForMe('nk:1', 'f1');
    expect(state.conversations['nk:1']!.messages.map((m) => m.id), ['m1']);
    expect(media.existsSync(), isFalse);
  });

  test('a peer profile teaches us their address so we can redial', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'outgoing': false});
    expect(state.conversations['nk:1']!.token, isNull);
    state.handleEvent({
      'type': 'peer-profile', 'peer': 'nk:1', 'name': 'nia', 'token': 'tcTHEIRS',
    });
    expect(state.conversations['nk:1']!.token, 'tcTHEIRS');
  });

  test('regenerateAddress swaps the announced address', () async {
    expect(await state.regenerateAddress(), isNull);
    expect(state.selfAddress, 'tcNEWADDR');
  });

  test('a send that breaks with the connection resumes on reconnect', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    final convo = state.conversations['nk:1']!;
    convo.messages.add(ChatMessage(
        id: 'f1', outgoing: true, ts: DateTime(2026), kind: MessageKind.video,
        path: '/media/v.mp4', status: MessageStatus.sending));
    state.handleEvent({'type': 'send-error', 'peer': 'nk:1', 'id': 'f1', 'error': 'bad file'});
    expect(convo.messageById('f1')!.status, MessageStatus.failed);

    convo.messageById('f1')!.status = MessageStatus.sending;
    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    state.handleEvent({'type': 'send-error', 'peer': 'nk:1', 'id': 'f1', 'error': 'conn reset'});
    expect(convo.messageById('f1')!.status, MessageStatus.queued);
  });

  test('a broken incoming transfer is interrupted, not retryable', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'ts': 1, 'name': 'v.mp4', 'kind': 'video'});
    state.handleEvent({'type': 'recv-error', 'peer': 'nk:1', 'id': 'f1'});
    final convo = state.conversations['nk:1']!;
    final msg = convo.messageById('f1')!;
    expect(msg.status, MessageStatus.interrupted);
    await state.retry('nk:1', msg);
    expect(convo.messages, [msg]);
    expect(msg.status, MessageStatus.interrupted);
  });

  test('connect returns once the dial lands, or why it did not', () async {
    final dials = _DialBridge();
    final s = AppState(dials, notifier: notifier);
    expect(await s.connect('tcPEER'), isNull);
    expect(s.selectedId, 'nodekey:peer1');
    expect(s.conversations['nodekey:peer1']!.token, 'tcPEER');
    expect(dials.activePeer, 'nodekey:peer1');

    dials.failWith = 'peer unreachable';
    expect(await s.connect('tcPEER'), 'peer unreachable');
  });

  test('a scanned QR marks the contact verified', () async {
    expect(await state.connect('tcPEER', verified: true), isNull);
    expect(bridge.verified['nodekey:peer1'], isTrue);
    expect(state.conversations['nodekey:peer1']!.verified, isTrue);
    expect(await state.setVerified('nodekey:peer1', false), isNull);
    expect(state.conversations['nodekey:peer1']!.verified, isFalse);
  });

  test('redials back off from 2s to 64s, then keep going every 5 minutes', () {
    expect([for (var i = 0; i < 8; i++) AppState.reconnectDelay(i).inSeconds],
        [2, 4, 8, 16, 32, 64, 300, 300]);
  });

  test('a dropped dialed peer shows as reconnecting until it is back', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'token': 'tcX'});
    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    final convo = state.conversations['nk:1']!;
    expect(convo.reconnecting, isTrue);
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(convo.reconnecting, isFalse);
  });

  test('server start dials every known peer, a failure schedules the next try', () async {
    final dials = _DialBridge()..failWith = 'unreachable';
    final s = AppState(dials, notifier: notifier);
    s.conversations['nk:1'] = Conversation(id: 'nk:1', name: 'nia', token: 'tcA');
    s.conversations['nk:2'] = Conversation(id: 'nk:2', name: 'sam'); // no way back
    s.conversations['nk:3'] = Conversation(id: 'nk:3', name: 'dee', token: 'tcC')..blocked = true;
    s.handleEvent({'type': 'server-started', 'address': 'tcME'});
    await pumpEventQueue();
    expect(dials.dialed, ['tcA']);
    expect(s.hasReconnectTimer('nk:1'), isTrue);
    expect(s.conversations['nk:1']!.reconnecting, isTrue);
    s.dispose();
  });

  test('status pings repaint only their conversation, and only on change', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    var app = 0, convo = 0;
    state.addListener(() => app++);
    state.conversations['nk:1']!.addListener(() => convo++);
    final ping = {'type': 'peer-status', 'peer': 'nk:1', 'direct': true, 'latencyMs': 9};
    state.handleEvent(ping);
    state.handleEvent(ping);
    expect((app, convo), (0, 1));
  });

  test('a message repaints the app only when the list reorders', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:2', 'name': 'sam'});
    state.handleEvent({'type': 'message', 'peer': 'nk:2', 'id': 'm0', 'body': 'first'});
    var app = 0;
    state.addListener(() => app++);
    state.handleEvent({'type': 'message', 'peer': 'nk:2', 'id': 'm1', 'body': 'still on top'});
    expect(app, 0);
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm2', 'body': 'overtakes'});
    expect(app, 1);
  });

  test('reactions toggle, one per person, and offline ones wait', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'hey'});
    final msg = state.conversations['nk:1']!.messageById('m1')!;
    await state.react('nk:1', 'm1', '👍');
    state.handleEvent({'type': 'react', 'peer': 'nk:1', 'id': 'r1', 'ref': 'm1', 'body': '👍'});
    expect(msg.reactions, {'👍': {'me', 'nk:1'}});
    await state.react('nk:1', 'm1', '👍');
    state.handleEvent({'type': 'react', 'peer': 'nk:1', 'id': 'r2', 'ref': 'm1', 'body': '😂'});
    expect(msg.reactions, {'😂': {'nk:1'}});
    expect(bridge.reactions.map((r) => r.$4), ['👍', '']);

    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    await state.react('nk:1', 'm1', '❤️');
    expect(bridge.reactions, hasLength(2));
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await pumpEventQueue();
    expect(bridge.reactions.last.$3, 'm1');
    expect(bridge.reactions.last.$4, '❤️');
  });

  test('search finds messages across chats, newest first', () {
    final a = state.conversations['nk:1'] = Conversation(id: 'nk:1', name: 'nia');
    final b = state.conversations['nk:2'] = Conversation(id: 'nk:2', name: 'sam');
    a.messages.add(text('a1', 'Ridge walk', ts: DateTime(2026, 1, 1)));
    b.messages.add(text('b1', 'the ridge again', ts: DateTime(2026, 2, 1)));
    b.messages.add(text('b2', 'nothing here', ts: DateTime(2026, 3, 1)));
    expect(state.search('RIDGE').map((h) => h.$2.id), ['b1', 'a1']);
    expect(state.search('  '), isEmpty);
  });

  test('muted chats stay quiet', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.setMuted('nk:1', true);
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'psst'});
    expect(notifier.shown, isEmpty);
    expect(state.conversations['nk:1']!.unread, 1);
  });

  test('disappearing timer syncs both ways and the sweep deletes expired media', () async {
    final dir = Directory.systemTemp.createTempSync('tc-exp-');
    addTearDown(() => dir.delete(recursive: true));
    final media = File('${dir.path}/pic.jpg')..writeAsStringSync('x');
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    final convo = state.conversations['nk:1']!;
    convo.messages.add(text('old', 'before the timer'));
    await state.setDisappearing('nk:1', const Duration(hours: 1));
    expect(bridge.timers.single.$3, 3600);
    expect(convo.timerPending, isFalse);

    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'body': 'soon gone'});
    expect(convo.messageById('m1')!.expiresAt, isNotNull);
    state.handleEvent({'type': 'peer-timer', 'peer': 'nk:1', 'id': 't', 'seconds': 0});
    expect(convo.disappearAfter, isNull);

    convo.messages.add(ChatMessage(
        id: 'f1', outgoing: false, ts: DateTime(2026), kind: MessageKind.image,
        path: media.path, expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
    convo.messageById('m1')!.expiresAt = DateTime(2000);
    state.sweepExpired();
    await pumpEventQueue();
    expect(convo.messages.map((m) => m.id), ['old']);
    expect(media.existsSync(), isFalse);
  });

  test('identity conflicts and refused connections are surfaced', () {
    state.handleEvent({'type': 'identity-conflict'});
    expect(state.identityConflict, isTrue);
    state.handleEvent({'type': 'peer-error', 'peer': 'nk:1', 'code': 'version', 'body': 'Update Tincan'});
    expect(state.peerError('nk:1'), 'Update Tincan');
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(state.peerError('nk:1'), isNull);
  });

  test('onboarding asks for a name until one is saved', () async {
    expect(state.needsName, isTrue);
    expect(await state.saveProfile(name: 'Nia', description: '', status: ''), isNull);
    expect(state.needsName, isFalse);
  });

  test('lockNow stops the transport and forgets what was loaded', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.select('nk:1');
    await state.lockNow();
    expect(bridge.locks, 1);
    expect(state.locked, isTrue);
    expect(state.conversations, isEmpty);
    expect(state.selectedId, isNull);
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(state.conversations, isEmpty);
  });

  test('what lands while the transport stops is saved before the vault locks', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('tc-lock');
    addTearDown(() => dir.delete(recursive: true));
    final stateDir = '${dir.path}/state';
    await state.init(
        stateDir: stateDir, downloadDir: '${dir.path}/media', vault: VaultManager(bridge, stateDir));
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    bridge.onStop = () => bridge.controller
        .add({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1000, 'body': 'late'});
    await state.lockNow();
    expect(bridge.calls, ['stop', 'lock']);
    expect(bridge.states.values.whereType<String>().any((j) => j.contains('"late"')), isTrue);
  });

  test('history is one file per conversation, written only when it changed', () async {
    final convos = <String, Conversation>{};
    final store = ChatStore(bridge, '/s', convos);
    await store.load();
    final a = convos['a'] = Conversation(id: 'a', name: 'nia');
    convos['b'] = Conversation(id: 'b', name: 'sam');
    await store.flush();
    expect(store.error, isNull);
    expect(bridge.states.containsKey(store.fileFor('b')), isTrue);

    bridge.states.remove(store.fileFor('b'));
    a.messages.add(text('m', 'hey', out: true));
    a.changed();
    await store.flush();
    final saved = jsonDecode(bridge.states[store.fileFor('a')] as String) as Map;
    expect(saved['messages'], hasLength(1));
    expect(bridge.states.containsKey(store.fileFor('b')), isFalse); // unchanged, not rewritten

    final again = <String, Conversation>{};
    await ChatStore(bridge, '/s', again).load();
    expect(again.keys, ['a']); // b's file is gone, the index alone doesn't bring it back
  });

  test('deleted chats and unreadable files are handled inside the store', () async {
    final convos = <String, Conversation>{};
    final store = ChatStore(bridge, '/s', convos);
    await store.load();
    convos['a'] = Conversation(id: 'a', name: 'nia');
    await store.flush();
    bridge.states['${store.fileFor('a')}.bak'] = bridge.states[store.fileFor('a')]!;
    convos.remove('a');
    await store.flush();
    expect(bridge.states.keys.where((k) => k.contains(store.fileFor('a'))), isEmpty);

    bridge.states[store.fileFor('x')] = '[1]';
    await ChatStore(bridge, '/s', <String, Conversation>{}).load();
    expect(bridge.states.containsKey(store.fileFor('x')), isFalse);
    expect(bridge.states.keys.where((k) => k.startsWith('${store.fileFor('x')}.corrupt-')), hasLength(1));
  });

  test('old single-file history migrates, its sent messages count as delivered', () async {
    final old = Conversation(id: 'a', name: 'nia')..messages.add(text('m', 'hi', out: true));
    bridge.states['/s/chats.json'] = {'v': 1, 'conversations': [old.toJson()]};
    final convos = <String, Conversation>{};
    final store = ChatStore(bridge, '/s', convos);
    await store.load();
    expect(convos['a']!.messages.single.status, MessageStatus.delivered);
    await store.flush();
    expect(bridge.states.containsKey(store.fileFor('a')), isTrue);
    expect(jsonDecode(bridge.states['/s/chats/index.json'] as String)['ids'], ['a']);
  });

  test('a corrupt history file falls back to its backup and says so', () async {
    final flaky = _FlakyBridge();
    final convos = <String, Conversation>{};
    final store = ChatStore(flaky, '/s', convos);
    await store.load();
    convos['a'] = Conversation(id: 'a', name: 'nia')..messages.add(text('m', 'hi'));
    await store.flush();
    await ChatStore(flaky, '/s', <String, Conversation>{}).load(); // rotates .bak
    await pumpEventQueue();
    expect(flaky.states.containsKey('${store.fileFor('a')}.bak'), isTrue);

    flaky.unreadable.add(store.fileFor('a'));
    final restored = <String, Conversation>{};
    final again = ChatStore(flaky, '/s', restored);
    await again.load();
    expect(restored['a']!.messages.single.body, 'hi');
    expect(again.error, contains('restored from backup'));
  });

  test('a failed history write is retried, not dropped', () async {
    final flaky = _FlakyBridge();
    final convos = <String, Conversation>{};
    var errors = 0;
    final store = ChatStore(flaky, '/s', convos, onError: () => errors++);
    await store.load();
    convos['a'] = Conversation(id: 'a', name: 'nia');
    flaky.failWrites = 1;
    await store.flush();
    expect(store.error, contains('disk full'));
    await store.flush();
    expect(flaky.states.containsKey(store.fileFor('a')), isTrue);
    expect(store.error, isNull);
    expect(errors, 2);
    store.dispose();
  });

  test('restored chats are saved', () async {
    final convos = <String, Conversation>{};
    final store = ChatStore(bridge, '/s', convos);
    await store.load();
    convos['a'] = Conversation(id: 'a', name: 'nia');
    store.scheduleSave();
    await store.flush();
    expect(bridge.states.containsKey(store.fileFor('a')), isTrue);
  });

  test('persisted fields round-trip', () {
    final c = Conversation(id: 'a', name: 'nia')
      ..nickname = 'N'
      ..fp = '1234'
      ..verified = true
      ..muted = true
      ..unread = 3
      ..disappearAfter = const Duration(days: 1);
    c.messages.add(ChatMessage(
        id: 'm', outgoing: true, ts: DateTime(2026), kind: MessageKind.text, body: 'hi',
        status: MessageStatus.queued, replyTo: 'x', expiresAt: DateTime(2027),
        reactions: {'👍': {'me', 'a'}}));
    final back = Conversation.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
    expect((back.nickname, back.fp, back.verified, back.muted, back.unread, back.disappearAfter),
        ('N', '1234', true, true, 3, const Duration(days: 1)));
    final m = back.messages.single;
    expect((m.status, m.replyTo, m.expiresAt), (MessageStatus.queued, 'x', DateTime(2027)));
    expect(m.reactions, {'👍': {'me', 'a'}});
  });

  test('settings fold the old relay pair and background switch into one each', () {
    final old = Settings.fromJson({'receiveInBackground': false, 'backgroundMinutes': 30, 'derpMapUrl': 'https://map.example'});
    expect((old.relay, old.backgroundMinutes), ('https://map.example', 0));
    expect(Settings.fromJson({'derpHost': 'r.example', 'derpMapUrl': 'https://m'}).relay, 'r.example');
    expect(Settings.fromJson({'backgroundMinutes': 45}).backgroundMinutes, 60);
    expect(Settings(relay: ' r.example ').relay, 'r.example');
  });

  test('a relay that fails to come up is not saved', () async {
    state.selfAddress = 'tcOLD';
    expect(await state.saveSettings(Settings(relay: 'bad.example')), isNotNull);
    expect(bridge.relayCalls, ['bad.example']);
    expect((state.settings.relay, state.selfAddress), ('', 'tcOLD'));

    expect(await state.saveSettings(Settings(relay: 'mine.example')), isNull);
    expect((state.settings.relay, state.selfAddress), ('mine.example', 'tcRELAY'));
  });

  test('incoming messages notify unless that conversation is on screen', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:2', 'name': 'sam'});
    state.select('nk:1');

    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'a', 'body': 'seen'});
    state.handleEvent({'type': 'message', 'peer': 'nk:2', 'id': 'b', 'body': 'hi'});
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:2', 'id': 'c', 'kind': 'image', 'name': 'x.jpg', 'size': 3});
    expect(notifier.shown, [('nk:2', 'sam', 'hi'), ('nk:2', 'sam', '📷 Photo')]);

    state.foreground = false;
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'd', 'body': 'away'});
    expect(notifier.shown.last, ('nk:1', 'nia', 'away'));
  });

  test('opening a conversation clears its notification and sets it active', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.select('nk:1');
    expect(notifier.cleared, ['nk:1']);
    expect(bridge.activePeer, 'nk:1');
  });

  test('contact requests notify even in front, and clear when withdrawn', () {
    state.handleEvent({'type': 'peer-request', 'peer': 'nk:3', 'name': 'dana'});
    expect(notifier.shown.single, ('nk:3', 'request', 'dana'));
    state.handleEvent({'type': 'peer-request-gone', 'peer': 'nk:3'});
    expect(notifier.cleared, ['nk:3']);
  });

  test('direct-only mode persists and reaches the bridge live', () async {
    expect(Settings.fromJson(Settings(directOnly: true).toJson()).directOnly, isTrue);
    expect(Settings().toJson().containsKey('directOnly'), isFalse);
    expect(Settings(directOnly: true).copyWith(relay: 'r').directOnly, isTrue);

    expect(await state.setDirectOnly(true), isNull);
    expect(state.settings.directOnly, isTrue);
    expect(bridge.directOnlyCalls, [true]);
    expect(await state.saveSettings(state.settings.copyWith(directOnly: false)), isNull);
    expect(bridge.directOnlyCalls, [true, false]);
  });

  test('a held dial awaits a direct path and keeps the outbox queued', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'token': 'tcX'});
    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    final convo = state.conversations['nk:1']!;
    state.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'direct': false, 'held': true});
    expect(convo.awaitingDirect, isTrue);
    await state.sendText('nk:1', 'later');
    expect(convo.messages.single.status, MessageStatus.queued);
    expect(bridge.sentTexts, isEmpty);

    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(convo.awaitingDirect, isFalse);
    await pumpEventQueue();
    expect(bridge.sentTexts.single.$3, 'later');

    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    state.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'direct': false, 'held': true});
    state.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'direct': false, 'held': false});
    expect(convo.awaitingDirect, isFalse);
  });

  test('a failed direct-only dial stops awaiting and requeues the send', () async {
    final dials = _DialBridge()..failWith = 'No direct path (direct-only mode)';
    final s = AppState(dials, notifier: notifier);
    final convo = s.conversations['nk:1'] = Conversation(id: 'nk:1', name: 'nia', token: 'tcA');
    s.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'held': true});
    expect(await s.reconnect('nk:1'), 'No direct path (direct-only mode)');
    expect(convo.awaitingDirect, isFalse);
    s.dispose();

    state.handleEvent({'type': 'peer-added', 'peer': 'nk:2', 'name': 'sam'});
    bridge
      ..failSends = true
      ..sendError = BridgeException('No direct path (direct-only mode)', code: 'offline');
    await state.sendText('nk:2', 'hi');
    expect(state.conversations['nk:2']!.messages.single.status, MessageStatus.queued);
  });

  test('cancelling a transfer fails an outgoing file and interrupts an incoming one', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    final convo = state.conversations['nk:1']!;
    convo.messages.add(ChatMessage(
        id: 'f1', outgoing: true, ts: DateTime(2026), kind: MessageKind.video,
        path: '/media/v.mp4', status: MessageStatus.sending, progress: 0.4));
    await state.cancelTransfer('nk:1', 'f1');
    final out = convo.messageById('f1')!;
    expect(bridge.cancels, [('nk:1', 'f1')]);
    expect(out.status, MessageStatus.failed);
    expect(out.progress.value, isNull);
    final sends = bridge.sentFiles.length;
    await state.retry('nk:1', out);
    expect(out.status, MessageStatus.sending);
    expect(bridge.sentFiles.skip(sends), [('nk:1', 'f1')]);

    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f2', 'name': 'a.jpg', 'size': 9, 'kind': 'image'});
    await state.cancelTransfer('nk:1', 'f2');
    expect(convo.messageById('f2')!.status, MessageStatus.interrupted);

    // The peer cancelled.
    state.handleEvent({'type': 'file-begin', 'peer': 'nk:1', 'id': 'f3', 'name': 'b.jpg', 'size': 9, 'kind': 'image'});
    state.handleEvent({'type': 'transfer-cancelled', 'peer': 'nk:1', 'id': 'f3'});
    expect(convo.messageById('f3')!.status, MessageStatus.interrupted);
    convo.messageById('f1')!.status = MessageStatus.sending;
    state.handleEvent({'type': 'transfer-cancelled', 'peer': 'nk:1', 'id': 'f1'});
    expect(convo.messageById('f1')!.status, MessageStatus.failed);
  });
}
