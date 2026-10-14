import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications for incoming messages and contact requests.
abstract class Notifier {
  /// [onOpen] gets the peer whose notification was tapped.
  Future<void> init(void Function(String peer) onOpen);

  /// Asks for permission where the platform requires it (Android 13+).
  Future<void> requestPermission();

  Future<void> message(String peer, String title, String line);

  Future<void> request(String peer, String name);

  Future<void> clear(String peer);
}

class SystemNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _lines = <String, List<String>>{};
  bool _ready = false;

  static const _maxLines = 6;

  @override
  Future<void> init(void Function(String peer) onOpen) async {
    if (!Platform.isAndroid && !Platform.isLinux) return;
    void open(NotificationResponse r) {
      if (r.payload case final String peer when peer.isNotEmpty) onOpen(peer);
    }

    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: open,
      );
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        if (launch!.notificationResponse case final r?) open(r);
      }
    } catch (e) {
      debugPrint('tincan: notifications unavailable: $e');
    }
  }

  @override
  Future<void> requestPermission() async {
    if (!_ready || !Platform.isAndroid) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('tincan: notification permission: $e');
    }
  }

  @override
  Future<void> message(String peer, String title, String line) async {
    final lines = _lines.putIfAbsent(peer, () => [])..add(line);
    if (lines.length > _maxLines) lines.removeAt(0);
    await _show(peer, title, lines.join('\n'), lines);
  }

  @override
  Future<void> request(String peer, String name) =>
      _show(peer, 'Contact request', '$name wants to chat', null);

  @override
  Future<void> clear(String peer) async {
    _lines.remove(peer);
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _idFor(peer));
    } catch (e) {
      debugPrint('tincan: clearing a notification: $e');
    }
  }

  Future<void> _show(String peer, String title, String body, List<String>? lines) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _idFor(peer),
        title: title,
        body: body,
        payload: peer,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'messages',
            'Messages',
            channelDescription: 'New messages and contact requests.',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            // The text stays off a secure lock screen.
            visibility: NotificationVisibility.private,
            styleInformation: lines == null || lines.length < 2
                ? null
                : InboxStyleInformation(lines, contentTitle: title),
          ),
          linux: const LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('tincan: showing a notification: $e');
    }
  }

  /// Stable across runs, unlike String.hashCode, so a restart still
  /// replaces the peer's notification rather than adding one.
  static int _idFor(String peer) {
    var h = 0x811c9dc5;
    for (final c in peer.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}
