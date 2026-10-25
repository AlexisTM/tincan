import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// A tapped notification: a peer's messages, or their contact request.
typedef NotificationTap = ({String peer, bool request});

/// System notifications for incoming messages and contact requests.
abstract class Notifier {
  /// [onOpen] gets taps while the app runs. A tap that launched it is
  /// kept for [takeLaunchTap] instead, since nothing is loaded yet.
  Future<void> init(void Function(NotificationTap tap) onOpen);

  /// The tap that launched the app, once.
  NotificationTap? takeLaunchTap();

  /// Asks for permission where the platform requires it (Android 13+, iOS).
  Future<void> requestPermission();

  Future<void> message(String peer, String title, String line);

  Future<void> request(String peer, String name);

  Future<void> clear(String peer);

  /// Forgets the message text kept for stacking, and unless [keepShown]
  /// cancels every notification too.
  Future<void> clearAll({bool keepShown = false});
}

class SystemNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _lines = <String, List<String>>{};
  bool _ready = false;
  NotificationTap? _launch;

  static const _maxLines = 6;
  static const _requestTag = 'req:';

  static NotificationTap? _tapOf(NotificationResponse r) => switch (r.payload) {
        final String p when p.startsWith(_requestTag) && p.length > _requestTag.length =>
          (peer: p.substring(_requestTag.length), request: true),
        final String p when p.isNotEmpty => (peer: p, request: false),
        _ => null,
      };

  @override
  Future<void> init(void Function(NotificationTap tap) onOpen) async {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isIOS) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          // Asked for in requestPermission, not at launch.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (_tapOf(r) case final tap?) onOpen(tap);
        },
      );
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        if (launch!.notificationResponse case final r?) _launch = _tapOf(r);
      }
    } catch (e) {
      debugPrint('tincan: notifications unavailable: $e');
    }
  }

  @override
  NotificationTap? takeLaunchTap() {
    final tap = _launch;
    _launch = null;
    return tap;
  }

  @override
  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
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
      _show(peer, 'Contact request', '$name wants to chat', null, request: true);

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

  @override
  Future<void> clearAll({bool keepShown = false}) async {
    _lines.clear();
    if (!_ready || keepShown) return;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('tincan: clearing notifications: $e');
    }
  }

  Future<void> _show(String peer, String title, String body, List<String>? lines,
      {bool request = false}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _idFor(peer),
        title: title,
        body: body,
        payload: request ? '$_requestTag$peer' : peer,
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
          iOS: DarwinNotificationDetails(threadIdentifier: peer),
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
