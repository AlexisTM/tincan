import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../files.dart';
import '../theme.dart';
import '../vault.dart';
import 'radio_row.dart';
import 'text_input.dart';
import 'toast.dart';

/// First run: choose how the store is locked. Everything the app keeps
/// is encrypted with a key this choice protects. Starts a new account,
/// or brings one back from an account backup.
class VaultSetupScreen extends StatefulWidget {
  const VaultSetupScreen({
    super.key,
    required this.vault,
    required this.onReady,
    this.pickBackup = _pickAccountFile,
  });

  final VaultManager vault;
  final VoidCallback onReady;
  final Future<String?> Function() pickBackup;

  static Future<String?> _pickAccountFile() =>
      pickFile(const [XTypeGroup(label: 'Account', extensions: ['json'])]);

  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen> {
  String? _backup;

  @override
  void dispose() {
    // It holds the private key in plaintext.
    unawaited(releasePicked(_backup));
    super.dispose();
  }

  Future<void> _chooseBackup() async {
    final path = await widget.pickBackup();
    if (path == null || !mounted) return;
    unawaited(releasePicked(_backup));
    setState(() => _backup = path);
  }

  void _dropBackup() {
    unawaited(releasePicked(_backup));
    setState(() => _backup = null);
  }

  Future<String?> _submit(LockMode mode, String password) async {
    final vault = widget.vault;
    final err = await vault.create(mode, password: password);
    final backup = _backup;
    if (err != null || backup == null) return err;
    final failed = await vault.recover(backup);
    // Leave no half-made store behind, so setup can simply run again.
    if (failed != null) await vault.erase();
    return failed;
  }

  @override
  Widget build(BuildContext context) {
    final backup = _backup;
    return _Sheet(
      title: backup == null ? 'Protect your messages' : 'Recover your account',
      blurb: 'Your key, your conversations and everything people send you '
          'are encrypted on this device. Choose what unlocks them.',
      children: [
        if (backup != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              border: Border.all(color: Tc.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.restore, size: 18, color: Tc.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p.basename(backup),
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Tc.inkMuted),
                onPressed: _dropBackup,
                child: const Text('Start new instead', style: TextStyle(fontSize: 12.5)),
              ),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        LockPicker(
          vault: widget.vault,
          action: backup == null ? 'Continue' : 'Recover account',
          onSubmit: _submit,
          onDone: widget.onReady,
        ),
        if (backup == null) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: Tc.inkMuted),
              onPressed: _chooseBackup,
              child: const Text('Recover an account from a backup…',
                  style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ],
    );
  }
}

/// Device lock, password or no lock, with the password typed twice. Used
/// at setup and to change the lock later. Phones offer only the device
/// lock until the user asks for the alternatives.
class LockPicker extends StatefulWidget {
  const LockPicker({
    super.key,
    required this.vault,
    required this.action,
    required this.onSubmit,
    required this.onDone,
    this.initial = LockMode.device,
  });

  final VaultManager vault;
  final String action;
  final LockMode initial;

  /// Returns an error message, or null.
  final Future<String?> Function(LockMode mode, String password) onSubmit;
  final VoidCallback onDone;

