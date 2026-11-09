import 'dart:typed_data';

import 'package:cave_player/core/autostart.dart';
import 'package:cave_player/core/desktop_notify.dart';
import 'package:cave_player/core/notify_prefs.dart';
import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Настройки уведомлений', () {
    test('по умолчанию: уведомления, звук и Windows включены, громкость 60, автозапуска нет', () {
      final s = Settings();
      expect(s.notifyOn, isTrue);
      expect(s.notifySound, isTrue);
      expect(s.notifySystem, isTrue);
      expect(s.notifyVolume, 60);
      expect(s.notifyFile, '');
      expect(s.autostartMode, 'off');
    });

    test('значения читаются из view, мусор заменяется безопасным', () {
      final s = Settings();
      s.view['ntf.on'] = '0';
      s.view['ntf.vol'] = '250';
      s.view['autostart'] = 'tray';
      expect(s.notifyOn, isFalse);
      expect(s.notifyVolume, 100);
      expect(s.autostartMode, 'tray');
      s.view['autostart'] = 'что-то';
      expect(s.autostartMode, 'off');
    });

    test('громкость 0 — тишина, 100 — полная, шкала мягче кубической', () {
      expect(notifyMpvVolume(0), 0);
      expect(notifyMpvVolume(100), 100);
      expect(notifyMpvVolume(25), closeTo(50, 1e-9));
      expect(notifyMpvVolume(-5), 0);
    });
  });

  group('Звук уведомления', () {
    test('встроенный сигнал — корректный WAV: 16 бит, моно, звук не пустой и не обрезан', () {
      final w = buildChimeWav();
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(w.sublist(36, 40)), 'data');
      final dataLen = w.buffer.asByteData().getUint32(40, Endian.little);
      expect(w.length, 44 + dataLen);
      // Около 0,9 секунды при 44,1 кГц
      expect(dataLen ~/ 2, closeTo(44100 * 0.9, 2));
      var peak = 0;
      final bd = w.buffer.asByteData();
      for (var i = 44; i < w.length - 1; i += 2) {
        final v = bd.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      // Тише полной шкалы (мягкий), но слышно
      expect(peak, inInclusiveRange(4000, 24000));
      // Затухает: последние отсчёты почти нулевые
      expect(bd.getInt16(w.length - 2, Endian.little).abs(), lessThan(100));
    });
  });

  group('Автозапуск', () {
    test('команда в реестр: путь в кавычках и аргумент для запуска в трее', () {
      expect(Autostart.command(r'C:\Program Files\Cavey\cavey.exe', tray: false), r'"C:\Program Files\Cavey\cavey.exe"');
      expect(Autostart.command(r'C:\Cavey\cavey.exe', tray: true), r'"C:\Cavey\cavey.exe" --tray');
    });
  });

  group('Уведомление Windows', () {
    test('со значком: круглая картинка слева, свой идентификатор приложения и тихий режим', () {
      final script = toastScript('Cavey', 'Текст', iconPath: r'C:\Users\Вася\AppData\Local\Temp\cavey_toast_logo.png');
      expect(script, contains('ToastGeneric'));
      expect(script, contains('appLogoOverride'));
      expect(script, contains('hint-crop="circle"'));
      expect(script, contains('file:///C:/Users/Вася/AppData/Local/Temp/cavey_toast_logo.png'));
      expect(script, contains('<audio silent="true"/>'));
      expect(script, contains(toastAppId));
    });

    test('без значка картинки в разметке нет', () {
      expect(toastScript('Cavey', 'Текст'), isNot(contains('appLogoOverride')));
    });
  });
}
