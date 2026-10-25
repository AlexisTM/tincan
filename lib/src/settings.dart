import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'bridge.dart';

/// How long to keep receiving after leaving the app; 0 is off.
const backgroundPresets = [0, 15, 60];

class Settings {
  Settings({
    int backgroundMinutes = 15,
    String relay = '',
    this.named = false,
    this.directOnly = false,
  })  : backgroundMinutes = snapBackground(backgroundMinutes),
        relay = relay.trim();

  /// 0 (off), 15 or 60.
  int backgroundMinutes;

  /// A relay hostname, or an http(s) URL of a relay map. Empty is the
  /// default relays.
  String relay;

  /// The user picked a display name once.
  bool named;

  /// Chat only over direct paths; the relay just introduces peers.
  bool directOnly;

  /// Any window snaps to a nonzero preset; only 0 is off.
  static int snapBackground(int minutes) {
    if (minutes <= 0) return 0;
    var best = backgroundPresets.firstWhere((p) => p > 0);
    for (final p in backgroundPresets.where((p) => p > 0)) {
      if ((p - minutes).abs() < (best - minutes).abs()) best = p;
    }
    return best;
  }

  // Older saves had a hostname and a map URL, the hostname winning.
  static String _relayFrom(String? relay, String? host, String? mapUrl) {
    for (final r in [relay, host, mapUrl]) {
      if (r != null && r.trim().isNotEmpty) return r;
    }
    return '';
  }

  Map<String, dynamic> toJson() => {
        'backgroundMinutes': backgroundMinutes,
        if (relay.isNotEmpty) 'relay': relay,
        'named': named,
        if (directOnly) 'directOnly': true,
      };

  static Settings fromJson(Map<String, dynamic> j) => Settings(
        // receiveInBackground predates backgroundMinutes.
        backgroundMinutes: j['receiveInBackground'] == false ? 0 : (j['backgroundMinutes'] as num?)?.toInt() ?? 15,
        relay: _relayFrom(j['relay'] as String?, j['derpHost'] as String?, j['derpMapUrl'] as String?),
        // Files from before naming was asked for have no key, and a name.
        named: j['named'] as bool? ?? true,
        directOnly: j['directOnly'] == true,
      );

  Settings copyWith({int? backgroundMinutes, String? relay, bool? named, bool? directOnly}) => Settings(
        backgroundMinutes: backgroundMinutes ?? this.backgroundMinutes,
        relay: relay ?? this.relay,
        named: named ?? this.named,
        directOnly: directOnly ?? this.directOnly,
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
