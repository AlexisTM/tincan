// Smoke test for the FFI bridge, no GUI. The parent starts a transport
// and spawns this script again as a child, which connects back over real
// DERP; they exchange a message and a file, then the parent regenerates
// its identity. Needs network. Run from the repo root:
//
//   TINCAN_BRIDGE=gobridge/build/libtincan_bridge.so dart run tool/e2e_smoke.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tincan/src/bridge.dart';

/// Buffers everything, so an event emitted between two waits (accept()
/// fires peer-added synchronously) isn't missed.
class Events {
  Events(Stream<Map<String, dynamic>> stream) {
    stream.listen(_all.add);
  }

  final _all = <Map<String, dynamic>>[];
  int _next = 0;

  Future<Map<String, dynamic>> waitFor(String type,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_next < _all.length) {
        final ev = _all[_next++];
        if (ev['type'] == type) return ev;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no $type event within $timeout');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
}

Future<int> parentMain() async {
  final dir = Directory.systemTemp.createTempSync('tincan-smoke-a');
  Process? child;
  try {
    return await _parentRun(dir, (p) => child = p);
  } on TimeoutException catch (e) {
    stderr.writeln('parent: $e');
    return 1;
  } finally {
    child?.kill();
    _rm(dir);
  }
}

void _rm(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
}

Future<int> _parentRun(Directory dir, void Function(Process) spawned) async {
  final bridge = TincanBridge();
  final events = Events(bridge.events);
  await bridge.vaultCreate(
      stateDir: '${dir.path}/state', secret: 'parent-secret', mode: 'password');
  final addr = (await bridge.start(
      stateDir: '${dir.path}/state', downloadDir: '${dir.path}/media', name: 'parent'))['address'] as String;
  stdout.writeln('parent: listening at ${addr.substring(0, 20)}…');

  final child = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/e2e_smoke.dart', '--peer', addr],
    environment: {...Platform.environment},
  );
  spawned(child);
  child.stdout.transform(const SystemEncoding().decoder).listen((s) => stdout.write('  child: $s'));
  child.stderr.transform(const SystemEncoding().decoder).listen((s) => stderr.write('  child! $s'));

  final req = await events.waitFor('peer-request');
  stdout.writeln('parent: chat request from ${req['name']}, accepting');
  await bridge.accept(req['peer'] as String);
  final added = await events.waitFor('peer-added');
  stdout.writeln('parent: peer connected: ${added['name']}');
  final msg = await events.waitFor('message');
  stdout.writeln('parent: got text: ${msg['body']}');
  if (msg['body'] != 'hello over the tunnel 🐈') return 1;

  final done = await events.waitFor('file-done');
  final path = done['path'] as String;
  const payload = 'file payload through the tunnel';

  // Nothing readable may sit on disk: not the received file, not the
  // message, not the identity.
  bool holds(String file, String needle) {
    final bytes = File(file).readAsBytesSync();
    final want = utf8.encode(needle);
    for (var i = 0; i + want.length <= bytes.length; i++) {
      var hit = true;
      for (var j = 0; j < want.length; j++) {
        if (bytes[i + j] != want[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  if (holds(path, payload)) {
    stderr.writeln('parent: received file is PLAINTEXT on disk');
    return 1;
  }
  if (holds('${dir.path}/state/identity.json', 'privkey')) {
    stderr.writeln('parent: identity is PLAINTEXT on disk');
    return 1;
  }
  final plain = '${dir.path}/plain.txt';
  await bridge.decryptMedia(path, plain);
  if (File(plain).readAsStringSync() != payload) return 1;
  stdout.writeln('parent: got file ${done['name']} (${done['size']} bytes), encrypted at rest');

  await bridge.sendText(added['peer'] as String, 'm-reply', 'pong');
  final code = await child.exitCode.timeout(const Duration(seconds: 60));
  stdout.writeln('parent: child exited $code');
  if (code != 0) return code;

  final newAddr = (await bridge.resetIdentity())['address'] as String;
  stdout.writeln('parent: regenerated address ${newAddr.substring(0, 20)}…');
  return newAddr == addr || !newAddr.startsWith('tc') ? 1 : 0;
}

Future<int> childMain(String peerAddr) async {
  final dir = Directory.systemTemp.createTempSync('tincan-smoke-b');
  try {
    return await _childRun(dir, peerAddr);
  } on TimeoutException catch (e) {
    stderr.writeln('child: $e');
    return 1;
  } finally {
    _rm(dir);
  }
}

Future<int> _childRun(Directory dir, String peerAddr) async {
  final bridge = TincanBridge();
  final events = Events(bridge.events);
  await bridge.vaultCreate(
      stateDir: '${dir.path}/state', secret: 'child-secret', mode: 'password');
  await bridge.start(
      stateDir: '${dir.path}/state', downloadDir: '${dir.path}/media', name: 'child');
  final peer = await bridge.connect(peerAddr);
  await events.waitFor('peer-added');
  stdout.writeln('connected to parent');
  await bridge.sendText(peer, 'm1', 'hello over the tunnel 🐈');

  // Files are refused until the parent accepts our request.
  await events.waitFor('peer-accepted');
  stdout.writeln('request accepted by parent');

  final f = File('${dir.path}/note.txt')..writeAsStringSync('file payload through the tunnel');
  await bridge.sendFile(peer, 'f1', f.path);

  final reply = await events.waitFor('message');
  stdout.writeln('got reply: ${reply['body']}');
  return reply['body'] == 'pong' ? 0 : 1;
}

Future<void> main(List<String> args) async {
  final i = args.indexOf('--peer');
  final code = i >= 0 ? await childMain(args[i + 1]) : await parentMain();
  exit(code);
}
