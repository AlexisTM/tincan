import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Brief bottom confirmation ("Copied", "Saved") — one at a time.
void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message, textAlign: TextAlign.center),
      behavior: SnackBarBehavior.floating,
      width: 260,
      duration: const Duration(milliseconds: 1600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
}

/// Surfaces an action's error, if any, once the action has settled.
Future<void> showError(BuildContext context, FutureOr<String?> result) async {
  final error = await result;
  if (error == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(error),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
}

/// showDialog, with the dialog's own messenger so its toasts land in
/// front of the barrier rather than behind it.
Future<T?> showTincanDialog<T>(BuildContext context, WidgetBuilder builder,
    {bool barrierDismissible = true}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => DialogScope(
      dismissible: barrierDismissible,
      child: Builder(builder: builder),
    ),
  );
}

class DialogScope extends StatelessWidget {
  const DialogScope({super.key, required this.child, this.dismissible = true});

  final Widget child;
  final bool dismissible;

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(children: [
          // The scaffold covers the barrier, so it takes over its tap.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissible ? () => Navigator.of(context).maybePop() : null,
            ),
          ),
          child,
        ]),
      ),
    );
  }
}

/// Cancel/confirm dialog; true only when the user confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = true,
}) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) {
      final tc = TincanColors.of(context);
      return AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        content: Text(body, style: const TextStyle(fontSize: 13.5, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: tc.inkMuted))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: destructive ? tc.danger : tc.accent,
                foregroundColor: destructive ? tc.dialog : tc.accentInk),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      );
    },
  );
  return sure == true;
}

Future<bool> confirmDeleteConversation(BuildContext context, String name) => confirmDialog(
      context,
      title: 'Delete this conversation?',
      body: 'Removes the messages with $name from this device and disconnects. '
          'They are not blocked, so either of you can start talking again.',
      action: 'Delete',
    );
