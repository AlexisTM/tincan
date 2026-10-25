import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// What the app needs from the transport. [TincanBridge] is the real
/// one; tests use a fake.
abstract class Bridge {
  Stream<Map<String, dynamic>> get events;

  /// Returns the server-started event. If the transport can't come up
  /// yet this throws, and the bridge keeps trying, reporting by events.
  /// [relay] is a relay hostname, or an http(s) URL of a relay map.
  /// [directOnly]: see [setDirectOnly].
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String relay,
    bool directOnly,
  });

  /// Chat only over a direct path; the relay just introduces peers. A
  /// dial waits up to a minute for one, reporting `peer-status` with
  /// `held: true` meanwhile. Applies at once, keeping the address.
  Future<void> setDirectOnly(bool on);

  /// Dials and waits for the outcome: returns the peer's id, or throws
  /// with the reason. Events still fire.
  Future<String> connect(String token);
  Future<void> sendText(String peer, String id, String body, {String? replyTo});

  /// Reacts to message [ref] with [emoji]; empty removes the reaction.
  Future<void> sendReaction(String peer, String id, String ref, String emoji);

  /// Sets the chat's disappearing timer on both sides; 0 turns it off.
  Future<void> sendTimer(String peer, String id, int seconds);

  /// Sends a file, sealing a copy into the store as it goes; a path
  /// already in the store is sent from as is. Resumes when the receiver
  /// kept a partial copy.
  Future<FileMeta> sendFile(String peer, String id, String path);

  /// Stops a file going either way; the peer gets `transfer-cancelled`
  /// and drops its partial copy.
  Future<void> cancelTransfer(String peer, String id);
  Future<void> setProfile({
    required String name,
    String description,
    String status,
    String avatarPath,
    bool avatarChanged,
  });
  /// These three return the new server-started event.
  Future<Map<String, dynamic>> resetIdentity();

  /// Rebuilds the transport from what is on disk; the restore path.
  Future<Map<String, dynamic>> restart();

  /// Android only: Go can't enumerate interfaces there.
  Future<void> setNetInterfaces(String json);
  Future<void> accept(String peer);
  Future<void> block(String peer);
  Future<void> unblock(String peer);

  /// Drops a pending request without blocking the peer.
  Future<void> ignore(String peer);
  Future<void> setVerified(String peer, bool verified);

  /// The chat on screen gets a status ping every 5 s, others every 30 s.
  Future<void> setActivePeer(String? peer);

  /// Stops the transport and forgets the data key until the next unlock.
  Future<void> lock();

  /// Whether an encrypted store exists here, and how it is locked.
  Future<({bool exists, String mode})> vaultStatus(String stateDir);

  /// Creates the encrypted store and unlocks it.
  Future<void> vaultCreate({
    required String stateDir,
    required String secret,
    required String mode,
  });

  Future<void> vaultUnlock({required String stateDir, required String secret});

  /// Rewraps the data key under a new secret, keeping the data.
  Future<void> vaultChangeSecret({required String secret, required String mode});

  /// Reads and writes host-owned JSON files inside the same encrypted
  /// store, decoded and encoded off the UI isolate. Null means the file
  /// does not exist; any other failure throws.
  Future<Object?> readState(String path);
  Future<void> writeState(String path, Object json);

  /// Writes the plaintext of a received file to dst, for display or for
  /// handing to another app.
  Future<void> decryptMedia(String src, String dst);

  /// Seals a plaintext file into dir under a free variant of name,
  /// returning where it landed.
  Future<String> importMedia(String src, String dir, String name);

  /// Account backup. It carries the private key: plaintext without a
  /// password, sealed with one.
  Future<void> exportAccount(String dst, {String password = ''});
  Future<void> importAccount(String src, {String password = ''});

  /// Password-wraps an arbitrary file (chat backups), and back.
  Future<void> sealFile(String src, String dst, String password);
  Future<void> openFile(String src, String dst, String password);

  /// Switches the relay. If it fails the old one stays in use, unless
  /// the transport is down: then the new one is kept and retried, and
  /// the result is empty.
  Future<Map<String, dynamic>> setRelay(String relay);

  /// Drops a peer without blocking them.
  Future<void> disconnect(String peer);
  Future<List<(String peer, String name)>> listBlocked();
}

