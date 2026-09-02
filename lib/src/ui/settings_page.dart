import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../settings.dart';
import '../theme.dart';
import '../vault.dart';
import 'radio_row.dart';
import 'text_input.dart';
import 'toast.dart';
import 'unlock_screen.dart' show LockPicker;

Future<void> showSettingsDialog(BuildContext context, AppState state) {
  return showDialog(context: context, builder: (_) => SettingsDialog(state: state));
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late bool _receive = widget.state.settings.receiveInBackground;
  late final _minutes =
      PlainTextEditingController(text: '${widget.state.settings.backgroundMinutes}');
  late final _derpHost = PlainTextEditingController(text: widget.state.settings.derpHost);
  late final _derpMapUrl = PlainTextEditingController(text: widget.state.settings.derpMapUrl);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _minutes.dispose();
    _derpHost.dispose();
    _derpMapUrl.dispose();
    super.dispose();
  }

  Future<void> _changeLock(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
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
                const Text('Your data stays as it is; only what unlocks it changes.',
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: Tc.inkMuted)),
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
    final minutes = int.tryParse(_minutes.text.trim());
    if (_receive &&
        (minutes == null || minutes < 1 || minutes > maxBackgroundMinutes)) {
      setState(() => _error = 'Enter between 1 and $maxBackgroundMinutes minutes.');
      return;
    }
    setState(() => _busy = true);
    final err = await widget.state.saveSettings(Settings(
      receiveInBackground: _receive,
      backgroundMinutes: minutes ?? widget.state.settings.backgroundMinutes,
      derpHost: _derpHost.text.trim(),
      derpMapUrl: _derpMapUrl.text.trim(),
    ));
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Dialog(
      insetPadding: EdgeInsets.all(narrow ? 14 : 40),
      child: Container(
        width: 460,
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
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18, color: Tc.inkMuted),
                ),
              ]),
              const SizedBox(height: 10),
              Text('RECEIVE MESSAGES IN THE BACKGROUND', style: Tc.caps(Tc.label)),
              const SizedBox(height: 4),
              if (!widget.state.supportsBackgroundPolicy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                      'On this platform the app keeps receiving as long as its window is open.',
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: Tc.inkMuted)),
                )
              else ...[
                RadioGroup<bool>(
                  groupValue: _receive,
                  onChanged: (v) => setState(() => _receive = v!),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                RadioRow(
                  value: false,
                  title: 'Never',
                  blurb: 'Messages arrive only while Tincan is open. Uses no battery in the background.',
                  onTap: () => setState(() => _receive = false),
                ),
                RadioRow(
                  value: true,
                  title: 'For a while after leaving',
                  blurb: 'Keeps receiving for up to an hour once you leave the app.',
                  onTap: () => setState(() => _receive = true),
                ),
                if (_receive)
                  Padding(
                    padding: const EdgeInsets.only(left: 34, right: 8, bottom: 8),
                    child: Row(children: [
                      SizedBox(
                        width: 92,
                        child: TextField(
                          controller: _minutes,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text('minutes', style: TextStyle(fontSize: 13, color: Tc.inkMuted)),
                    ]),
                  ),
                  ]),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Android freezes backgrounded apps, so receiving needs an ongoing '
                  'notification while it lasts, and it caps how long that may run — '
                  'an hour is the most Tincan will ask for.',
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: Tc.inkFaint),
                ),
              ],
              const SizedBox(height: 20),
              Text('LOCK', style: Tc.caps(Tc.label)),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: Text(
                    switch (widget.state.lockMode) {
                      LockMode.device => 'Unlocks with this device\'s fingerprint, face or screen lock.',
                      LockMode.password => 'Unlocks with your password.',
                      LockMode.none => 'Opens without asking. The key sits in this device\'s keystore.',
                      null => 'Lock unknown.',
                    },
                    style: const TextStyle(fontSize: 12.5, height: 1.45, color: Tc.inkMuted),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: Tc.accentOutline,
                  onPressed: _busy ? null : () => _changeLock(context),
                  child: const Text('Change…'),
                ),
              ]),
              const SizedBox(height: 20),
              Text('RELAY', style: Tc.caps(Tc.label)),
              const SizedBox(height: 4),
              const Text(
                'Peers talk directly when they can. When a network blocks that, '
                'traffic is relayed — encrypted end to end, so a relay only ever '
                'sees ciphertext. Leave these empty to use the default relays.',
                style: TextStyle(fontSize: 12, height: 1.45, color: Tc.inkMuted),
              ),
              const SizedBox(height: 10),
              _text(_derpHost, 'Relay hostname', 'relay.example.com'),
              const SizedBox(height: 8),
              _text(_derpMapUrl, 'Or a relay map URL', 'https://example.com/relays.json'),
              const SizedBox(height: 6),
              const Text(
                'Changing the relay restarts the transport and changes your '
                'address, so anyone holding the old one has to be given the new one.',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: Tc.inkFaint),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(fontSize: 12, color: Tc.danger)),
              ],
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Tc.inkMuted)),
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

  Widget _text(TextEditingController c, String label, String hint) {
    return TextField(
      controller: c,
      enabled: !_busy,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 13, color: Tc.inkFaint),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}
