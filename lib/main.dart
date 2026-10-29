import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/log.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.init();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      AppLog.error('Ошибка интерфейса', details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLog.error('Необработанная ошибка', error, stack);
      return true;
    };
    MediaKit.ensureInitialized();
    final app = await AppServices.create();
    runApp(CavePlayerApp(app: app));
  }, (error, stack) => AppLog.error('Необработанная ошибка', error, stack));
}
