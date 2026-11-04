// Renders app screens for the store listing: flutter test tool/store/screens_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tincan/src/app_state.dart';
import 'package:tincan/src/background.dart';
import 'package:tincan/src/models.dart';
import 'package:tincan/src/theme.dart';
import 'package:tincan/src/ui/home_screen.dart';
import 'package:tincan/src/ui/new_chat_dialog.dart';
import 'package:tincan/src/ui/profile_dialog.dart';
import 'package:tincan/src/ui/settings_page.dart';
import 'package:tincan/src/ui/sidebar.dart';
import 'package:tincan/src/ui/unlock_screen.dart';
import 'package:tincan/src/vault.dart';

import '../../test/app_state_test.dart' show FakeBridge, FakeNotifier;
import 'demo_chats.dart';

const outDir = 'tool/store/build/screens';
const phone = Size(1080, 2340);
const phoneRatio = 2.625;
const tablet = Size(2560, 1600);
const tabletRatio = 2.0;

const selfAddress = 'tc7m4kq2xv9hd3rwz8np6jf5ub2ls7ye4ga9tc3wk6mq8rh2vd5xp';

class StoreBridge extends FakeBridge {
  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String relay = '',
    bool directOnly = false,
  }) async =>
      {'type': 'server-started', 'address': selfAddress, 'name': selfName};

  @override
  Future<void> decryptMedia(String src, String dst) async {
    await Directory(p.dirname(dst)).create(recursive: true);
    await File(src).copy(dst);
  }
}

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

/// An unlocked app holding the demo chats, its media under [dir].
Future<AppState> demo(Directory dir) async {
  final media = Directory(p.join(dir.path, 'media'))..createSync(recursive: true);
  String write(String name, List<int> bytes) {
    final f = File(p.join(media.path, name))..writeAsBytesSync(bytes);
    return f.path;
  }

  final photos = {
    for (final e in demoPhotos.entries)
      e.key: write('${e.key}.jpg', demoPhoto(e.value.seed, e.value.sky, e.value.ground)),
  };
  final bridge = StoreBridge();
  final state = AppState(bridge, notifier: FakeNotifier());
  final stateDir = p.join(dir.path, 'state');
  final vault = VaultManager(bridge, stateDir);
  await vault.status();
  await state.init(stateDir: stateDir, downloadDir: media.path, vault: vault);
  state.handleEvent({
    'type': 'self-profile',
    'name': selfName,
    'status': selfStatus,
    'description': selfDescription,
    'avatarPath': write('me.png', demoAvatar([30, 36, 51], [19, 124, 122])),
  });

  final now = DateTime.now();
  for (final peer in demoPeers) {
    state.handleEvent({
      'type': 'peer-added',
      'peer': peer.id,
      'name': peer.name,
      'token': 'tc${peer.id.substring(3)}',
      'fp': '31415 92653 58979 32384 62643 38327',
      'verified': peer.verified,
    });
    state.handleEvent({
      'type': 'peer-profile',
      'peer': peer.id,
      'status': peer.status,
      'description': peer.description,
      if (peer.avatar case final a?) 'avatarPath': write('${peer.id.substring(3)}.png', demoAvatar(a, [255, 220, 190])),
    });
    if (peer.online) {
      state.handleEvent({
        'type': 'peer-status',
        'peer': peer.id,
        'direct': peer.direct,
        'addr': peer.direct ? '192.168.1.${20 + peer.latencyMs}:41641' : '',
        'relay': peer.direct ? '' : 'Frankfurt',
        'latencyMs': peer.latencyMs,
      });
    } else {
      state.handleEvent({'type': 'peer-removed', 'peer': peer.id});
    }
    final c = state.conversations[peer.id]!;
    c.messages.clear();
    for (final l in peer.lines) {
      final photo = l.photo == null ? null : photos[l.photo]!;
      c.messages.add(ChatMessage(
        id: l.id,
        outgoing: l.out,
        ts: now.subtract(Duration(minutes: l.minutesAgo)),
        kind: photo == null ? MessageKind.text : MessageKind.image,
        body: l.body,
        path: photo,
        name: photo == null ? null : p.basename(photo),
        size: photo == null ? null : File(photo).lengthSync(),
        status: MessageStatus.delivered,
        replyTo: l.reply,
        reactions: {
          ?l.react: {l.out ? peer.id : 'me'},
        },
      ));
      if (photo != null) state.plaintext(photo);
    }
    c
      ..unread = peer.unread
      ..changed();
  }
  state.handleEvent({'type': 'peer-request', 'peer': 'nk:jordan', 'name': 'Jordan Lee', 'first': 'Hey, it\'s Jordan from the climbing gym!'});
  return state;
}

