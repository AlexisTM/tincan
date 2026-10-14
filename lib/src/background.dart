import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'settings.dart';

/// Starts and stops the Android foreground service as the app leaves
/// and re-enters the foreground. The service does no work of its own; it
/// just stops Android freezing the process, so the transport's idle
/// connection keeps delivering.
class BackgroundController with WidgetsBindingObserver {
  BackgroundController(this._settings);

  static const _channel = MethodChannel('tincan/service');
  Settings _settings;
  bool _observing = false;

  /// Flutter emits a burst of states while the activity attaches, some
  /// of them backgrounded-looking. None count until the first resume.
  bool _sawResumed = false;

  /// Lets tests exercise the mobile-only policy UI off Android.
  @visibleForTesting
  static bool? debugSupportedOverride;

  bool get supported => debugSupportedOverride ?? Platform.isAndroid;

  void start() {
    if (!supported || _observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void dispose() {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _stopService();
  }

  /// Applies a changed setting immediately.
  void update(Settings settings) {
    _settings = settings;
    if (!supported) return;
    // A null state at startup means launching, not backgrounded.
    if (_sawResumed && _backgrounded(WidgetsBinding.instance.lifecycleState)) {
      _applyBackgroundPolicy();
    } else {
      _stopService();
    }
  }

  /// `inactive` is transient (notification shade, permission dialog) and
  /// must not count as backgrounded.
  static bool _backgrounded(AppLifecycleState? state) =>
      state == AppLifecycleState.paused || state == AppLifecycleState.hidden;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!supported) return;
    if (state == AppLifecycleState.resumed) {
      _sawResumed = true;
      _stopService();
      return;
    }
    if (!_sawResumed) return; // still starting up
    // detached: Back closed the activity, but the engine and transport
    // live on with the process, so it counts as backgrounded.
    if (_backgrounded(state) || state == AppLifecycleState.detached) {
      // Not debounced: Android only allows starting a foreground service
      // in the short grace period after leaving the foreground.
      _applyBackgroundPolicy();
    }
    // inactive: leave whatever is running alone.
  }

  void _applyBackgroundPolicy() {
    if (_settings.receiveInBackground) {
      _startService(_settings.backgroundMinutes);
    } else {
      _stopService();
    }
  }

  Future<void> _startService(int stopAfterMinutes) async {
    try {
      debugPrint('tincan: background service on (stop after ${stopAfterMinutes}m)');
      await _channel.invokeMethod('start', {'stopAfterMinutes': stopAfterMinutes});
    } catch (e) {
      debugPrint('tincan: starting background service: $e');
    }
  }

  Future<void> _stopService() async {
    try {
      debugPrint('tincan: background service off');
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('tincan: stopping background service: $e');
    }
  }
}
