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
      width: 240,
      duration: const Duration(milliseconds: 1600),
      backgroundColor: Tc.sidebar,
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
      backgroundColor: Tc.sidebar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
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
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: Text(body, style: const TextStyle(fontSize: 13.5, height: 1.5)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Tc.inkMuted))),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: destructive ? Tc.danger : Tc.accent),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return sure == true;
}

Future<bool> confirmDeleteConversation(BuildContext context, String name) => confirmDialog(
      context,
      title: 'Delete this conversation?',
      body: 'Removes the messages with $name from this device and disconnects. '
          'They are not blocked — either of you can start talking again.',
      action: 'Delete',
    );
