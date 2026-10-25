import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/app_state.dart';
import 'package:tincan/src/background.dart';
import 'package:tincan/src/bridge.dart';
import 'package:tincan/src/models.dart';
import 'package:tincan/src/theme.dart';
import 'package:tincan/src/ui/blocked_dialog.dart';
import 'package:tincan/src/ui/home_screen.dart';
import 'package:tincan/src/ui/new_chat_dialog.dart';
import 'package:tincan/src/ui/onboarding.dart';
import 'package:tincan/src/ui/profile_dialog.dart';
import 'package:tincan/src/ui/settings_page.dart';
import 'package:tincan/src/ui/thread_view.dart';
import 'package:tincan/src/ui/unlock_screen.dart';
import 'package:tincan/src/vault.dart';

class _NullBridge implements Bridge {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<Map<String, dynamic>> start({
    required String stateDir,
    required String downloadDir,
    required String name,
    String relay = '',
    bool directOnly = false,
  }) async =>
      {'type': 'server-started', 'address': 'tcX'};

  @override
  Future<void> setDirectOnly(bool on) async {}

  @override
  Future<void> cancelTransfer(String peer, String id) async {}

  @override
  Future<String> connect(String token) async => 'nk:1';

  @override
  Future<void> sendText(String peer, String id, String body, {String? replyTo}) async {}

  @override
  Future<void> sendReaction(String peer, String id, String ref, String emoji) async {}

  @override
  Future<void> sendTimer(String peer, String id, int seconds) async {}

  @override
  Future<void> ignore(String peer) async {}

  @override
  Future<void> setVerified(String peer, bool verified) async {}

  @override
  Future<void> setActivePeer(String? peer) async {}

  @override
  Future<void> stopTransport() async {}

  @override
  Future<void> lock() async {}

  @override
  Future<void> sealFile(String src, String dst, String password) async {}

  @override
  Future<void> openFile(String src, String dst, String password) async {}

  @override
  Future<FileMeta> sendFile(String peer, String id, String path) async =>
      const FileMeta('f', 'file', 1, '/media/f');

  @override
  Future<void> setProfile({
    required String name,
    String description = '',
    String status = '',
    String avatarPath = '',
    bool avatarChanged = false,
  }) async {}

  @override
  Future<Map<String, dynamic>> resetIdentity() async =>
      {'type': 'server-started', 'address': 'tcY'};

  @override
  Future<Map<String, dynamic>> restart() async =>
      {'type': 'server-started', 'address': 'tcZ'};

  @override
  Future<void> setNetInterfaces(String json) async {}

  final states = <String, Object>{};

  @override
  Future<({bool exists, String mode})> vaultStatus(String stateDir) async =>
      (exists: true, mode: 'password');

  String? createdMode;
  String? createdSecret;

  @override
  Future<void> vaultCreate({
    required String stateDir,
    required String secret,
    required String mode,
  }) async {
    createdMode = mode;
    createdSecret = secret;
  }

  @override
  Future<void> vaultUnlock({required String stateDir, required String secret}) async {}

  @override
  Future<void> vaultChangeSecret({required String secret, required String mode}) async {}

  @override
  Future<Object?> readState(String path) async => states[path];

  @override
  Future<void> writeState(String path, Object json) async => states[path] = json;

  @override
  Future<void> deleteState(String path) async => states.remove(path);

  @override
  Future<List<String>> listState(String dir) async => [
        for (final k in states.keys)
          if (k.startsWith('$dir/') && !k.substring(dir.length + 1).contains('/'))
            k.substring(dir.length + 1),
      ];

  @override
  Future<void> renameState(String src, String dst) async {
    if (states.remove(src) case final v?) states[dst] = v;
  }

  @override
  Future<void> decryptMedia(String src, String dst) async {}

  @override
  Future<String> importMedia(String src, String dir, String name) async => '$dir/$name';

  @override
  Future<void> exportAccount(String dst, {String password = ''}) async {}

