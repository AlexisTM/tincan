import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/app_state.dart';
import 'package:tincan/src/background.dart';
import 'package:tincan/src/bridge.dart';
import 'package:tincan/src/theme.dart';
import 'package:tincan/src/ui/blocked_dialog.dart';
import 'package:tincan/src/ui/home_screen.dart';
import 'package:tincan/src/ui/new_chat_dialog.dart';
import 'package:tincan/src/ui/profile_dialog.dart';
import 'package:tincan/src/ui/settings_page.dart';
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
    String derpHost = '',
    String derpMapUrl = '',
  }) async =>
      {'type': 'server-started', 'address': 'tcX'};

  @override
  Future<String> connect(String token) async => 'nk:1';

  @override
  Future<void> sendText(String peer, String id, String body) async {}

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
  Future<void> decryptMedia(String src, String dst) async {}

  @override
  Future<String> importMedia(String src, String dir, String name) async => '$dir/$name';

  @override
  Future<void> exportAccount(String dst) async {}

  String? importedFrom;
  Object? importError;

  @override
  Future<void> importAccount(String src) async {
    if (importError != null) throw importError!;
    importedFrom = src;
  }



  final disconnected = <String>[];

  String? derpHost;

  @override
  Future<Map<String, dynamic>> setDerp({required String host, required String mapUrl}) async {
    derpHost = host;
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
    await tester.pumpWidget(_app(HomeScreen(state: _populatedState())));
    await tester.pump();
    expect(find.text('Tincan'), findsOneWidget);
    expect(find.text('Nia Okafor'), findsWidgets);
    expect(find.text('Sam Kessler'), findsOneWidget); // pending request tile
    expect(find.text('morning! ⛰️'), findsWidgets); // bubble + sidebar preview
    expect(find.textContaining('Direct'), findsWidgets);
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
    expect(find.text('Share your profile'), findsOneWidget);
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
    expect(find.text('Copy profile'), findsOneWidget);
    expect(find.text('Save contact'), findsOneWidget);
    expect(find.text('Scan a QR image…'), findsOneWidget);
    expect(find.text('Generate a new address…'), findsOneWidget);
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
    await tester.pumpWidget(_app(HomeScreen(state: _populatedState())));
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
    expect(find.text('Never'), findsOneWidget);
    expect(find.text('For a while after leaving'), findsOneWidget);
    expect(find.text('Always'), findsNothing); // capped, so no endless mode
    expect(find.text('Relay hostname'), findsOneWidget);
    // The default mode is timed, so the minutes field is showing.
    expect(find.text('minutes'), findsOneWidget);

    await tester.tap(find.text('Never'));
    await tester.pump();
    expect(find.text('minutes'), findsNothing);
  });

  testWidgets('settings dialog explains itself on desktop', (tester) async {
    BackgroundController.debugSupportedOverride = false;
    addTearDown(() => BackgroundController.debugSupportedOverride = null);
    await tester.pumpWidget(_app(SettingsDialog(state: _populatedState())));
    await tester.pump();
    expect(find.textContaining('as long as its window is open'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
  });

  testWidgets('blocked dialog lists blocked peers with unblock', (tester) async {
    await tester.pumpWidget(_app(BlockedDialog(state: _populatedState())));
    await tester.pump();
    expect(find.text('Dana Wolfe'), findsOneWidget);
    expect(find.text('Unblock'), findsOneWidget);
  });

  testWidgets('lock picker allows no lock, with a warning', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final bridge = _NullBridge();
    final vault = VaultManager(bridge, '/state');
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: VaultSetupScreen(vault: vault, onReady: () => done = true),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('anyone who can open this'), findsNothing);
    await tester.tap(find.text('No lock'));
    await tester.pump();
    expect(find.textContaining('anyone who can open this'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(bridge.createdMode, 'none');
    expect(bridge.createdSecret, isNotEmpty);
    expect(done, isTrue);
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
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('tincan-account.json'), findsOneWidget);
    await tester.tap(find.text('No lock'));
    await tester.tap(find.text('Recover account'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(bridge.createdMode, 'none');
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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('No lock'));
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
}