/// Test fonts have no system fallback, so emoji need naming.
ThemeData withEmoji(ThemeData t) => t.copyWith(
    textTheme: t.textTheme.apply(fontFamilyFallback: const ['NotoColorEmoji']),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamilyFallback: const ['NotoColorEmoji']));

Future<void> shoot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 400));
  final image = await captureImage(find.byType(MaterialApp).evaluate().single);
  await t.runAsync(() async {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$outDir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Lets real IO (decrypted copies, images) land between frames.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 100));
  }
  // An image read before its decrypted copy landed never completes.
  for (final e in find.byType(Image).evaluate()) {
    await t.runAsync(() => precacheImage((e.widget as Image).image, e)
        .timeout(const Duration(seconds: 2), onTimeout: () {}));
  }
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final materialFonts = '$flutterRoot/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    WidgetsApp.debugAllowBannerOverride = false;
    BackgroundController.debugSupportedOverride = true;
    FlutterSecureStorage.setMockInitialValues({});
    await loadFont('SchibstedGrotesk', ['assets/fonts/SchibstedGrotesk.ttf']);
    await loadFont('IBMPlexMono', ['assets/fonts/IBMPlexMono-Regular.ttf', 'assets/fonts/IBMPlexMono-Medium.ttf']);
    await loadFont('Roboto', [for (final w in ['Regular', 'Medium', 'Bold']) '$materialFonts/Roboto-$w.ttf']);
    await loadFont('MaterialIcons', ['$materialFonts/MaterialIcons-Regular.otf']);
    const emoji = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';
    if (File(emoji).existsSync()) await loadFont('NotoColorEmoji', [emoji]);
  });

  void sizeTo(WidgetTester t, Size size, double ratio, {double bottom = 16}) {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = ratio;
    t.view.padding = FakeViewPadding(top: 24 * ratio, bottom: bottom * ratio);
    addTearDown(t.view.reset);
  }

  Future<AppState> pumpApp(WidgetTester t, {Brightness brightness = Brightness.light}) async {
    final dir = Directory.systemTemp.createTempSync('tincan-store');
    addTearDown(() => dir.deleteSync(recursive: true));
    final state = (await t.runAsync(() => demo(dir)))!;
    t.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: withEmoji(tincanTheme()),
      darkTheme: withEmoji(tincanDarkTheme()),
      home: HomeScreen(state: state),
    ));
    await settle(t);
    return state;
  }

  Future<void> pumpScreen(WidgetTester t, Widget home) async {
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: withEmoji(tincanTheme()),
      darkTheme: withEmoji(tincanDarkTheme()),
      home: home,
    ));
    await settle(t);
  }

  BuildContext ctx(WidgetTester t) => t.element(find.byType(HomeScreen));

  Future<void> close(WidgetTester t) async {
    Navigator.of(ctx(t)).pop();
    await settle(t);
  }

  testWidgets('store phone screens', (t) async {
    sizeTo(t, phone, phoneRatio);
    final state = await pumpApp(t);
    await shoot(t, 'chats');
    state.select('nk:nia');
    await settle(t);
    await shoot(t, 'thread');
    state.select(null);
    await settle(t);
    showNewChatDialog(ctx(t), state);
    await settle(t);
    await shoot(t, 'new-chat');
    await close(t);
    showProfileDialog(ctx(t), state);
    await settle(t);
    await shoot(t, 'profile');
    await close(t);
    showSettingsDialog(ctx(t), state);
    await settle(t);
    await shoot(t, 'settings');
    await close(t);
    showRequestsDialog(ctx(t), state);
    await settle(t);
    await shoot(t, 'requests');
  });

  testWidgets('store dark thread', (t) async {
    sizeTo(t, phone, phoneRatio);
    final state = await pumpApp(t, brightness: Brightness.dark);
    state.select('nk:nia');
    await settle(t);
    await shoot(t, 'thread-dark');
    state.select(null);
    await settle(t);
    await shoot(t, 'chats-dark');
  });

  testWidgets('store lock screens', (t) async {
    sizeTo(t, phone, phoneRatio);
    final vault = VaultManager(StoreBridge(), '/state');
    await pumpScreen(t, VaultSetupScreen(vault: vault, onReady: () {}));
    await shoot(t, 'setup');
    await pumpScreen(
        t, UnlockScreen(vault: vault, mode: LockMode.password, autoUnlock: false, onUnlocked: () {}, onErase: () async {}));
    await shoot(t, 'unlock');
  });

  testWidgets('store tablet screens', (t) async {
    sizeTo(t, tablet, tabletRatio, bottom: 0);
    final state = await pumpApp(t);
    state.select('nk:nia');
    await settle(t);
    await shoot(t, 'tablet-thread');
    showNewChatDialog(ctx(t), state);
    await settle(t);
    await shoot(t, 'tablet-new-chat');
    await close(t);
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    state.select('nk:sam');
    await settle(t);
    await shoot(t, 'tablet-dark');
  });
}
