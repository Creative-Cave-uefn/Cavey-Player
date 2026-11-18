import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import '../config.dart';

/// Build check used by Cavey DevKit before a test build is published:
/// `cave_player.exe --smoke-test=<file.json>` loads the native player
/// libraries, renders one frame, writes what it was built as and exits.
/// It runs before the single-instance check and touches no user data.
const smokeTestArg = '--smoke-test=';

/// Path of the report file, or null when this is a normal launch.
String? smokeTestPath(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith(smokeTestArg) && arg.length > smokeTestArg.length) {
      return arg.substring(smokeTestArg.length);
    }
  }
  return null;
}

/// What the report contains; kept separate so it can be unit-tested.
Map<String, Object?> smokeTestReport({required bool mediaKit, required bool frame, String? error}) => {
      'version': kAppVersion,
      'channel': kBuildChannel,
      'mediaKit': mediaKit,
      'frame': frame,
      if (error != null) 'error': error,
    };

Future<Never> runSmokeTest(String path) async {
  var mediaKit = false, frame = false;
  String? error;
  try {
    MediaKit.ensureInitialized();
    mediaKit = true;
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    frame = true;
  } catch (e) {
    error = '$e';
  }
  await File(path).writeAsString(jsonEncode(smokeTestReport(mediaKit: mediaKit, frame: frame, error: error)));
  exit(error == null ? 0 : 1);
}
