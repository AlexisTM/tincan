import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// What the app needs from the transport. [TincanBridge] is the real
/// one; tests use a fake.
abstract class Bridge {
  Stream<Map<String, dynamic>> get events;

  /// Returns the server-started event. If the transport can't come up
  /// yet this throws, and the bridge keeps trying, reporting by events.
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String derpHost,
    String derpMapUrl,
  });

  /// Starts dialing and returns the peer's id at once; the outcome
  /// arrives as a peer-added or connect-error event.
  Future<String> connect(String token);
  Future<void> sendText(String peer, String id, String body);
  /// Sends a file, sealing a copy into the store as it goes; a path
  /// already in the store is sent from as is.
  Future<FileMeta> sendFile(String peer, String id, String path);
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

  /// Account backup, in plaintext because it must open on another
  /// device. It carries the private key.
  Future<void> exportAccount(String dst);
  Future<void> importAccount(String src);

  /// Switches the relay. If it fails the old one stays in use, unless
  /// the transport is down: then the new one is kept and retried, and
  /// the result is empty.
  Future<Map<String, dynamic>> setDerp({required String host, required String mapUrl});

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
    final port = ReceivePort();
    port.listen((raw) {
      if (raw is String) {
        try {
          _events.add(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {}
      }
    });
    Isolate.spawn(_eventPump, port.sendPort, debugName: 'tincan-events');
  }

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String derpHost = '',
    String derpMapUrl = '',
  }) =>
      _call('TincanStart', [
        jsonEncode({
          'stateDir': stateDir,
          'downloadDir': downloadDir,
          'name': name,
          'derpHost': derpHost,
          'derpMapUrl': derpMapUrl,
          'verbose': Platform.environment['TINCAN_VERBOSE'] == '1',
        })
      ]);

  @override
  Future<String> connect(String token) async =>
      (await _call('TincanConnect', [token]))['peer'] as String;

  @override
  Future<void> sendText(String peer, String id, String body) =>
      _call('TincanSendText', [peer, id, body]);

  @override
  Future<FileMeta> sendFile(String peer, String id, String path) async {
    final res = await _call('TincanSendFile', [peer, id, path]);
    return FileMeta(res['name'] as String, res['kind'] as String,
        (res['size'] as num).toInt(), res['path'] as String);
  }

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
  Future<void> exportAccount(String dst) => _call('TincanExportAccount', [dst]);

  @override
  Future<void> importAccount(String src) => _call('TincanImportAccount', [src]);

  @override
  Future<Map<String, dynamic>> setDerp({required String host, required String mapUrl}) =>
      _call('TincanSetDERP', [
        {'host': host, 'mapUrl': mapUrl}
      ]);

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

/// Calls that can block for long (picking a relay takes up to a minute)
/// get an isolate of their own, so the pool keeps serving sends.
const _slowCalls = {'TincanStart', 'TincanSetDERP', 'TincanRestart', 'TincanResetIdentity'};

/// Non-string args are sent as JSON.
Future<Map<String, dynamic>> _call(String symbol, [List<Object> args = const []]) async =>
    _checked(_slowCalls.contains(symbol)
        ? await _isolated(symbol, [for (final a in args) a is String ? a : jsonEncode(a)])
        : await _workers.call(symbol, args));

// Top-level and alone, so the closure captures nothing but its args.
Future<Map<String, dynamic>> _isolated(String symbol, List<String> args) =>
    Isolate.run(() => _invoke(symbol, args));

Map<String, dynamic> _checked(Map<String, dynamic> res) {
  final err = res['error'];
  if (err is String && err.isNotEmpty) throw BridgeException(err);
  return res;
}

final _workers = _WorkerPool(3);

/// Long-lived isolates that run bridge calls, each binding the library
/// once. Several, so a slow dial can't hold up sends behind it.
class _WorkerPool {
  _WorkerPool(this.size) : _busy = List.filled(size, 0);

  final int size;
  final List<int> _busy;
  final _ports = <Future<SendPort>>[];

  Future<Map<String, dynamic>> call(String symbol, List<Object> args) async {
    if (_ports.isEmpty) {
      for (var i = 0; i < size; i++) {
        _ports.add(_spawnWorker(i));
      }
    }
    var pick = 0;
    for (var i = 1; i < size; i++) {
      if (_busy[i] < _busy[pick]) pick = i;
    }
    _busy[pick]++;
    final reply = ReceivePort();
    try {
      (await _ports[pick]).send((symbol, args, reply.sendPort));
      return await reply.first as Map<String, dynamic>;
    } finally {
      reply.close();
      _busy[pick]--;
    }
  }
}

// Top-level on purpose: an isolate entry point that closed over `this`
// would drag the bridge and everything it references into the message,
// failing with "object is unsendable".
Future<SendPort> _spawnWorker(int i) async {
  final ready = ReceivePort();
  await Isolate.spawn(_workerMain, ready.sendPort, debugName: 'tincan-bridge-$i');
  final port = await ready.first as SendPort;
  ready.close();
  return port;
}

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

final _free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('TincanFree');
final _attachEvents = _lib.lookupFunction<Int32 Function(), int Function()>('TincanAttachEvents');
final _nextEvent = _lib.lookupFunction<Pointer<Utf8> Function(Int32, Int32),
    Pointer<Utf8> Function(int, int)>('TincanNextEvent');

String _take(Pointer<Utf8> ptr) {
  final s = ptr.toDartString();
  _free(ptr);
  return s;
}

final _bound = <String, Function>{};

Map<String, dynamic> _invoke(String symbol, List<String> args) {
  final fn = _bound[symbol] ??= switch (args.length) {
    0 => _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(symbol),
    1 => _lib.lookupFunction<_NativeStr1, _NativeStr1>(symbol),
    2 => _lib.lookupFunction<_NativeStr2, _NativeStr2>(symbol),
    _ => _lib.lookupFunction<_NativeStr3, _NativeStr3>(symbol),
  };
  final ptrs = [for (final a in args) a.toNativeUtf8()];
  try {
    final out = switch (ptrs) {
      [] => (fn as Pointer<Utf8> Function())(),
      [final a] => (fn as _NativeStr1)(a),
      [final a, final b] => (fn as _NativeStr2)(a, b),
      [final a, final b, final c, ...] => (fn as _NativeStr3)(a, b, c),
    };
    return jsonDecode(_take(out)) as Map<String, dynamic>;
  } finally {
    ptrs.forEach(malloc.free);
  }
}

/// Runs until a newer bridge attaches: Android can replace the engine
/// while this isolate lives on, and it must not keep taking events.
void _eventPump(SendPort port) {
  int? gen;
  while (true) {
    try {
      gen ??= _attachEvents();
      // A thread parked forever in a native call wedges VM shutdown.
      final ev = _take(_nextEvent(gen, 500));
      if (ev == 'stale') return;
      if (ev.isNotEmpty) port.send(ev);
    } catch (e) {
      port.send(jsonEncode({'type': 'fatal', 'error': '$e'}));
      return;
    }
  }
}
