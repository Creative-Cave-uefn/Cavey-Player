import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/window_style.dart';
import 'ui/smooth_scroll.dart';
import 'core/log.dart';
import 'core/single_instance.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    CaveBinding.ensureInitialized();
    // Уже запущена другая копия (возможно, спрятанная в трее) — показываем её и выходим
    if (!claimSingleInstance()) exit(0);
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
    try {
      await windowManager.ensureInitialized();
      await setupWindowStyle();
    } catch (e) {
      AppLog.warn('Окно: управление не запустилось', e);
    }
    final app = await AppServices.create();
    runApp(CavePlayerApp(app: app));
  }, (error, stack) => AppLog.error('Необработанная ошибка', error, stack));
}