  String? importedFrom;
  Object? importError;

  @override
  Future<void> importAccount(String src, {String password = ''}) async {
    if (importError != null) throw importError!;
    importedFrom = src;
  }



  final disconnected = <String>[];

  String? relay;

  @override
  Future<Map<String, dynamic>> setRelay(String host) async {
    relay = host;
    return {'type': 'server-started', 'address': 'tcRELAY'};
  }

  @override
  Future<void> disconnect(String peer) async => disconnected.add(peer);

  @override
  Future<void> accept(String peer) async {}

  @override
  Future<void> block(String peer) async {}

  @override
  Future<void> unblock(String peer) async {}

  @override
  Future<List<(String, String)>> listBlocked() async => const [];
}

AppState _populatedState() {
  final state = AppState(_NullBridge());
  state.handleEvent({'type': 'server-started', 'address': 'tcSOMEADDRESS1234567890', 'name': 'alexis'});
  state.handleEvent({'type': 'peer-added', 'peer': 'nk:1', 'name': 'Nia Okafor', 'outgoing': true, 'token': 'tcPEER'});
  state.handleEvent({'type': 'peer-status', 'peer': 'nk:1', 'direct': true, 'addr': '203.0.113.7:41641', 'latencyMs': 14});
  state.handleEvent({'type': 'message', 'peer': 'nk:1', 'id': 'm1', 'ts': 1000, 'body': 'morning! ⛰️'});
  state.handleEvent({'type': 'peer-request', 'peer': 'nk:2', 'name': 'Sam Kessler'});
  state.handleEvent({'type': 'peer-blocked', 'peer': 'nk:3', 'name': 'Dana Wolfe'});
  return state;
}

Widget _app(Widget child) => MaterialApp(theme: tincanTheme(), home: child);

