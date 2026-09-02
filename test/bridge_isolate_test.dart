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
      await call();
    } catch (e) {
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
  });
}
