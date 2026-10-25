// A headless peer for interop testing: prints its address, auto-accepts
// requests, echoes what arrives and sends what you type. From the root:
//
//   TINCAN_BRIDGE=gobridge/build/libtincan_bridge.so dart run tool/peer.dart [name]
import 'dart:convert';
import 'dart:io';

import 'package:tincan/src/bridge.dart';

Future<void> main(List<String> args) async {
  final name = args.isNotEmpty ? args.first : 'desktop';
  final dir = Directory.systemTemp.createTempSync('tincan-peer');
  final bridge = TincanBridge();
  String? peer;

  void cleanup() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  ProcessSignal.sigint.watch().listen((_) {
    cleanup();
    exit(130);
  });

  bridge.events.listen((ev) async {
    switch (ev['type']) {
      case 'peer-request':
        stdout.writeln('<< request from ${ev['name']}, accepting');
        try {
          await bridge.accept(ev['peer'] as String);
        } catch (e) {
          stdout.writeln('!! accept failed: $e');
        }
      case 'peer-added':
        peer = ev['peer'] as String;
        stdout.writeln('<< connected: ${ev['name']}');
      case 'peer-profile':
        stdout.writeln('<< profile: ${ev['name']} / ${ev['status']}');
      case 'peer-status':
        if (ev.containsKey('held')) {
          stdout.writeln(ev['held'] == true ? '<< held: no direct path yet' : '<< no longer held');
        } else {
          stdout.writeln('<< path: ${ev['direct'] == true ? 'DIRECT ${ev['addr']}' : 'relay ${ev['relay']}'} ${ev['latencyMs']}ms');
        }
      case 'message':
        stdout.writeln('<< ${ev['body']}');
      case 'file-done':
        stdout.writeln('<< file ${ev['name']} (${ev['size']} bytes) -> ${ev['path']}');
      case 'peer-removed':
        if (ev['peer'] == peer) peer = null;
        stdout.writeln('<< disconnected');
    }
  });

  await bridge.vaultCreate(stateDir: '${dir.path}/state', secret: 'peer-secret', mode: 'password');
  final started = await bridge.start(
      stateDir: '${dir.path}/state', downloadDir: '${dir.path}/media', name: name);
  final addr = started['address'];
  await bridge.setProfile(name: name, status: 'desktop peer');
  stdout.writeln('ADDRESS: $addr');

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (peer == null) {
      stdout.writeln('!! nobody connected yet');
      continue;
    }
    try {
      await bridge.sendText(peer!, DateTime.now().microsecondsSinceEpoch.toString(), line);
      stdout.writeln('>> $line');
    } catch (e) {
      stdout.writeln('!! send failed: $e');
    }
  }
  cleanup();
  exit(0);
}
