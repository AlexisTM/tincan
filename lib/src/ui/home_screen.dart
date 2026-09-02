import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'new_chat_dialog.dart';
import 'sidebar.dart';
import 'thread_view.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
          final convo = state.selected;
          if (constraints.maxWidth < 700) {
            // On a phone the list is the screen, and picking a
            // conversation pushes the thread over it.
            return convo == null
                ? Sidebar(state: state, fullWidth: true)
                : PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (_, _) => state.select(null),
                    child: ThreadView(
                      state: state,
                      convo: convo,
                      onBack: () => state.select(null),
                    ),
                  );
          }
          // Wide, a connected conversation fills the pane until one is picked.
          final shown = convo ?? state.ordered.where((c) => c.connected).firstOrNull;
          if (convo == null && shown != null) {
            // Selected, so it stays put as the list reorders and its
            // messages arrive read.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (state.selectedId == null) state.select(shown.id);
            });
          }
          return Row(children: [
            Sidebar(state: state),
            Expanded(
              child: shown == null
                  ? _EmptyState(state: state)
                  : ThreadView(state: state, convo: shown),
            ),
          ]);
        }),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.chat_bubble_outline_rounded, size: 44, color: Tc.inkFaint),
        const SizedBox(height: 16),
        const Text('No conversation open',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text('Share your address, or paste a peer\'s to begin.',
            style: TextStyle(fontSize: 13, color: Tc.inkMuted)),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () => showNewChatDialog(context, state),
          child: const Text('Start a conversation',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        if (state.startError != null) ...[
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(state.startError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Tc.danger)),
          ),
        ],
      ]),
    );
  }
}
