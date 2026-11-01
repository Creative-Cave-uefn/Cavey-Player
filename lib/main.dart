import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'ui/smooth_scroll.dart';
import 'core/log.dart';
import 'core/share_link.dart';
import 'core/single_instance.dart';
import 'core/window_style.dart';

Future<void> main(List<String> args) async {
  runZonedGuarded(() async {
    CaveBinding.ensureInitialized();
    // Уже запущена другая копия (возможно, спрятанная в трее) — показываем её и выходим
    final link = linkFromArgs(args);
    if (!claimSingleInstance(link: link)) exit(0);
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
      // Системную шапку прячем: вместо неё своя, прозрачная, поверх стеклянного фона
      if (Platform.isWindows) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
        tintCaption();
      }
      // Окно нельзя сжать до пары пикселей: меньше этого вёрстка уже не помещается
      await windowManager.setMinimumSize(const Size(560, 440));
    } catch (e) {
      AppLog.warn('Окно: управление не запустилось', e);
    }
    final app = await AppServices.create();
    if (link != null) app.incomingLink.value = link;
    runApp(CavePlayerApp(app: app));
  }, (error, stack) => AppLog.error('Необработанная ошибка', error, stack));
}