void main() {
  testWidgets('home screen renders sidebar, request, and thread', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(HomeScreen(state: _populatedState()..select('nk:1'))));
    await tester.pump();
    expect(find.text('Tincan'), findsOneWidget);
    expect(find.text('Nia Okafor'), findsWidgets);
    expect(find.text('Sam Kessler'), findsOneWidget); // pending request tile
    expect(find.text('morning! ⛰️'), findsWidgets); // bubble + sidebar preview
    expect(find.textContaining('Direct'), findsWidgets);
  });

  testWidgets('wide: a chat with unread messages is not opened by itself', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    await tester.pumpWidget(_app(HomeScreen(state: state)));
    await tester.pump();
    expect(find.text('No conversation open'), findsOneWidget);
    expect(state.selectedId, isNull);
  });

  testWidgets('dark theme renders the home screen', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
        theme: tincanTheme(),
        darkTheme: tincanDarkTheme(),
        themeMode: ThemeMode.dark,
        home: HomeScreen(state: _populatedState()..select('nk:1'))));
    await tester.pump();
    final ctx = tester.element(find.byType(HomeScreen));
    expect(TincanColors.of(ctx), same(TincanColors.dark));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone width: list first, thread opens with back', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    state.select(null);
    await tester.pumpWidget(_app(HomeScreen(state: state)));
    await tester.pump();
    // List screen: conversation tile visible, no thread composer.
    expect(find.text('Nia Okafor'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);

    await tester.tap(find.text('Nia Okafor'));
    await tester.pump();
    expect(find.text('morning! ⛰️'), findsOneWidget); // thread
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing); // back on list
  });

  testWidgets('phone width: new chat dialog stacks into one column', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(NewChatDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Connect to a peer'), findsOneWidget);
    expect(find.text('Share your Tincan ID'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple requests collapse into one line', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    state.handleEvent({'type': 'peer-request', 'peer': 'nk:4', 'name': 'Priya'});
    state.handleEvent({'type': 'peer-request', 'peer': 'nk:5', 'name': 'Tomás'});
    await tester.pumpWidget(_app(HomeScreen(state: state)));
    await tester.pump();
    expect(find.text('3 chat requests'), findsOneWidget);
    expect(find.text('Priya'), findsNothing); // hidden until Review
    expect(find.text('Review'), findsOneWidget);
  });

  testWidgets('new chat dialog lays out with QR code', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(NewChatDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Start a conversation'), findsOneWidget);
    expect(find.text('Copy Tincan ID'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    expect(find.byTooltip('Read a QR code from an image'), findsOneWidget);
    expect(find.text('Generate a new address…'), findsNothing); // in Settings now
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile dialog renders and saves', (tester) async {
    await tester.pumpWidget(_app(ProfileDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('thread header keeps its actions at the far right', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(HomeScreen(state: _populatedState()..select('nk:1'))));
    await tester.pump();

    final menu = tester.getRect(find.byType(PopupMenuButton<String>));
    // The header spans the pane right of the 288px sidebar.
    const paneRight = 1280.0;
    expect(paneRight - menu.right, lessThan(20),
        reason: 'the ⋮ menu drifted left of the header edge');
  });

  testWidgets('settings dialog offers the background modes', (tester) async {
    BackgroundController.debugSupportedOverride = true;
    addTearDown(() => BackgroundController.debugSupportedOverride = null);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(SettingsDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.text('1 hour'), findsOneWidget);
    expect(find.text('Always'), findsNothing); // capped, so no endless mode
    expect(find.text('Generate a new Tincan ID…'), findsOneWidget);
    expect(find.text('Save chats…'), findsOneWidget);
    // The relay hides under Advanced until asked for.
    expect(find.text('Relay'), findsNothing);
    await tester.ensureVisible(find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await tester.pump();
    expect(find.text('Relay'), findsOneWidget);
  });

  testWidgets('changing the relay asks first, since it changes the ID', (tester) async {
    BackgroundController.debugSupportedOverride = false;
    addTearDown(() => BackgroundController.debugSupportedOverride = null);
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_app(SettingsDialog(state: _populatedState())));
    await tester.pump();
    await tester.tap(find.text('Advanced'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Relay'), 'relay.example.com');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Change the relay?'), findsOneWidget);
  });

  testWidgets('settings dialog explains itself on desktop', (tester) async {
    BackgroundController.debugSupportedOverride = false;
    addTearDown(() => BackgroundController.debugSupportedOverride = null);
    await tester.pumpWidget(_app(SettingsDialog(state: _populatedState())));
    await tester.pump();
    expect(find.textContaining('as long as its window is open'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('blocked dialog lists blocked peers with unblock', (tester) async {
    await tester.pumpWidget(_app(BlockedDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Dana Wolfe'), findsOneWidget);
    expect(find.text('Unblock'), findsOneWidget);
  });

  testWidgets('lock picker sets a password, never no lock', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final bridge = _NullBridge();
    final vault = VaultManager(bridge, '/state');
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: VaultSetupScreen(vault: vault, onReady: () => done = true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No lock'), findsNothing);
    await _choosePassword(tester);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(bridge.createdMode, 'password');
    expect(bridge.createdSecret, isNotEmpty);
    expect(done, isTrue);
  });

  testWidgets('password fields can be shown', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: VaultSetupScreen(vault: VaultManager(_NullBridge(), '/state'), onReady: () {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A password'));
    await tester.pump();
    bool obscured() => tester.widget<TextField>(find.byType(TextField).first).obscureText;
    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(obscured(), isFalse);
  });

  testWidgets('setup recovers an account from a backup', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final bridge = _NullBridge();
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: VaultSetupScreen(
          vault: VaultManager(bridge, '/state'),
          onReady: () => done = true,
          pickBackup: () async => '/backups/tincan-account.json'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Recover an account from a backup…'));
    // Checking the file for a seal is real IO.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('tincan-account.json'), findsOneWidget);
    await _choosePassword(tester);
    await tester.tap(find.text('Recover account'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(bridge.createdMode, 'password');
    expect(bridge.importedFrom, '/backups/tincan-account.json');
    expect(done, isTrue);
  });

  testWidgets('a backup that fails to import stops setup with the error', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final bridge = _NullBridge()..importError = BridgeException('not a tincan account file');
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: VaultSetupScreen(
          vault: VaultManager(bridge, '/nonexistent-tincan-state'),
          onReady: () => done = true,
          pickBackup: () async => '/backups/notes.json'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Recover an account from a backup…'));
    // Checking the file for a seal is real IO.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 400));
    await _choosePassword(tester);
    await tester.tap(find.text('Recover account'));
    // Erasing the half-made store is real file IO.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.textContaining('not a tincan account file'), findsOneWidget);
    expect(done, isFalse);
  });

  testWidgets('locked out, the unlock screen erases after confirming', (tester) async {
    var erased = false;
    await tester.pumpWidget(MaterialApp(
      home: UnlockScreen(
          vault: VaultManager(_NullBridge(), '/state'),
          mode: LockMode.password,
          onUnlocked: () {},
          onErase: () async => erased = true),
    ));
    await tester.tap(find.textContaining("Can't unlock?"));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Erase Tincan on this device?'), findsOneWidget);
    await tester.tap(find.text('Erase'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(erased, isTrue);
  });

  testWidgets('onboarding asks for a name and only a name gets past it', (tester) async {
    final state = _populatedState();
    expect(state.needsName, isTrue);
    await tester.pumpWidget(_app(NameStep(state: state)));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Alexis');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(state.needsName, isFalse);
    expect(state.selfName, 'Alexis');
  });

  testWidgets('a request can be ignored without blocking', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    state.handleEvent({
      'type': 'peer-request', 'peer': 'nk:2', 'name': 'Sam Kessler',
      'fp': '1234 5678 9012 3456 7890', 'first': 'hi, it is Sam from the climbing gym',
    });
    await tester.pumpWidget(_app(HomeScreen(state: state)));
    await tester.pump();
    expect(find.textContaining('climbing gym'), findsOneWidget);
    expect(find.textContaining('1234 5678'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    await tester.tap(find.text('Ignore'));
    await tester.pump();
    expect(state.requests, isEmpty);
    expect(state.blockedPeers.any((b) => b.peer == 'nk:2'), isFalse);
    expect(find.text('Sam Kessler'), findsNothing);
  });

  testWidgets('sidebar search finds messages and jumps to them', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    await tester.pumpWidget(_app(HomeScreen(state: state)));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Search messages'), 'MORNING');
    await tester.pump();
    final hit = find.byKey(const ValueKey('hit:nk:1:m1'));
    expect(hit, findsOneWidget);
    expect(find.descendant(of: hit, matching: find.text('Nia Okafor')), findsOneWidget);
    await tester.tap(hit);
    await tester.pump();
    expect(state.selectedId, 'nk:1');
    expect(hit, findsNothing);
    // The thread takes the focus and flashes the message.
    await tester.pump();
    expect(state.focused.value, isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('backups pass the optional password through', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final bridge = _PasswordBridge();
    final state = AppState(bridge)
      ..handleEvent({'type': 'server-started', 'address': 'tcA', 'name': 'alexis'});
    await tester.pumpWidget(_app(Scaffold(
        body: SettingsDialog(
            state: state, pickBackup: (_) async => '/backups/tincan-account.json'))));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'Backup password (optional)'), 'hunter2hunter2');
    await tester.ensureVisible(find.text('Restore account…'));
    await tester.tap(find.text('Restore account…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(bridge.importPassword, 'hunter2hunter2');
  });

  testWidgets('direct-only toggle applies at once', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final state = _populatedState();
    await tester.pumpWidget(_app(SettingsDialog(state: state)));
    await tester.pump();
    expect(find.textContaining('messages never pass through it'), findsOneWidget);
    final toggle = find.widgetWithText(SwitchListTile, 'Direct connections only');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.settings.directOnly, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  group('thread messages', () {
    Finder inThread(Finder f) => find.descendant(of: find.byType(ThreadView), matching: f);

    Future<AppState> openThread(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      final state = _populatedState()..select('nk:1');
      await tester.pumpWidget(_app(HomeScreen(state: state)));
      await tester.pump();
      return state;
    }

    Future<void> longPressMessage(WidgetTester tester, String text) async {
      await tester.longPress(inThread(find.text(text)));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('long-press opens the message menu; delete removes it here', (tester) async {
      final state = await openThread(tester);
      await longPressMessage(tester, 'morning! ⛰️');
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('👍'), findsOneWidget);
      expect(find.byTooltip('More reactions'), findsOneWidget);
      await tester.tap(find.text('Delete for me'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.conversations['nk:1']!.messageById('m1'), isNull);
      expect(inThread(find.text('morning! ⛰️')), findsNothing);
    });

    testWidgets('reply shows in the composer, then quoted in the bubble', (tester) async {
      final state = await openThread(tester);
      await longPressMessage(tester, 'morning! ⛰️');
      await tester.tap(find.text('Reply'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      await tester.enterText(inThread(find.byType(TextField)), 'agreed');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 100));
      final sent = state.conversations['nk:1']!.messages.last;
      expect(sent.body, 'agreed');
      expect(sent.replyTo, 'm1');
      expect(find.byTooltip('Cancel reply'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('^Quote from Nia Okafor: morning')), findsOneWidget);
    });

    testWidgets('reaction chips count, highlight mine, and toggle', (tester) async {
      final state = await openThread(tester);
      state.handleEvent({'type': 'react', 'peer': 'nk:1', 'id': 'r1', 'ref': 'm1', 'body': '❤️'});
      await tester.pump();
      await longPressMessage(tester, 'morning! ⛰️');
      await tester.tap(find.text('❤️'));
      await tester.pump(const Duration(milliseconds: 500));
      final msg = state.conversations['nk:1']!.messageById('m1')!;
      expect(msg.reactionOf('me'), '❤️');
      expect(find.text('❤️ 2'), findsOneWidget);
      expect(find.bySemanticsLabel('❤️ 2, yours'), findsOneWidget);
      await tester.tap(find.text('❤️ 2'));
      await tester.pump();
      expect(msg.reactionOf('me'), isNull);
      expect(find.text('❤️ 1'), findsOneWidget);
    });

    testWidgets('outgoing messages label their delivery state', (tester) async {
      final state = await openThread(tester);
      final convo = state.conversations['nk:1']!;
      final t0 = DateTime(2026, 1, 1, 9);
      for (final (i, s) in [
        MessageStatus.delivered,
        MessageStatus.sent,
        MessageStatus.sending,
        MessageStatus.queued,
        MessageStatus.failed,
      ].indexed) {
        convo.messages.add(ChatMessage(
            id: 's$i',
            outgoing: true,
            ts: t0.add(Duration(minutes: 10 * i)),
            kind: MessageKind.text,
            body: 'msg $i',
            status: s));
      }
      convo.changed();
      await tester.pump();
      for (final label in ['Delivered', 'Sent', 'Sending', 'Waiting to send', 'Not sent']) {
        expect(find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == label),
            findsOneWidget, reason: label);
      }
      await longPressMessage(tester, 'msg 4');
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}

class _PasswordBridge extends _NullBridge {
  String? importPassword;

  @override
  Future<void> importAccount(String src, {String password = ''}) async {
    importPassword = password;
  }
}

Future<void> _choosePassword(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  await tester.tap(find.text('A password'));
  await tester.pump();
  await tester.enterText(find.byType(TextField).at(0), 'correct horse');
  await tester.enterText(find.byType(TextField).at(1), 'correct horse');
}
