import 'dart:async';

import 'package:tincan/src/log.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  logMuted = true;
  await testMain();
}
