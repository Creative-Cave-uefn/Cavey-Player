// Журнал работы и крашей. Пишется в cave-player.log рядом с настройками;
// при превышении 1 МБ старый журнал переименовывается в cave-player.1.log.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config.dart';

class AppLog {
  static Directory? _dir;
  static int errorsThisRun = 0;

  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}cave_player${Platform.pathSeparator}logs');
      await d.create(recursive: true);
      _dir = d;
      info('Запуск Cavey ${kAppVersion.isEmpty ? '(сборка для разработки)' : kAppVersion}, '
          '${Platform.operatingSystemVersion}');
    } catch (_) {
      // без журнала приложение всё равно должно работать
    }
  }

  static Directory? get dir => _dir;
  static File? get file => _dir == null ? null : File('${_dir!.path}${Platform.pathSeparator}cave-player.log');

  static void info(String message) => _write('INFO', message);
  static void warn(String message, [Object? error]) => _write('WARN', error == null ? message : '$message: $error');

  static void error(String message, Object error, [StackTrace? stack]) {
    errorsThisRun++;
    _write('ERROR', '$message: $error${stack == null ? '' : '\n$stack'}');
  }

  static void _write(String level, String message) {
    final f = file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.lengthSync() > 1024 * 1024) {
        final old = File('${_dir!.path}${Platform.pathSeparator}cave-player.1.log');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      final line = '${DateTime.now().toIso8601String()} $level $message\n';
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // диск занят или нет прав — молча пропускаем
    }
  }

  /// Последние строки журнала (для «Скопировать» и отправки)
  static String tail([int maxLines = 400]) {
    final f = file;
    if (f == null || !f.existsSync()) return '';
    try {
      final lines = f.readAsLinesSync();
      return lines.skip(lines.length > maxLines ? lines.length - maxLines : 0).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Сколько ошибок записано за последние [days] дней
  static int recentErrors([int days = 3]) {
    final f = file;
    if (f == null || !f.existsSync()) return 0;
    final since = DateTime.now().subtract(Duration(days: days));
    var n = 0;
    try {
      for (final l in f.readAsLinesSync()) {
        if (!l.contains(' ERROR ')) continue;
        final t = DateTime.tryParse(l.split(' ').first);
        if (t != null && t.isAfter(since)) n++;
      }
    } catch (_) {}
    return n;
  }
}
