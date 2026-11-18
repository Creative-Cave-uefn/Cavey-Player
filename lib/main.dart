import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'ui/smooth_scroll.dart';
import 'core/autostart.dart';
import 'core/log.dart';
import 'core/share_link.dart';
import 'core/single_instance.dart';
import 'core/smoke_test.dart';
import 'core/window_style.dart';

/// Автозапуск в трей: ждём, пока значок встанет, и прячем окно. Не встал — окно остаётся, чтобы не потерять приложение
Future<void> _hideToTray(AppServices app) async {
  for (var i = 0; i < 40 && !app.tray.ready; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  if (!app.tray.ready) {
    AppLog.warn('Автозапуск в трей: значок не появился, окно оставлено на экране');
    return;
  }
  try {
    await windowManager.hide();
  } catch (e) {
    AppLog.warn('Автозапуск в трей: окно не спряталось', e);
  }
}

Future<void> main(List<String> args) async {
  runZonedGuarded(() async {
    CaveBinding.ensureInitialized();
    // Build check from Cavey DevKit: report what this build is and exit, before anything else runs
    final smokeTest = smokeTestPath(args);
    if (smokeTest != null) await runSmokeTest(smokeTest);
    // Уже запущена другая копия (возможно, спрятанная в трее) — показываем её и выходим
    final link = linkFromArgs(args);
    // Автозапуск «в трей» (--tray): окно не показываем, а если Cavey уже запущена — ничего не делаем
    final startInTray = args.contains(Autostart.trayArg);
    if (!claimSingleInstance(link: link, quiet: startInTray)) exit(0);
    await AppLog.init();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      AppLog.error('Ошибка интерфейса', details.exception, details.stack);
    };
    // Ошибка в одном виджете не должна заливать серым прямоугольником всё вокруг: в сборке без отладки
    // (там по умолчанию серый прямоугольник) вместо упавшего виджета остаётся пустое место, а причина — в журнале
    if (kReleaseMode) ErrorWidget.builder = (details) => const SizedBox.shrink();
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
    if (startInTray && Platform.isWindows) unawaited(_hideToTray(app));
  }, (error, stack) => AppLog.error('Необработанная ошибка', error, stack));
}
