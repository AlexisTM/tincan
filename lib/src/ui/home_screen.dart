import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';
import 'new_chat_dialog.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'thread_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = FocusNode(debugLabel: 'search');

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _focusSearch() {
    // On a phone the search box lives on the list screen.
    if (state.selectedId != null && MediaQuery.sizeOf(context).width < 700) state.select(null);
    WidgetsBinding.instance.addPostFrameCallback((_) => _search.requestFocus());
  }

  void _step(int delta) {
    final list = state.ordered;
    if (list.isEmpty) return;
    final at = list.indexWhere((c) => c.id == state.selectedId);
    final next = at < 0 ? (delta > 0 ? 0 : list.length - 1) : (at + delta).clamp(0, list.length - 1);
    state.select(list[next].id);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            showNewChatDialog(context, state),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            showSettingsDialog(context, state),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          if (canLockNow(state)) state.lockNow();
        },
      },
      // Something in here must hold focus for the shortcuts to fire.
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
              final convo = state.selected;
              if (constraints.maxWidth < 700) {
                // On a phone the list is the screen, and picking a
                // conversation pushes the thread over it.
                return convo == null
                    ? Sidebar(state: state, fullWidth: true, searchFocus: _search)
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
              // Wide, a connected conversation fills the pane until one is
              // picked, unless it has unread messages: opening it would mark
              // them read before anyone saw them.
              final first = state.ordered.where((c) => c.connected).firstOrNull;
              final shown = convo ?? (first != null && first.unread == 0 ? first : null);
              if (convo == null && shown != null) {
                // Selected, so it stays put as the list reorders and its
                // messages arrive read.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (state.selectedId == null) state.select(shown.id);
                });
              }
              return Row(children: [
                Sidebar(state: state, searchFocus: _search),
                Expanded(
                  child: shown == null
                      ? _EmptyState(state: state)
                      : ThreadView(state: state, convo: shown),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tc = TincanColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 44, color: tc.inkFaint),
          const SizedBox(height: 16),
          const Text('No conversation open',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Pick one on the left, or share your Tincan ID to begin.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: tc.inkMuted)),
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
                  style: TextStyle(fontSize: 12, color: tc.danger)),
            ),
          ],
        ]),
      ),
    );
  }
}
