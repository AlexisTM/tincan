import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/bridge.dart';

// Guards the Android startup crash. Closures in one function body share
// a context, so an Isolate.run closure sitting next to one that touched
// `this` dragged the bridge and the whole widget tree into the message,
// failing with "object is unsendable".
//
// The send happens before the native call, so no library is needed: a
// BridgeException means the send worked and only the .so was missing.
void main() {
  Future<void> expectSendable(String label, Future<void> Function() call) async {
    try {
      await call().timeout(const Duration(seconds: 90));
    } catch (e) {
      expect(e, isNot(isA<TimeoutException>()), reason: '$label hung');
      expect('$e', isNot(contains('unsendable')), reason: '$label captured unsendable state');
      expect('$e', isNot(contains('Illegal argument in isolate message')), reason: label);
    }
  }

  test('no bridge call captures the bridge in its isolate message', () async {
    final bridge = TincanBridge();
    bridge.events.listen((_) {}); // the listener that made this fatal

    await expectSendable('setNetInterfaces', () => bridge.setNetInterfaces('[]'));
    await expectSendable('resetIdentity', () => bridge.resetIdentity());
    await expectSendable('sendText', () => bridge.sendText('p', 'i', 'b'));
    await expectSendable('listBlocked', () => bridge.listBlocked());
    await expectSendable('setProfile', () => bridge.setProfile(name: 'x'));
    await expectSendable('sendReaction', () => bridge.sendReaction('p', 'i', 'r', 'x'));
  });

  test('no slow-path call captures the bridge in its isolate message', () async {
    final bridge = TincanBridge();
    bridge.events.listen((_) {});
    final dir = Directory.systemTemp.createTempSync('tincan-bridge-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final missing = '${dir.path}/missing';
    final out = '${dir.path}/out';

    await expectSendable('connect', () => bridge.connect('bogus'));
    await expectSendable('lock', () => bridge.lock());
    await expectSendable('exportAccount', () => bridge.exportAccount(out, password: 'pw'));
    await expectSendable('sealFile', () => bridge.sealFile(missing, out, 'pw'));
    await expectSendable('openFile', () => bridge.openFile(missing, out, 'pw'));
    await expectSendable('vaultChangeSecret', () => bridge.vaultChangeSecret(secret: 's', mode: 'password'));
  });
}
