import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'bridge.dart';

/// Android kills an app that holds a foreground service too long, and
/// caps the dataSync type at a few hours a day, so an unbounded window
/// is not on offer. An hour also bounds the battery cost.
const maxBackgroundMinutes = 60;

class Settings {
  Settings({
    this.receiveInBackground = true,
    this.backgroundMinutes = 15,
    this.derpHost = '',
    this.derpMapUrl = '',
  });

  /// Keep receiving for [backgroundMinutes] after leaving the app.
  bool receiveInBackground;

  /// Up to [maxBackgroundMinutes]; remembered while receiving is off.
  int backgroundMinutes;

  /// A relay of your own, by hostname. Wins over [derpMapUrl].
  String derpHost;

  /// A relay map to pick relays from, instead of the default one.
  String derpMapUrl;

  Map<String, dynamic> toJson() => {
        'receiveInBackground': receiveInBackground,
        'backgroundMinutes': backgroundMinutes,
        if (derpHost.isNotEmpty) 'derpHost': derpHost,
        if (derpMapUrl.isNotEmpty) 'derpMapUrl': derpMapUrl,
      };

  static Settings fromJson(Map<String, dynamic> j) => Settings(
        receiveInBackground: j['receiveInBackground'] as bool? ?? true,
        backgroundMinutes:
            ((j['backgroundMinutes'] as num?)?.toInt() ?? 15).clamp(1, maxBackgroundMinutes),
        derpHost: j['derpHost'] as String? ?? '',
        derpMapUrl: j['derpMapUrl'] as String? ?? '',
      );

  static const _file = 'preferences.json';

  /// Settings are cheap to lose, so an unreadable file means defaults.
  static Future<Settings> load(Bridge bridge, String stateDir) async {
    try {
      final json = await bridge.readState(p.join(stateDir, _file));
      return json is Map ? fromJson(json.cast<String, dynamic>()) : Settings();
    } catch (e) {
      debugPrint('tincan: unreadable settings, using defaults: $e');
      return Settings();
    }
  }

  Future<void> save(Bridge bridge, String stateDir) =>
      bridge.writeState(p.join(stateDir, _file), toJson());
}
