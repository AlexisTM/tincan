import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/backup.dart';
import 'package:tincan/src/models.dart';

void main() {
  test('chats backup round-trips messages and media across devices', () async {
    final mediaSrc = Directory.systemTemp.createTempSync('tc-chats-src').path;
    final mediaDst = Directory.systemTemp.createTempSync('tc-chats-dst').path;
    File('$mediaSrc/ridge.jpg').writeAsBytesSync(List.generate(100, (i) => i));

    final convo = Conversation(id: 'nk:1', name: 'nia', token: 'tcX');
    convo.messages.add(ChatMessage(
        id: 'm1',
        outgoing: false,
        ts: DateTime.fromMillisecondsSinceEpoch(1000),
        kind: MessageKind.text,
        body: 'hey'));
    convo.messages.add(ChatMessage(
        id: 'f1',
        outgoing: false,
        ts: DateTime.fromMillisecondsSinceEpoch(2000),
        kind: MessageKind.image,
        name: 'ridge.jpg',
        size: 100,
        path: '$mediaSrc/ridge.jpg'));

    // With encryption the media hops through these two callbacks; a
    // plain copy stands in for the vault here.
    Future<void> copy(String src, String dst) async =>
        File(src).copySync(dst);
    final zip = '$mediaDst.zip';
    await exportChats([convo], copy, zip);
    Future<String> seal(String src, String dir, String name) async =>
        File(src).copySync('$dir/$name').path;
    final restored = await importChats(zip, mediaDst, seal);

    expect(restored, hasLength(1));
    final rc = restored.single;
    expect(rc.id, 'nk:1');
    expect(rc.token, 'tcX');
    expect(rc.messages, hasLength(2));
    expect(rc.messages.first.body, 'hey');
    final media = rc.messages.last;
    expect(media.kind, MessageKind.image);
    expect(File(media.path!).readAsBytesSync(), List.generate(100, (i) => i));
    expect(media.path, isNot('$mediaSrc/ridge.jpg')); // landed in the new media dir

    // Merging the same backup again doesn't duplicate messages.
    final again = (await importChats(zip, mediaDst, seal)).single;
    rc.mergeFrom(again);
    expect(rc.messages, hasLength(2));
  });
}
