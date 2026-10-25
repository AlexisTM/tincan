import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../files.dart';
import '../settings.dart';
import '../theme.dart';
import '../vault.dart';
import 'radio_row.dart';
import 'sidebar.dart' show AdvancedToggle;
import 'text_input.dart';
import 'toast.dart';
import 'unlock_screen.dart' show LockPicker, PasswordField;

Future<void> showSettingsDialog(BuildContext context, AppState state) {
  return showTincanDialog(context, (_) => SettingsDialog(state: state));
}

/// Only a real lock can be locked; an unlocked store would just reopen.
bool canLockNow(AppState state) =>
    state.lockMode == LockMode.device || state.lockMode == LockMode.password;

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.state, this.pickBackup = _pick});

  final AppState state;

  /// Picks a backup to restore, given its file type; null if cancelled.
  final Future<String?> Function(XTypeGroup type) pickBackup;

  static Future<String?> _pick(XTypeGroup type) => pickFile([type]);

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late int _background = widget.state.settings.backgroundMinutes;
  late bool _directOnly = widget.state.settings.directOnly;
  late final String _relayWas = widget.state.settings.relay;
  late final _relay = PlainTextEditingController(text: _relayWas);
  final _backupPassword = PlainTextEditingController();
  late bool _advanced = _relayWas.isNotEmpty;
  String? _error;
  String? _note;
  bool _noteIsError = false;
  bool _busy = false;

  @override
  void dispose() {
    _relay.dispose();
    _backupPassword.dispose();
    super.dispose();
  }

  Future<void> _changeLock(BuildContext context) async {
    await showTincanDialog<void>(
      context,
      (dialogContext) => Dialog(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Change the lock',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('Your data stays as it is; only what unlocks it changes.',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: TincanColors.of(dialogContext).inkMuted)),
                const SizedBox(height: 10),
                LockPicker(
                  vault: widget.state.vault,
                  action: 'Change lock',
                  initial: widget.state.lockMode ?? LockMode.device,
                  onSubmit: widget.state.changeLock,
                  onDone: () {
                    Navigator.of(dialogContext).pop();
                    showToast(context, 'Lock changed');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final relay = _relay.text.trim();
    if (relay != _relayWas &&
        !await confirmDialog(context,
            title: 'Change the relay?',
            body: 'Tincan reconnects through the new relay and your Tincan ID changes. '
                'Anyone holding the old one has to be given the new one.',
            action: 'Change relay',
            destructive: false)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.state.saveSettings(
        widget.state.settings.copyWith(backgroundMinutes: _background, relay: relay));
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _run(Future<String?> Function() op, String doneNote) async {
    setState(() => _busy = true);
    final err = await op();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = err ?? doneNote;
      _noteIsError = err != null;
    });
    showToast(context, err == null ? doneNote : 'Failed: $err');
  }

  Future<void> _setDirectOnly(bool on) async {
    setState(() {
      _directOnly = on;
      _busy = true;
    });
    final err = await widget.state.setDirectOnly(on);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) _directOnly = !on;
    });
    if (err != null) showToast(context, 'Failed: $err');
  }

  Future<void> _lockNow() async {
    Navigator.of(context).pop();
    await widget.state.lockNow();
  }

  Future<void> _regenerate() async {
    if (!await confirmDialog(context,
        title: 'Generate a new Tincan ID?',
        body: 'Your current Tincan ID stops working for good, and every open conversation drops. Anyone who only has the old one can no longer reach you.',
        action: 'New Tincan ID')) {
      return;
    }
    await _run(widget.state.regenerateAddress, 'New Tincan ID generated.');
  }

  String get _password => _backupPassword.text;

  static const _accountType = XTypeGroup(label: 'Account', extensions: ['json']);
  static const _chatsType = XTypeGroup(label: 'Chats', extensions: ['zip']);

  Future<void> _saveAccount() async {
    final target = await chooseSaveTarget('tincan-account.json', const [_accountType]);
    if (target == null) return;
    final password = _password;
    await _run(
        () => target.write((path) => widget.state.exportAccount(path, password: password)),
        password.isEmpty
            ? 'Account saved. The file holds your private key, so guard it like a password.'
            : 'Account saved, sealed with the backup password.');
  }

  Future<void> _restoreAccount() async {
    final path = await widget.pickBackup(_accountType);
    if (path == null) return;
    try {
      if (!mounted ||
          !await confirmDialog(context,
              title: 'Restore this account?',
              body: 'Your current identity is replaced by the one in the backup, and every open conversation drops. Chat history on this device stays.',
              action: 'Restore',
              destructive: false) ||
          !mounted) {
        return;
      }
      final password = _password;
      await _run(
          () => widget.state.importAccount(path, password: password), 'Account restored.');
    } finally {
      // It holds the private key in plaintext.
      await releasePicked(path);
    }
  }

  Future<void> _saveChats() async {
    final target = await chooseSaveTarget('tincan-chats.zip', const [_chatsType]);
    if (target == null) return;
    final password = _password;
    await _run(() => target.write((path) => widget.state.exportChats(path, password: password)),
        'Chats saved (messages and shared media).');
  }

  Future<void> _restoreChats() async {
    final path = await widget.pickBackup(_chatsType);
    if (path == null) return;
    try {
      final password = _password;
      await _run(() => widget.state.importChats(path, password: password),
          'Chats restored (merged with what was here).');
    } finally {
      await releasePicked(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final blurb = TextStyle(fontSize: 12.5, height: 1.45, color: tc.inkMuted);
    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 4),
          child: Text(title, style: Tc.caps(tc.label)),
        );
    return Dialog(
      insetPadding: EdgeInsets.all(narrow ? 14 : 40),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Expanded(
                  child: Text('Settings',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, size: 18, color: tc.inkMuted),
                ),
              ]),
              section('RECEIVE IN THE BACKGROUND'),
              if (!widget.state.supportsBackgroundPolicy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                      'On this platform the app keeps receiving as long as its window is open.',
                      style: blurb),
                )
              else ...[
                RadioGroup<int>(
                  groupValue: _background,
                  onChanged: (v) => setState(() => _background = v!),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final m in backgroundPresets)
                      RadioRow(
                        value: m,
                        title: switch (m) { 0 => 'Off', 60 => '1 hour', _ => '$m minutes' },
                        blurb: m == 0 ? 'Messages arrive only while Tincan is open.' : '',
                        onTap: () => setState(() => _background = m),
                      ),
                  ]),
                ),
                Text('Android shows a notification while Tincan listens in the background.',
                    style: blurb),
              ],
              section('CONNECTIONS'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _directOnly,
                onChanged: _busy ? null : _setDirectOnly,
                title: const Text('Direct connections only', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                    'The relay only introduces you; messages never pass through it. '
                    'Contacts on other networks may be unreachable.',
                    style: blurb),
              ),
              section('LOCK'),
              Row(children: [
                Expanded(
                  child: Text(
                    switch (widget.state.lockMode) {
                      LockMode.device => 'Unlocks with this device\'s fingerprint, face or screen lock.',
                      LockMode.password => 'Unlocks with your password.',
                      LockMode.none => 'Opens without asking, so anyone holding this device can read your messages. Pick a real lock.',
                      null => 'Lock unknown.',
                    },
                    style: widget.state.lockMode == LockMode.none
                        ? blurb.copyWith(color: tc.danger)
                        : blurb,
                  ),
                ),
                const SizedBox(width: 8),
                // Old unlocked stores; same test as vault.canUpgradeLock.
                if (widget.state.lockMode == LockMode.none)
                  FilledButton(
                    onPressed: _busy ? null : () => _changeLock(context),
                    child: const Text('Set a lock…'),
                  )
                else
                  OutlinedButton(
                    style: tc.accentOutline,
                    onPressed: _busy ? null : () => _changeLock(context),
                    child: const Text('Change…'),
                  ),
              ]),
              if (canLockNow(widget.state)) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _lockNow,
                  icon: const Icon(Icons.lock_outline, size: 16),
                  label: const Text('Lock now'),
                ),
              ],
              section('ACCOUNT'),
              Text('Your Tincan ID is how people reach you. A new one cuts off everyone holding the old one.',
                  style: blurb),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: tc.danger, padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: _busy ? null : _regenerate,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Generate a new Tincan ID…'),
              ),
              section('BACKUPS'),
              Text(
                  'With a password, backups are encrypted and need it to restore. Without one, anyone holding the files can read them.',
                  style: blurb),
              const SizedBox(height: 10),
              PasswordField(
                controller: _backupPassword,
                label: 'Backup password (optional)',
                enabled: !_busy,
                onSubmitted: () {},
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _ghostButton('Save account…', _saveAccount)),
                const SizedBox(width: 8),
                Expanded(child: _ghostButton('Restore account…', _restoreAccount)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _ghostButton('Save chats…', _saveChats)),
                const SizedBox(width: 8),
                Expanded(child: _ghostButton('Restore chats…', _restoreChats)),
              ]),
              const SizedBox(height: 6),
              Text(
                  'The account file holds your private key. The chats file holds your history and shared media.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: tc.inkFaint)),
              if (_note != null) ...[
                const SizedBox(height: 8),
                Text(_note!,
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: _noteIsError ? tc.danger : tc.inkMuted)),
              ],
              const SizedBox(height: 14),
              AdvancedToggle(open: _advanced, onTap: () => setState(() => _advanced = !_advanced)),
              if (_advanced) ...[
                Text(
                  'Peers talk directly when they can, and through a relay when a network blocks that. '
                  'A relay only sees ciphertext. Leave empty for the default relays.',
                  style: blurb,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _relay,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: 'Relay',
                    hintText: 'relay.example.com or https://…/relays.json',
                    hintStyle: TextStyle(fontSize: 13, color: tc.inkFaint),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 6),
                Text('Changing it changes your Tincan ID.',
                    style: TextStyle(fontSize: 12, height: 1.4, color: tc.inkFaint)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(fontSize: 12.5, color: tc.danger)),
              ],
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: tc.inkMuted),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: busyOr(_busy, const Text('Save')),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ghostButton(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: _busy ? null : onTap,
      child: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }
}
