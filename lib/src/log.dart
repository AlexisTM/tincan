import 'package:flutter/foundation.dart';

/// Tests mute it; flutter test shows every line otherwise.
@visibleForTesting
bool logMuted = false;

void appLog(String message) {
  if (!logMuted) debugPrint(message);
}