class FileMeta {
  const FileMeta(this.name, this.kind, this.size, this.path);
  final String name;
  final String kind;
  final int size;
  final String path; // the sealed copy
}

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// FFI wrapper around libtincan_bridge (gobridge/). Calls run on a
/// small pool of worker isolates since the Go side blocks on network
/// I/O, and a dedicated isolate pumps events from the start.
class TincanBridge implements Bridge {
  TincanBridge() {
    // Exit comes through the same port as events so it can't overtake
    // the pump's last word.
    _pumpPort.handler = (Object? raw) {
      switch (raw) {
        case int gen:
          _pumpGen = gen;
        case _retired:
          _pumpRetired = true;
          _pumpPort.close();
        case String ev:
          try {
            _events.add(jsonDecode(ev) as Map<String, dynamic>);
          } catch (_) {}
        case null:
          // Died unexpectedly; the next one resumes our generation, so it
          // retires instead of stealing events if a newer engine took over.
          if (!_pumpRetired) Timer(const Duration(seconds: 1), _spawnPump);
      }
    };
    _spawnPump();
  }

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pumpPort = RawReceivePort();
  bool _pumpRetired = false;
  int? _pumpGen;
  var _spawnFailures = 0;

  void _spawnPump() {
    if (_pumpRetired) return;
    Isolate.spawn(_eventPump, (_pumpPort.sendPort, _pumpGen),
            debugName: 'tincan-events', onExit: _pumpPort.sendPort)
        .then((_) => _spawnFailures = 0, onError: (Object e) {
      if (++_spawnFailures == 5) {
        _events.add({'type': 'fatal', 'error': 'event pump: $e'});
      }
      Timer(Duration(seconds: _spawnFailures < 5 ? _spawnFailures : 5), _spawnPump);
    });
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String relay = '',
    bool directOnly = false,
  }) =>
      _call('TincanStart', [
        jsonEncode({
          'stateDir': stateDir,
          'downloadDir': downloadDir,
          'name': name,
          'relay': relay,
          'directOnly': directOnly,
          'verbose': Platform.environment['TINCAN_VERBOSE'] == '1',
        })
      ]);

  @override
  Future<String> connect(String token) async =>
      (await _call('TincanConnect', [token]))['peer'] as String;

  @override
  Future<void> sendText(String peer, String id, String body, {String? replyTo}) =>
      _call('TincanSendText', [peer, id, body, replyTo ?? '']);

  @override
  Future<void> sendReaction(String peer, String id, String ref, String emoji) =>
      _call('TincanSendReaction', [peer, id, ref, emoji]);

  @override
  Future<void> sendTimer(String peer, String id, int seconds) =>
      _call('TincanSendTimer', [peer, id, '$seconds']);

  @override
  Future<FileMeta> sendFile(String peer, String id, String path) async {
    final res = await _call('TincanSendFile', [peer, id, path]);
    return FileMeta(res['name'] as String, res['kind'] as String,
        (res['size'] as num).toInt(), res['path'] as String);
  }

  @override
  Future<void> cancelTransfer(String peer, String id) => _call('TincanCancelTransfer', [peer, id]);

  @override
  Future<void> setDirectOnly(bool on) => _call('TincanSetDirectOnly', ['$on']);

  @override
  Future<void> setProfile({
    required String name,
    String description = '',
    String status = '',
    String avatarPath = '',
    bool avatarChanged = false,
  }) =>
      _call('TincanSetProfile', [
        {
          'name': name,
          'description': description,
          'status': status,
          'avatarPath': avatarPath,
          'avatarChanged': avatarChanged,
        }
      ]);

  @override
  Future<Map<String, dynamic>> resetIdentity() => _call('TincanResetIdentity');

  @override
  Future<Map<String, dynamic>> restart() => _call('TincanRestart');

  @override
  Future<void> setNetInterfaces(String json) => _call('TincanSetNetInterfaces', [json]);

  @override
  Future<void> accept(String peer) => _call('TincanAccept', [peer]);

  @override
  Future<void> block(String peer) => _call('TincanBlock', [peer]);

  @override
  Future<void> unblock(String peer) => _call('TincanUnblock', [peer]);

  @override
  Future<void> ignore(String peer) => _call('TincanIgnore', [peer]);

  @override
  Future<void> setVerified(String peer, bool verified) =>
      _call('TincanSetVerified', [peer, '$verified']);

  @override
  Future<void> setActivePeer(String? peer) => _call('TincanSetActivePeer', [peer ?? '']);

  @override
  Future<void> lock() => _call('TincanLock');

  @override
  Future<({bool exists, String mode})> vaultStatus(String stateDir) async {
    final res = await _call('TincanVaultStatus', [stateDir]);
    return (exists: res['exists'] == true, mode: res['mode'] as String? ?? '');
  }

  @override
  Future<void> vaultCreate({
    required String stateDir,
    required String secret,
    required String mode,
  }) =>
      _call('TincanVaultCreate', [
        {'stateDir': stateDir, 'secret': secret, 'mode': mode}
      ]);

  @override
  Future<void> vaultUnlock({required String stateDir, required String secret}) =>
      _call('TincanUnlock', [
        {'stateDir': stateDir, 'secret': secret}
      ]);

  @override
  Future<void> vaultChangeSecret({required String secret, required String mode}) =>
      _call('TincanChangeSecret', [
        {'secret': secret, 'mode': mode}
      ]);

  @override
  Future<Object?> readState(String path) async =>
      (await _call('TincanReadState', [path]))['content'];

  @override
  Future<void> writeState(String path, Object json) =>
      _call('TincanWriteState', [path, json]);

  @override
  Future<void> decryptMedia(String src, String dst) =>
      _call('TincanDecryptMedia', [src, dst]);

  @override
  Future<String> importMedia(String src, String dir, String name) async =>
      (await _call('TincanImportMedia', [src, dir, name]))['path'] as String;

  @override
  Future<void> exportAccount(String dst, {String password = ''}) =>
      _call('TincanExportAccount', [dst, password]);

  @override
  Future<void> importAccount(String src, {String password = ''}) =>
      _call('TincanImportAccount', [src, password]);

  @override
  Future<void> sealFile(String src, String dst, String password) =>
      _call('TincanSealFile', [src, dst, password]);

  @override
  Future<void> openFile(String src, String dst, String password) =>
      _call('TincanOpenFile', [src, dst, password]);

  @override
  Future<Map<String, dynamic>> setRelay(String relay) => _call('TincanSetRelay', [relay]);

  @override
  Future<void> disconnect(String peer) => _call('TincanDisconnect', [peer]);

  @override
  Future<List<(String, String)>> listBlocked() async {
    final res = await _call('TincanListBlocked');
    final list = res['blocked'] as List? ?? const [];
    return [
      for (final e in list)
        ((e as Map)['peer'] as String, (e['name'] as String?) ?? ''),
    ];
  }
}

