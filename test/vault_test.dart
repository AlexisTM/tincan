import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/bridge.dart';
import 'package:tincan/src/vault.dart';

class _VaultBridge implements Bridge {
  String unwraps = 'old';
  bool failRewrap = false;

  @override
  Future<void> vaultUnlock({required String stateDir, required String secret}) async {
    if (secret != unwraps) throw BridgeException('wrong password');
  }

  @override
  Future<void> vaultChangeSecret({required String secret, required String mode}) async {
    if (failRewrap) throw BridgeException('disk full');
    unwraps = secret;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const current = 'tincan.vault.devicekey', staged = 'tincan.vault.devicekey.next';
  const storage = FlutterSecureStorage();

  test('a rewrap that died before the keystore caught up still unlocks', () async {
    FlutterSecureStorage.setMockInitialValues({current: 'old', staged: 'new'});
    final bridge = _VaultBridge()..unwraps = 'new';
    expect(await VaultManager(bridge, '/s').unlock(LockMode.none), isNull);
    expect(await storage.read(key: current), 'new');
    expect(await storage.read(key: staged), isNull);
  });

  test('a failed lock change keeps the secret that unwraps the vault', () async {
    FlutterSecureStorage.setMockInitialValues({current: 'old'});
    final bridge = _VaultBridge()..failRewrap = true;
    final vault = VaultManager(bridge, '/s');
    expect(await vault.changeLock(LockMode.none), isNotNull);
    expect(await storage.read(key: current), 'old');
    expect(await vault.unlock(LockMode.none), isNull);
  });

  test('erasing forgets the keystore secret and the store', () async {
    FlutterSecureStorage.setMockInitialValues({current: 'old', staged: 'new'});
    final dir = await Directory.systemTemp.createTemp('tincan-vault-');
    final vault = VaultManager(_VaultBridge(), dir.path)..mode = LockMode.none;
    await vault.erase();
    expect(await storage.read(key: current), isNull);
    expect(await storage.read(key: staged), isNull);
    expect(await dir.exists(), isFalse);
    expect(vault.mode, isNull);
  });
}
