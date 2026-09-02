import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/app_state.dart';
import 'src/bridge.dart';
import 'src/theme.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/unlock_screen.dart';
import 'src/vault.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TincanApp());
}

class TincanApp extends StatelessWidget {
  const TincanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tincan',
      debugShowCheckedModeBanner: false,
      theme: tincanTheme(),
      home: const _Boot(),
    );
  }
}

/// Resolves where state lives, unlocks it, then starts the app. Nothing
/// is read or written before the store is open.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  final _bridge = TincanBridge();
  late final AppState _state = AppState(_bridge);

  String? _stateDir;
  String? _downloadDir;
  VaultManager? _vault;
  LockMode? _lockedWith;
  bool _needsSetup = false;
  bool _open = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      // TINCAN_HOME gives a second instance its own identity.
      final home = Platform.environment['TINCAN_HOME'];
      final base = home != null && home.isNotEmpty
          ? home
          : (await getApplicationSupportDirectory()).path;
      if (!Platform.isAndroid && !Platform.isIOS) await _lockDataDir(base);
      _stateDir = p.join(base, 'state');
      _downloadDir = p.join(base, 'media');
      final vault = VaultManager(_bridge, _stateDir!);
      final status = await vault.status();
      if (status.exists && status.mode == LockMode.none) {
        final err = await vault.unlock(LockMode.none);
        if (err != null) throw err;
        _vault = vault;
        await _start();
        return;
      }
      if (!mounted) return;
      setState(() {
        _vault = vault;
        _needsSetup = !status.exists;
        _lockedWith = status.mode;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Held for the life of the process.
  static RandomAccessFile? _dataLock;

  /// Two desktop instances on one data dir would share an identity on
  /// the relay and overwrite each other's history.
  Future<void> _lockDataDir(String base) async {
    if (_dataLock != null) return;
    await Directory(base).create(recursive: true);
    final f = await File(p.join(base, '.lock')).open(mode: FileMode.write);
    try {
      await f.lock(FileLock.exclusive);
    } on FileSystemException {
      await f.close();
      throw 'Tincan is already running with this data ($base). '
          'Set TINCAN_HOME to run a second instance.';
    }
    _dataLock = f;
  }

  /// Leaves nothing behind but an empty data dir, then shows setup,
  /// which can recover from a backup.
  Future<void> _erase() async {
    await _vault!.erase();
    final media = Directory(_downloadDir!);
    if (await media.exists()) await media.delete(recursive: true);
    if (mounted) setState(() => _needsSetup = true);
  }

  Future<void> _start() async {
    await _state.init(stateDir: _stateDir!, downloadDir: _downloadDir!, vault: _vault!);
    if (mounted) setState(() => _open = true);
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Tc.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SelectableText('Tincan could not start.\n\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Tc.danger)),
          ),
        ),
      );
    }
    if (_open) return HomeScreen(state: _state);
    final vault = _vault;
    if (vault == null) {
      return const Scaffold(
        backgroundColor: Tc.bg,
        body: Center(child: CircularProgressIndicator(color: Tc.accent)),
      );
    }
    if (_needsSetup) {
      return VaultSetupScreen(vault: vault, onReady: _start);
    }
    return UnlockScreen(
      vault: vault,
      mode: _lockedWith ?? LockMode.password,
      onUnlocked: _start,
      onErase: _erase,
    );
  }
}
