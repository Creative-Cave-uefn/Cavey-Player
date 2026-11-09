import 'dart:io';

import 'log.dart';

/// Автозапуск Cavey вместе с Windows: запись в `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
/// Права администратора не нужны, а в «Диспетчере задач → Автозагрузка» запись видна и отключается как обычно.
class Autostart {
  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _name = 'Cavey';

  /// Аргумент запуска «сразу в трей, окно не показывать»
  static const trayArg = '--tray';

  /// Команда для записи в реестр: путь к программе и, если нужно, аргумент
  static String command(String exe, {required bool tray}) => tray ? '"$exe" $trayArg' : '"$exe"';

  /// Включает автозапуск ([mode] show или tray) или выключает (off). Возвращает false, если не получилось
  static Future<bool> apply(String mode) async {
    if (!Platform.isWindows) return false;
    try {
      if (mode == 'off') {
        // Записи может и не быть: код выхода не важен
        await Process.run('reg', ['delete', _key, '/v', _name, '/f']);
        return true;
      }
      final r = await Process.run('reg', [
        'add',
        _key,
        '/v',
        _name,
        '/t',
        'REG_SZ',
        '/d',
        command(Platform.resolvedExecutable, tray: mode == 'tray'),
        '/f',
      ]);
      if (r.exitCode != 0) AppLog.warn('Автозапуск: reg add вернул ${r.exitCode}: ${r.stderr}');
      return r.exitCode == 0;
    } catch (e) {
      AppLog.warn('Автозапуск не настроился', e);
      return false;
    }
  }

  /// Что сейчас записано в реестре: off, show или tray
  static Future<String> current() async {
    if (!Platform.isWindows) return 'off';
    try {
      final r = await Process.run('reg', ['query', _key, '/v', _name]);
      if (r.exitCode != 0) return 'off';
      final out = '${r.stdout}';
      return out.contains(trayArg) ? 'tray' : 'show';
    } catch (_) {
      return 'off';
    }
  }
}