/// Calls that can block for long (a dial, picking a relay, argon2) get
/// an isolate of their own, so the pool keeps serving sends.
const _slowCalls = {
  'TincanStart', 'TincanSetRelay', 'TincanRestart', 'TincanResetIdentity', 'TincanConnect',
  'TincanLock', 'TincanExportAccount', 'TincanImportAccount', 'TincanSealFile', 'TincanOpenFile',
  'TincanUnlock', 'TincanVaultCreate', 'TincanChangeSecret',
};

// Redials fire for every offline contact at once, each up to a minute.
final _dials = _Gate(4);

/// Non-string args are sent as JSON.
Future<Map<String, dynamic>> _call(String symbol, [List<Object> args = const []]) async {
  if (!_slowCalls.contains(symbol)) return _checked(await _workers.call(symbol, args));
  final strs = [for (final a in args) a is String ? a : jsonEncode(a)];
  return _checked(symbol == 'TincanConnect'
      ? await _dials.run(() => _isolated(symbol, strs))
      : await _isolated(symbol, strs));
}

// Top-level and alone, so the closure captures nothing but its args.
Future<Map<String, dynamic>> _isolated(String symbol, List<String> args) =>
    Isolate.run(() => _invoke(symbol, args));

Map<String, dynamic> _checked(Map<String, dynamic> res) {
  final err = res['error'];
  if (err is String && err.isNotEmpty) throw BridgeException(err);
  return res;
}

