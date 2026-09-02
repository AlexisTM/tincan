import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/app_state.dart';
import 'package:tincan/src/bridge.dart';
import 'package:tincan/src/chat_store.dart';
import 'package:tincan/src/models.dart';
import 'package:tincan/src/settings.dart';

class FakeBridge implements Bridge {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final sentTexts = <(String, String, String)>[];
  bool failSends = false;

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String derpHost = '',
    String derpMapUrl = '',
  }) async =>
      {'type': 'server-started', 'address': 'tcTESTADDR'};

  @override
  Future<String> connect(String token) async => 'nodekey:peer1';

  @override
  Future<void> sendText(String peer, String id, String body) async {
    if (failSends) throw BridgeException('peer gone');
    sentTexts.add((peer, id, body));
  }

  @override
  Future<FileMeta> sendFile(String peer, String id, String path) async =>
      const FileMeta('pic.png', 'image', 42, '/media/pic.png');

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

  @override
  Future<Object?> readState(String path) async => states[path];

  @override
  Future<void> writeState(String path, Object json) async => states[path] = json;

  @override
  Future<void> decryptMedia(String src, String dst) async {}

  @override
  Future<String> importMedia(String src, String dir, String name) async => '$dir/$name';

  @override
  Future<void> exportAccount(String dst) async {}

  @override
  Future<void> importAccount(String src) async {}



  final disconnected = <String>[];

  String? derpHost;
  final derpCalls = <String>[];

  @override
  Future<Map<String, dynamic>> setDerp({required String host, required String mapUrl}) async {
    derpCalls.add(host);
    if (host == 'bad.example') throw BridgeException('no such relay');
    derpHost = host;
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

void main() {
  late FakeBridge bridge;
  late AppState state;

  setUp(() {
    bridge = FakeBridge();
    state = AppState(bridge);
  });

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
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1000, 'body': 'hey'});
    final convo = state.conversations['nk:1']!;
    expect(convo.messages.single.body, 'hey');
    expect(convo.messages.single.outgoing, isFalse);
    expect(convo.unread, 1);
    expect(state.conversations['nk:2']!.unread, 0);
  });

  test('file receive: begin, progress, done', () {
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

    state.handleEvent({
      'type': 'file-done', 'peer': 'nk:1', 'id': 'f1',
      'path': '/tmp/ridge.jpg', 'name': 'ridge.jpg', 'size': 100,
    });
    expect(msg.progress.value, isNull);
    expect(msg.path, '/tmp/ridge.jpg');
    expect(msg.status, MessageStatus.sent);
  });

  test('sendText is optimistic and marks failures', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    await state.sendText('nk:1', 'hello');
    final convo = state.conversations['nk:1']!;
    expect(convo.messages.single.status, MessageStatus.sent);
    expect(bridge.sentTexts.single.$3, 'hello');

    bridge.failSends = true;
    await state.sendText('nk:1', 'again');
    expect(convo.messages.last.status, MessageStatus.failed);
  });

  test('chat requests buffer until accepted or refused', () async {
    state.handleEvent({'type': 'peer-request', 'peer': 'nk:1', 'name': 'nia'});
    expect(state.requests.single.name, 'nia');
    expect(state.conversations, isEmpty);

    await state.acceptRequest('nk:1');
    expect(bridge.accepted, ['nk:1']);
    expect(state.requests, isEmpty);
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(state.conversations['nk:1']!.connected, isTrue);

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

  test('peer-profile updates name, bio, status, and picture', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({
      'type': 'peer-profile', 'peer': 'nk:1',
      'name': 'Nia O.', 'description': 'ridge person', 'status': 'offline sundays',
      'avatarPath': '/tmp/a.img',
    });
    final convo = state.conversations['nk:1']!;
    expect(convo.name, 'Nia O.');
    expect(convo.description, 'ridge person');
    expect(convo.statusText, 'offline sundays');
    expect(convo.avatarPath, '/tmp/a.img');
  });

  test('deleting a conversation disconnects and forgets it', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1, 'body': 'hi'});
    expect(await state.deleteConversation('nk:1'), isNull);
    expect(bridge.disconnected, ['nk:1']);
    expect(state.conversations, isEmpty);
    expect(state.selectedId, isNull);
  });

  test('a peer profile teaches us their address so we can redial', () {
    // The side that only ever accepted a connection has no token
    // until the peer's profile arrives carrying their own address.
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

  test('send-error marks an in-flight transfer failed', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    state.handleEvent({
      'type': 'file-begin', 'peer': 'nk:1', 'id': 'f1', 'ts': 1,
      'name': 'v.mp4', 'size': 10, 'kind': 'video',
    });
    state.handleEvent({'type': 'send-error', 'peer': 'nk:1', 'id': 'f1', 'error': 'conn reset'});
    expect(state.conversations['nk:1']!.messageById('f1')!.status, MessageStatus.failed);
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
  });

  test('connect waits for the dial to land, or reports why it did not', () async {
    final ok = state.connect('tcPEER');
    await pumpEventQueue();
    state.handleEvent({'type': 'peer-added', 'peer': 'nodekey:peer1', 'name': 'nia', 'token': 'tcPEER'});
    expect(await ok, isNull);
    expect(state.selectedId, 'nodekey:peer1');

    final failed = state.connect('tcPEER');
    await pumpEventQueue();
    state.handleEvent({'type': 'connect-error', 'peer': 'nodekey:peer1', 'error': 'peer unreachable'});
    expect(await failed, 'peer unreachable');
  });

  test('redials back off from 2s to 64s, then leave it to the user', () {
    expect([for (var i = 0; i < 7; i++) AppState.reconnectDelay(i)?.inSeconds],
        [2, 4, 8, 16, 32, 64, null]);
  });

  test('a dropped dialed peer shows as reconnecting until it is back', () {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia', 'token': 'tcX'});
    state.handleEvent({'type': 'peer-removed', 'peer': 'nk:1'});
    final convo = state.conversations['nk:1']!;
    expect(convo.reconnecting, isTrue);
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    expect(convo.reconnecting, isFalse);
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
    state.handleEvent({'type': 'message', 'peer': 'nk:2', 'id': 'm0', 'ts': 1000, 'body': 'first'});
    var app = 0;
    state.addListener(() => app++);
    state.handleEvent({'type': 'message', 'peer': 'nk:2', 'id': 'm1', 'ts': 2000, 'body': 'still on top'});
    expect(app, 0);
    state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm2', 'ts': 3000, 'body': 'overtakes'});
    expect(app, 1);
  });

  test('history re-encodes only the conversations that changed', () async {
    final convos = <String, Conversation>{};
    final store = ChatStore(bridge, '/s', convos);
    await store.load();
    final a = convos['a'] = Conversation(id: 'a', name: 'nia');
    convos['b'] = Conversation(id: 'b', name: 'sam');
    store.scheduleSave();
    await store.flush();
    final first = a.encoded;
    expect(identical(a.encoded, first), isTrue);
    a.messages.add(ChatMessage(id: 'm', outgoing: true, ts: DateTime(2026), kind: MessageKind.text, body: 'hey'));
    a.changed();
    store.scheduleSave();
    await store.flush();
    final saved = jsonDecode(bridge.states['/s/chats.json'] as String) as Map;
    expect((saved['conversations'] as List).first['messages'], hasLength(1));
  });

  test('retry resends a failed text as a fresh message', () async {
    state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'nia'});
    bridge.failSends = true;
    await state.sendText('nk:1', 'hello');
    final convo = state.conversations['nk:1']!;
    bridge.failSends = false;
    await state.retry('nk:1', convo.messages.single);
    expect(convo.messages.single.status, MessageStatus.sent);
    expect(bridge.sentTexts.last.$3, 'hello');
  });

  test('a relay that fails to come up is not saved', () async {
    state.selfAddress = 'tcOLD';
    expect(await state.saveSettings(Settings(derpHost: 'bad.example')), isNotNull);
    expect(bridge.derpCalls, ['bad.example']);
    expect((state.settings.derpHost, state.selfAddress), ('', 'tcOLD'));

    expect(await state.saveSettings(Settings(derpHost: 'mine.example')), isNull);
    expect((state.settings.derpHost, state.selfAddress), ('mine.example', 'tcRELAY'));
  });
}