  @override
  State<LockPicker> createState() => _LockPickerState();
}

class _LockPickerState extends State<LockPicker> {
  final _password = PlainTextEditingController();
  final _confirm = PlainTextEditingController();
  late LockMode _mode = widget.initial;
  late bool _showAll = !(Platform.isAndroid || Platform.isIOS) || widget.initial != LockMode.device;
  bool _deviceAvailable = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.vault.deviceLockAvailable().then((ok) {
      if (mounted) {
        setState(() {
          _deviceAvailable = ok;
          if (!ok && _mode == LockMode.device) _mode = LockMode.password;
        });
      }
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_mode == LockMode.password) {
      if (_password.text.length < 8) {
        setState(() => _error = 'Use at least 8 characters.');
        return;
      }
      if (_password.text != _confirm.text) {
        setState(() => _error = 'The passwords do not match.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onSubmit(_mode, _password.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RadioGroup<LockMode>(
        groupValue: _mode,
        onChanged: (v) => setState(() => _mode = v!),
        child: Column(children: [
          if (_deviceAvailable)
            _choice(LockMode.device, 'This device',
                'Unlock with your fingerprint, face or screen lock.'),
          if (_showAll || !_deviceAvailable) ...[
            _choice(LockMode.password, 'A password',
                'Only you know it. There is no way to recover it.'),
            _choice(LockMode.none, 'No lock',
                'Tincan opens straight away, without asking.'),
          ],
        ]),
      ),
      if (!_showAll && _deviceAvailable)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: Tc.inkMuted),
            onPressed: () => setState(() => _showAll = true),
            child: const Text('Other options', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      if (_mode == LockMode.none) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Tc.relayAmberBg,
            border: Border.all(color: Tc.relayAmberBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: Tc.relayAmberInk),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your messages stay encrypted, but anyone who can open this '
                'device can read them and take over your identity.',
                style: TextStyle(fontSize: 12, height: 1.4, color: Tc.relayAmberInk),
              ),
            ),
          ]),
        ),
      ],
      if (_mode == LockMode.password) ...[
        const SizedBox(height: 8),
        _field(_password, 'Password'),
        const SizedBox(height: 8),
        _field(_confirm, 'Repeat password'),
        const SizedBox(height: 6),
        const Text(
          'Forgetting it means losing the messages. Nothing is stored '
          'anywhere else, so nobody can reset it for you.',
          style: TextStyle(fontSize: 12, height: 1.4, color: Tc.inkFaint),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: const TextStyle(fontSize: 12.5, color: Tc.danger)),
      ],
      const SizedBox(height: 20),
      _PrimaryButton(label: widget.action, busy: _busy, onPressed: _submit),
    ]);
  }

  Widget _choice(LockMode mode, String title, String blurb) => RadioRow(
      value: mode, title: title, blurb: blurb, onTap: () => setState(() => _mode = mode));

  Widget _field(TextEditingController c, String label) => TextField(
        controller: c,
        obscureText: true,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _submit(),
        decoration: _inputDecoration(label),
      );
}

/// Later runs: unlock what is already there.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({
    super.key,
    required this.vault,
    required this.mode,
    required this.onUnlocked,
    required this.onErase,
  });

  final VaultManager vault;
  final LockMode mode;
  final VoidCallback onUnlocked;

  /// Deletes everything here so setup can start over or recover.
  final Future<void> Function() onErase;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _password = PlainTextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.mode == LockMode.device) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.vault.unlock(widget.mode, password: _password.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.onUnlocked();
  }

  Future<void> _erase() async {
    final sure = await confirmDialog(context,
        title: 'Erase Tincan on this device?',
        body: 'Without the ${widget.mode == LockMode.password ? 'password' : 'device lock'}, '
            'nothing stored here can be read. Erasing deletes your messages, media and '
            'identity on this device.\n\nAfterwards you can recover your account from '
            'a backup, or start a new one.',
        action: 'Erase');
    if (!sure || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onErase();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final byPassword = widget.mode == LockMode.password;
    return _Sheet(
      title: 'Tincan is locked',
      blurb: byPassword
          ? 'Enter your password to open your messages.'
          : 'Unlock with your fingerprint, face or screen lock.',
      children: [
        if (byPassword) ...[
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _unlock(),
            decoration: _inputDecoration('Password'),
          ),
          const SizedBox(height: 12),
        ],
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(fontSize: 12.5, color: Tc.danger)),
          const SizedBox(height: 12),
        ],
        _PrimaryButton(label: byPassword ? 'Unlock' : 'Try again', busy: _busy, onPressed: _unlock),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: Tc.inkMuted),
            onPressed: _busy ? null : _erase,
            child: const Text("Can't unlock? Recover or start over…",
                style: TextStyle(fontSize: 12.5)),
          ),
        ),
      ],
    );
  }
}

InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.busy, required this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 46,
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: busy ? null : onPressed,
          child: busyOr(
              busy,
              Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              size: 18),
        ),
      );
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.blurb, required this.children});

  final String title;
  final String blurb;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Tc.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(blurb,
                    style: const TextStyle(fontSize: 13.5, height: 1.5, color: Tc.inkMuted)),
                const SizedBox(height: 20),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