class _Gate {
  _Gate(this._free);
  int _free;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() f) async {
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    try {
      return await f();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _free++;
      }
    }
  }
}

final _workers = _WorkerPool(3);

class _Worker {
  _Worker(this.port);
  final Future<SendPort> port;
  final pending = <Completer<Map<String, dynamic>>>{};
}

/// Long-lived isolates that run bridge calls, each binding the library
/// once. Several, so a slow dial can't hold up sends behind it. A worker
/// that dies fails its calls and is replaced on the next one.
class _WorkerPool {
  _WorkerPool(this.size) : _slots = List.filled(size, null);

  final int size;
  final List<_Worker?> _slots;

  // One port takes the worker's SendPort, its exit and its errors, so a
  // worker dying during startup fails its callers instead of hanging them.
  _Worker _spawn(int i) {
    final ready = Completer<SendPort>();
    ready.future.ignore();
    final w = _Worker(ready.future);
    final port = RawReceivePort();
    void fail(String why) {
      port.close();
      if (!ready.isCompleted) ready.completeError(BridgeException(why));
      _retire(i, w, why);
    }

    port.handler = (Object? msg) => switch (msg) {
          SendPort p when !ready.isCompleted => ready.complete(p),
          [final e, _] => fail('bridge worker failed: $e'),
          _ => fail('bridge worker died'),
        };
    _spawnWorker(i, port.sendPort).then((_) {}, onError: (Object e) => fail('$e'));
    return w;
  }

  void _retire(int i, _Worker w, String why) {
    if (identical(_slots[i], w)) _slots[i] = null;
    for (final c in w.pending) {
      if (!c.isCompleted) c.completeError(BridgeException(why));
    }
  }

  Future<Map<String, dynamic>> call(String symbol, List<Object> args) async {
    var pick = 0;
    for (var i = 1; i < size; i++) {
      if ((_slots[i]?.pending.length ?? 0) < (_slots[pick]?.pending.length ?? 0)) pick = i;
    }
    final w = _slots[pick] ??= _spawn(pick);
    final done = Completer<Map<String, dynamic>>();
    // _retire may fail it while we are still waiting on the port.
    done.future.ignore();
    final reply = RawReceivePort((Object? r) {
      if (done.isCompleted) return;
      if (r is Map<String, dynamic>) {
        done.complete(r);
      } else {
        done.completeError(BridgeException('bad reply from bridge worker: $r'));
      }
    });
    w.pending.add(done);
    try {
      (await w.port).send((symbol, args, reply.sendPort));
      return await done.future;
    } finally {
      reply.close();
      w.pending.remove(done);
    }
  }
}

// Top-level on purpose: an isolate entry point that closed over `this`
// would drag the bridge and everything it references into the message,
// failing with "object is unsendable".
Future<Isolate> _spawnWorker(int i, SendPort port) => Isolate.spawn(_workerMain, port,
    debugName: 'tincan-bridge-$i', onExit: port, onError: port);

void _workerMain(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((msg) {
    final (symbol, args, reply) = msg as (String, List<Object>, SendPort);
    try {
      reply.send(_invoke(symbol, [for (final a in args) a is String ? a : jsonEncode(a)]));
    } catch (e) {
      reply.send({'error': '$e'});
    }
  });
}

// The lazy bindings below initialize once per isolate; dlopen is cached.

String _libFileName() {
  if (Platform.isWindows) return 'tincan_bridge.dll';
  if (Platform.isMacOS || Platform.isIOS) return 'libtincan_bridge.dylib';
  return 'libtincan_bridge.so';
}

DynamicLibrary _openLib() {
  final name = _libFileName();
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final override = Platform.environment['TINCAN_BRIDGE'];
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    p.join(exeDir, 'lib', name), // Linux bundle layout
    p.join(exeDir, name),
    name, // whatever the linker search path finds
  ];
  final errors = <String>[];
  for (final c in candidates) {
    try {
      return DynamicLibrary.open(c);
    } catch (e) {
      errors.add('$c: $e');
    }
  }
  throw BridgeException(
      'could not load $name (build it with gobridge/build.sh, or point TINCAN_BRIDGE at it):\n${errors.join('\n')}');
}

