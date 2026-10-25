import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/backup.dart';
import 'package:tincan/src/models.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tc-chats'));
  tearDown(() => dir.delete(recursive: true));

  ChatMessage media(String id, String path) => ChatMessage(
      id: id, outgoing: false, ts: DateTime(2026), kind: MessageKind.image, name: 'x', path: path);

  test('chats backup carries the history and maps media through the bridge', () async {
    Directory('${dir.path}/a').createSync();
    for (final f in ['ridge.jpg', 'a/ridge.jpg']) {
      File('${dir.path}/$f').writeAsStringSync(f);
    }
    final convo = Conversation(id: 'nk:1', name: 'nia', token: 'tcX')
      ..messages.addAll([
        ChatMessage(id: 'm1', outgoing: false, ts: DateTime(2026), kind: MessageKind.text, body: 'hey'),
        media('f1', '${dir.path}/ridge.jpg'),
        media('f2', '${dir.path}/a/ridge.jpg'),
        media('f3', '${dir.path}/ridge.jpg'),
        media('gone', '${dir.path}/missing.jpg'),
      ]);

    late String index;
    late List<(String, String)> sent;
    var pw = '';
    await exportChats([convo], '${dir.path}/out', password: 'pw',
        write: (dst, i, m, {String password = ''}) async {
      index = i;
      sent = m;
      pw = password;
    });
    expect(pw, 'pw');
    expect(sent, [
      ('${dir.path}/ridge.jpg', 'media/ridge.jpg'),
      ('${dir.path}/a/ridge.jpg', 'media/ridge (2).jpg'),
    ]);

    final restored = await importChats('${dir.path}/out', '/media', password: 'pw',
        read: (src, mediaDir, {String password = ''}) async => (
              index: index,
              media: {for (final (_, name) in sent) name: '$mediaDir/${name.substring(6)}'},
            ));
    final rc = restored.single;
    expect(rc.token, 'tcX');
    expect(rc.messages.first.body, 'hey');
    expect([for (final m in rc.messages.skip(1)) m.path],
        ['/media/ridge.jpg', '/media/ridge (2).jpg', '/media/ridge.jpg', null]);
  });

  test('a password-sealed chats backup needs its password', () async {
    final out = File('${dir.path}/chats.tincan')..writeAsBytesSync([0x54, 0x43, 0x42, 0x01, 9]);
    var reads = 0;
    Future<({String index, Map<String, String> media})> read(String src, String mediaDir,
        {String password = ''}) async {
      reads++;
      return (index: '{"v":2,"kind":"tincan-chats","conversations":[]}', media: <String, String>{});
    }

    expect(await isSealedBackup(out.path), isTrue);
    await expectLater(importChats(out.path, dir.path, read: read), throwsFormatException);
    expect(reads, 0);
    expect(await importChats(out.path, dir.path, password: 'pw', read: read), isEmpty);
  });

  test('a history that is not a chats backup is refused', () async {
    final out = File('${dir.path}/chats.zip')..writeAsStringSync('PK');
    await expectLater(
        importChats(out.path, dir.path,
            read: (src, mediaDir, {String password = ''}) async =>
                (index: '{"v":2,"conversations":[1]}', media: <String, String>{})),
        throwsFormatException);
  });
}
