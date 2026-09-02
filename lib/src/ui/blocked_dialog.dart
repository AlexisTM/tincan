import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'toast.dart';

Future<void> showBlockedDialog(BuildContext context, AppState state) {
  return showDialog(context: context, builder: (_) => BlockedDialog(state: state));
}

class BlockedDialog extends StatelessWidget {
  const BlockedDialog({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final blocked = state.blockedPeers;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Expanded(
                    child: Text('Blocked peers',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: Tc.inkMuted),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text(
                  'Blocked peers can\'t reach you at all — to them you look offline. Unblocking lets them send a new chat request.',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: Tc.inkMuted),
                ),
                const SizedBox(height: 14),
                if (blocked.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 26),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F1EC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('Nobody is blocked.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Tc.inkMuted)),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: blocked.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: Tc.border),
                      itemBuilder: (context, i) {
                        final b = blocked[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(b.displayName,
                                      style: const TextStyle(
                                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text(b.shortKey,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Tc.mono(11, Tc.inkFaint)),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              style: Tc.accentOutline,
                              onPressed: () => showError(context, state.unblockPeer(b.peer)),
                              child: const Text('Unblock'),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
