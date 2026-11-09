import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:cave_player/core/autostart.dart';
import 'package:cave_player/core/desktop_notify.dart';
import 'package:cave_player/core/jam.dart';
import 'package:cave_player/core/notices.dart';
import 'package:cave_player/core/toast_window.dart';
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

  group('Плавный переход в джеме', () {
    test('опережение: моя позиция минус общая, если это похоже на переход', () {
      // Мой трек начался на 5 с раньше общего времени
      expect(jamMeasureLead(const Duration(seconds: 6), const Duration(seconds: 1)), const Duration(seconds: 5));
      // Совпадаем с общим временем — опережения нет
      expect(jamMeasureLead(const Duration(seconds: 1), const Duration(milliseconds: 900)), const Duration(milliseconds: 100));
      // Чуть отстаю (в пределах погрешности) — считаем нулём
      expect(jamMeasureLead(const Duration(milliseconds: 500), const Duration(milliseconds: 900)), Duration.zero);
    });

    test('слишком большой отрыв или отставание — это перемотка, нужна синхронизация', () {
      // Кто-то перемотал вперёд: я сильно позади
      expect(jamMeasureLead(const Duration(seconds: 10), const Duration(seconds: 70)), isNull);
      // Кто-то включил трек сначала, а я уже далеко ушёл вперёд
      expect(jamMeasureLead(const Duration(seconds: 60), const Duration(seconds: 1)), isNull);
      // Граница: ровно предел ещё опережение
      expect(jamMeasureLead(const Duration(seconds: 21), const Duration(seconds: 1)), const Duration(seconds: 20));
      expect(jamMeasureLead(const Duration(seconds: 22), const Duration(seconds: 1)), isNull);
    });
  });

  group('Карточка уведомления', () {
    String title(String id) => 'Песня';
    String label(String id) => 'Песня — Автор';
    final t0 = DateTime(2026, 1, 1);

    test('текст без имени: с заглавной буквы', () {
      expect(noticeBodyText(Notice(NoticeKind.like, 'a', t0, ['x']), title: title, label: label), 'Добавил(а) «Песня» в любимое');
      expect(noticeBodyText(Notice(NoticeKind.share, 'a', t0, ['x']), title: title, label: label), 'Поделился(ась): Песня — Автор');
      expect(noticeBodyText(const Notice(NoticeKind.jamInvite, 'a', DateTime(2026), []), title: title, label: label), 'Зовёт в джем');
    });

    test('окно уведомления: ник, текст, цвета и место в стопке попадают в скрипт', () {
      const spec = ToastSpec(
        title: "О'Брайен",
        text: 'Добавил(а) «Песня» в любимое',
        letter: 'О',
        bg: Color(0xFF201C24),
        line: Color(0xFF3A3340),
        accent: Color(0xFFB794F6),
        fg: Color(0xFFFFFFFF),
        muted: Color(0xFF9A93A3),
        letterBg: Color(0xFF445566),
        letterInk: Color(0xFFFFFFFF),
        avatarPath: r'C:\Users\Вася\AppData\Local\Temp\av.png',
      );
      final script = toastWindowScript(spec, slot: 2, exe: r"C:\Program Files\Cavey\cavey.exe");
      // Одинарные кавычки в нике удваиваются, иначе строка PowerShell сломается
      expect(script, contains("\$title = 'О''Брайен'"));
      expect(script, contains("\$bg = '#201c24'"));
      expect(script, contains("\$accent = '#b794f6'"));
      expect(script, contains('\$slot = 2'));
      expect(script, contains("\$avatar = 'C:\\Users\\Вася\\AppData\\Local\\Temp\\av.png'"));
      expect(script, contains('Topmost="True"'));
      expect(script, contains('ShowActivated="False"'));
      expect(script, contains('Dispatcher]::Run()'));
    });

    test('без аватарки путь пустой, остаётся кружок с буквой', () {
      const spec = ToastSpec(
        title: 'Ник',
        text: 'Текст',
        letter: 'Н',
        bg: Color(0xFF000000),
        line: Color(0xFF000000),
        accent: Color(0xFF000000),
        fg: Color(0xFF000000),
        muted: Color(0xFF000000),
        letterBg: Color(0xFF000000),
        letterInk: Color(0xFF000000),
      );
      expect(toastWindowScript(spec, slot: 0, exe: 'x'), contains("\$avatar = ''"));
    });
  });
}
