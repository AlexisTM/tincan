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
    await exportChats([convo], copy, zip, seal: _noCrypt);
    Future<String> seal(String src, String dir, String name) async =>
        File(src).copySync('$dir/$name').path;
    final restored = await importChats(zip, mediaDst, seal, open: _noCrypt);

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
    final again = (await importChats(zip, mediaDst, seal, open: _noCrypt)).single;
    rc.mergeFrom(again);
    expect(rc.messages, hasLength(2));
  });

  test('a password-sealed chats backup needs its password', () async {
    final dir = Directory.systemTemp.createTempSync('tc-chats-pw');
    addTearDown(() => dir.delete(recursive: true));
    final convo = Conversation(id: 'nk:1', name: 'nia')
      ..messages.add(ChatMessage(
          id: 'm1', outgoing: true, ts: DateTime(2026), kind: MessageKind.text, body: 'hey',
          status: MessageStatus.delivered));
    // The bridge's magic plus a byte flip stands in for the sealing.
    const magic = [0x54, 0x43, 0x42, 0x01];
    Future<void> flip(String src, String dst, String pw) async =>
        File(dst).writeAsBytesSync([...magic, for (final b in File(src).readAsBytesSync()) b ^ pw.length]);
    Future<void> unflip(String src, String dst, String pw) async => File(dst)
        .writeAsBytesSync([for (final b in File(src).readAsBytesSync().skip(magic.length)) b ^ pw.length]);
    final out = '${dir.path}/chats.tincan';
    await exportChats([convo], (s, d) async {}, out, password: 'pw', seal: flip);
    Future<String> seal(String src, String d, String name) async => '$d/$name';

    expect(await isSealedBackup(out), isTrue);
    await expectLater(importChats(out, dir.path, seal, open: unflip), throwsFormatException);
    final back = await importChats(out, dir.path, seal, password: 'pw', open: unflip);
    expect(back.single.messages.single.body, 'hey');
    expect(back.single.messages.single.status, MessageStatus.delivered);
  });

  test('a failed export leaves no half-written file', () async {
    final dir = Directory.systemTemp.createTempSync('tc-chats-fail');
    addTearDown(() => dir.delete(recursive: true));
    final out = '${dir.path}/chats.tincan';
    Future<void> broken(String src, String dst, String pw) async {
      File(dst).writeAsStringSync('partial');
      throw const FileSystemException('disk full');
    }
    await expectLater(
        exportChats([Conversation(id: 'a', name: 'nia')], (s, d) async {}, out, password: 'pw', seal: broken),
        throwsA(isA<FileSystemException>()));
    expect(File(out).existsSync(), isFalse);
  });
}

Future<void> _noCrypt(String src, String dst, String password) => throw StateError('no password given');