final DynamicLibrary _lib = _openLib();

typedef _NativeStr1 = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeStr2 = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeStr3 = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeStr4 = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

final _free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('TincanFree');
final _attachEvents = _lib.lookupFunction<Int32 Function(), int Function()>('TincanAttachEvents');
final _nextEvent = _lib.lookupFunction<Pointer<Utf8> Function(Int32, Int32),
    Pointer<Utf8> Function(int, int)>('TincanNextEvent');

// Wiping native buffers is best-effort: the Dart strings and isolate
// message copies still hold the same bytes until the GC reuses them.
String _take(Pointer<Utf8> ptr) {
  final n = ptr.length;
  try {
    return ptr.toDartString(length: n);
  } finally {
    ptr.cast<Uint8>().asTypedList(n).fillRange(0, n, 0);
    _free(ptr);
  }
}

Pointer<Utf8> _native(Uint8List bytes) {
  final ptr = malloc<Uint8>(bytes.length + 1);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  ptr[bytes.length] = 0;
  return ptr.cast();
}

final _bound = <String, Function>{};

Map<String, dynamic> _invoke(String symbol, List<String> args) {
  final fn = _bound[symbol] ??= switch (args.length) {
    0 => _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(symbol),
    1 => _lib.lookupFunction<_NativeStr1, _NativeStr1>(symbol),
    2 => _lib.lookupFunction<_NativeStr2, _NativeStr2>(symbol),
    3 => _lib.lookupFunction<_NativeStr3, _NativeStr3>(symbol),
    4 => _lib.lookupFunction<_NativeStr4, _NativeStr4>(symbol),
    _ => throw ArgumentError('$symbol: ${args.length} args, at most 4 supported'),
  };
  final bytes = [for (final a in args) utf8.encode(a)];
  final ptrs = [for (final b in bytes) _native(b)];
  try {
    final out = switch (ptrs) {
      [] => (fn as Pointer<Utf8> Function())(),
      [final a] => (fn as _NativeStr1)(a),
      [final a, final b] => (fn as _NativeStr2)(a, b),
      [final a, final b, final c] => (fn as _NativeStr3)(a, b, c),
      [final a, final b, final c, final d] => (fn as _NativeStr4)(a, b, c, d),
      _ => throw StateError('unreachable'),
    };
    return jsonDecode(_take(out)) as Map<String, dynamic>;
  } finally {
    // Args carry secrets and message bodies; don't leave them in freed memory.
    for (var i = 0; i < ptrs.length; i++) {
      final n = bytes[i].length;
      ptrs[i].cast<Uint8>().asTypedList(n).fillRange(0, n, 0);
      bytes[i].fillRange(0, n, 0);
      malloc.free(ptrs[i]);
    }
  }
}

const _retired = 'retired';

/// Runs until a newer bridge attaches: Android can replace the engine
/// while this isolate lives on, and it must not keep taking events.
/// A respawned pump gets the generation its predecessor attached.
/// Other failures are retried with backoff, and only a run of them is
/// reported as fatal.
void _eventPump((SendPort, int?) start) {
  var (port, gen) = start;
  var failures = 0;
  while (true) {
    try {
      if (gen == null) {
        gen = _attachEvents();
        port.send(gen);
      }
      // A thread parked forever in a native call wedges VM shutdown.
      final ev = _take(_nextEvent(gen, 500));
      failures = 0;
      if (ev == 'stale') {
        port.send(_retired);
        return;
      }
      if (ev.isNotEmpty) port.send(ev);
    } on BridgeException catch (e) {
      // No library: nothing to retry.
      port.send(jsonEncode({'type': 'fatal', 'error': '$e'}));
      port.send(_retired);
      return;
    } catch (e) {
      failures++;
      if (failures == 1 || failures == 5) {
        port.send(jsonEncode({'type': failures == 5 ? 'fatal' : 'pump-error', 'error': '$e'}));
      }
      sleep(Duration(seconds: failures < 5 ? failures : 5));
    }
  }
}
