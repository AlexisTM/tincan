import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'bridge.dart';

/// How the data key is protected.
enum LockMode {
  /// A random secret in the platform keystore, released after the
  /// device's own biometric or PIN check.
  device,

  /// A password only the user knows. Nothing recoverable if forgotten.
  password,

  /// A random secret in the platform keystore, released without asking.
  /// Protects a copied disk, not an unlocked device. No longer offered;
  /// stores made with it keep working.
  none;

  /// What setup and lock changes offer.
  static const choices = [device, password];

  /// Only a real lock can be locked; an unlocked store would just reopen.
  bool get lockable => this != none;

  /// An old store that opens without asking; Settings offers a real lock.
  bool get upgradable => this == none;
}

/// Unlocks the encrypted store. The key never leaves the transport: the
/// app only ever supplies the secret that unwraps it.
class VaultManager {
  VaultManager(this._bridge, this._stateDir);

  final Bridge _bridge;
  final String _stateDir;

  static const _storage = FlutterSecureStorage();
  static const _deviceKeyEntry = 'tincan.vault.devicekey';

  /// A new keystore secret waits here until the vault is rewrapped
  /// under it, so dying halfway never leaves the keystore holding a
  /// secret that unwraps nothing.
  static const _stagedKeyEntry = 'tincan.vault.devicekey.next';

  final _auth = LocalAuthentication();

  /// How the store is locked, as last read or set here.
  LockMode? mode;

  bool get canUpgradeLock => mode?.upgradable ?? false;

  /// Whether a store already exists here, and how it is locked.
  Future<({bool exists, LockMode? mode})> status() async {
    final s = await _bridge.vaultStatus(_stateDir);
    mode = LockMode.values.asNameMap()[s.mode];
    return (exists: s.exists, mode: mode);
  }

  /// Whether the device can gate the keystore behind biometrics or a
  /// screen lock. False on a device with neither.
  Future<bool> deviceLockAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Creates the store. Returns an error message, or null.
  Future<String?> create(LockMode mode, {String password = ''}) async {
    final err = await _withNewSecret(mode, password,
        (secret) => _bridge.vaultCreate(stateDir: _stateDir, secret: secret, mode: mode.name));
    if (err == null) this.mode = mode;
    return err;
  }

  /// Unlocks an existing store. For [LockMode.device] this prompts for
  /// biometrics; for a password, pass it in.
  Future<String?> unlock(LockMode mode, {String password = ''}) async {
    try {
      if (mode == LockMode.password) {
        if (password.isEmpty) return 'Enter your password.';
        await _bridge.vaultUnlock(stateDir: _stateDir, secret: password);
        return null;
      }
      if (mode == LockMode.device && !await _deviceAuth()) return 'Unlock cancelled.';
      return await _unlockFromKeystore();
    } catch (e) {
      return '$e';
    }
  }

  /// Tries the keystore secret, then a staged one a lock change may
  /// have left behind, keeping whichever opens the vault.
  Future<String?> _unlockFromKeystore() async {
    final current = await _storage.read(key: _deviceKeyEntry);
    final staged = await _storage.read(key: _stagedKeyEntry);
    Object? failure;
    for (final secret in [current, staged]) {
      if (secret == null || secret.isEmpty) continue;
      try {
        await _bridge.vaultUnlock(stateDir: _stateDir, secret: secret);
      } on BridgeException catch (e) {
        failure = e;
        continue;
      }
      if (secret != current) await _storage.write(key: _deviceKeyEntry, value: secret);
      if (staged != null) await _storage.delete(key: _stagedKeyEntry);
      return null;
    }
    return failure?.toString() ?? 'The key is missing from this device\'s keystore.';
  }

  /// Moves the account in a backup file into a store [create] just made.
  Future<String?> recover(String backup, {String password = ''}) async {
    try {
      await _bridge.importAccount(backup, password: password);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Forgets the keystore secret and deletes the store. Nothing in it
  /// can be read again.
  Future<void> erase() async {
    try {
      await _storage.delete(key: _deviceKeyEntry);
      await _storage.delete(key: _stagedKeyEntry);
    } catch (e) {
      debugPrint('tincan: clearing the device key: $e');
    }
    final dir = Directory(_stateDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    mode = null;
  }

  /// Switches how the store is locked, keeping the data.
  Future<String?> changeLock(LockMode mode, {String password = ''}) async {
    final err = await _withNewSecret(
        mode, password, (secret) => _bridge.vaultChangeSecret(secret: secret, mode: mode.name));
    if (err == null) this.mode = mode;
    if (err == null && mode == LockMode.password) {
      // The keystore secret no longer unwraps anything.
      try {
        await _storage.delete(key: _deviceKeyEntry);
        await _storage.delete(key: _stagedKeyEntry);
      } catch (e) {
        debugPrint('tincan: clearing the device key: $e');
      }
    }
    return err;
  }

  /// Returns an error message, or null.
  Future<String?> _withNewSecret(
      LockMode mode, String password, Future<void> Function(String secret) apply) async {
    if (!LockMode.choices.contains(mode)) return 'Pick a device lock or a password.';
    try {
      if (mode == LockMode.password) {
        if (password.isEmpty) return 'Pick a password.';
        await apply(password);
        return null;
      }
      final rnd = Random.secure();
      final secret = base64Url.encode(List.generate(32, (_) => rnd.nextInt(256)));
      await _storage.write(key: _stagedKeyEntry, value: secret);
      await apply(secret);
      try {
        await _storage.write(key: _deviceKeyEntry, value: secret);
        await _storage.delete(key: _stagedKeyEntry);
      } catch (e) {
        // Unlock still finds it staged.
        debugPrint('tincan: promoting the new device key: $e');
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// False means the user dismissed the biometric prompt.
  Future<bool> _deviceAuth() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Tincan',
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      if (e.code == LocalAuthExceptionCode.userCanceled ||
          e.code == LocalAuthExceptionCode.systemCanceled) {
        return false;
      }
      // A device with no lock of any kind has nothing to check against,
      // so the keystore entry alone is the key. Anything else fails.
      if (!_noDeviceLock.contains(e.code)) throw 'Unlock failed: ${e.description ?? e.code.name}';
      debugPrint('tincan: device auth unavailable: $e');
      return true;
    }
  }

  static const _noDeviceLock = {
    LocalAuthExceptionCode.noCredentialsSet,
    LocalAuthExceptionCode.noBiometricHardware,
    LocalAuthExceptionCode.noBiometricsEnrolled,
  };
}
