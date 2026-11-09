import 'dart:ui' show Color;

import 'package:cave_player/core/jam.dart';
import 'package:cave_player/core/notices.dart';
import 'package:cave_player/core/notify_prefs.dart';
import 'package:cave_player/core/store.dart';
import 'package:cave_player/core/toast_window.dart';
import 'package:flutter_test/flutter_test.dart';

ToastSpec _spec({bool buttons = false, Color line = const Color(0x2EFFFFFF), Color bg = const Color(0xF0191920)}) => ToastSpec(
      title: 'Ник',
      text: 'Зовёт в джем',
      letter: 'Н',
      bg: bg,
      line: line,
      accent: const Color(0xFFB794F6),
      fg: const Color(0xFFFFFFFF),
      muted: const Color(0xB8FFFFFF),
      letterBg: const Color(0xFF445566),
      letterInk: const Color(0xFF000000),
      buttons: buttons,
    );

void main() {
  group('Окно уведомления Windows', () {
    test('полупрозрачная рамка не превращается в белую обводку', () {
      final script = toastWindowScript(_spec(), slot: 0, exe: 'x');
      expect(script, isNot(contains("\$line = '#ffffff'")));
      // Белый с прозрачностью 18% на тёмном фоне — тёмно-серый, заметно темнее белого
      final m = RegExp(r"\$line = '#([0-9a-f]{6})'").firstMatch(script)!;
      final r = int.parse(m.group(1)!.substring(0, 2), radix: 16);
      expect(r, lessThan(0x60));
      expect(r, greaterThan(0x19));
    });

    test('вместо выезда — плавное появление и затухание', () {
      final script = toastWindowScript(_spec(), slot: 0, exe: 'x');
      expect(script, contains('OpacityProperty'));
      expect(script, isNot(contains('LeftProperty')));
      expect(script, isNot(contains('CubicEase')));
      expect(script, contains(r'$w.Opacity = 0'));
    });

    test('кнопки показываются только когда нужны, ответ идёт кодом выхода', () {
      final plain = toastWindowScript(_spec(), slot: 0, exe: 'x');
      final withButtons = toastWindowScript(_spec(buttons: true), slot: 0, exe: 'x');
      expect(plain, contains(r'$buttons = $false'));
      expect(withButtons, contains(r'$buttons = $true'));
      expect(withButtons, contains(r'$global:code = 10'));
      expect(withButtons, contains(r'$global:code = 11'));
      expect(withButtons, contains(r'exit $code'));
    });
  });

  group('Какие уведомления показывать', () {
    test('по умолчанию у каждого вида включены и звук, и карточка', () {
      final s = Settings();
      for (final k in NoticeKind.values) {
        expect(s.soundFor(k), isTrue, reason: '$k');
        expect(s.popupFor(k), isTrue, reason: '$k');
      }
    });

    test('галочки строки таблицы действуют только на свой вид', () {
      final s = Settings();
      s.view['ntf.share.snd'] = '0';
      s.view['ntf.jam.pop'] = '0';
      expect(s.soundFor(NoticeKind.share), isFalse);
      expect(s.popupFor(NoticeKind.share), isTrue);
      expect(s.soundFor(NoticeKind.like), isTrue);
      expect(s.popupFor(NoticeKind.jamInvite), isFalse);
      expect(s.popupFor(NoticeKind.jamRequest), isFalse, reason: 'просьба войти идёт в одной строке с приглашением');
      expect(s.soundFor(NoticeKind.jamInvite), isTrue);
    });

    test('добавление в плейлист идёт вместе с лайком', () {
      final s = Settings();
      s.view['ntf.like.pop'] = '0';
      expect(s.popupFor(NoticeKind.addToPlaylist), isFalse);
    });

    test('общие выключатели главнее таблицы', () {
      final s = Settings();
      s.view['ntf.sound'] = '0';
      expect(s.soundFor(NoticeKind.like), isFalse);
      expect(s.popupFor(NoticeKind.like), isTrue);
      s.view['ntf.on'] = '0';
      expect(s.popupFor(NoticeKind.like), isFalse);
    });
  });

  group('Организатор джема', () {
    test('назначенный организатор остаётся им, пока он в джеме', () {
      expect(jamPickHost('b@x', ['a@x', 'b@x', 'c@x']), 'b@x');
    });

    test('организатора нет среди участников — первый по алфавиту, у всех одинаково', () {
      expect(jamPickHost('z@x', ['c@x', 'a@x', 'b@x']), 'a@x');
      expect(jamPickHost(null, ['c@x', 'b@x']), 'b@x');
      expect(jamPickHost('z@x', ['b@x', 'c@x']), jamPickHost('z@x', ['c@x', 'b@x']));
    });

    test('в пустом джеме остаётся назначенный', () {
      expect(jamPickHost('a@x', const []), 'a@x');
      expect(jamPickHost(null, const []), isNull);
    });

    test('в приглашении приходит организатор', () {
      final out = collectNotices(
        me: 'me@x',
        events: [
          (
            'a@x',
            DateTime(2026, 1, 1),
            {'k': 'jaminv', 'jam': 'j1', 'to': ['me@x'], 'host': 'boss@x'}
          ),
          (
            'b@x',
            DateTime(2026, 1, 2),
            {'k': 'jaminv', 'jam': 'j2', 'to': ['me@x']}
          ),
        ],
        uploaderOf: (_) => '',
      );
      expect(out.length, 2);
      final byJam = {for (final n in out) n.jam: n};
      expect(byJam['j1']!.host, 'boss@x');
      expect(byJam['j2']!.host, isNull);
    });
  });

  group('Снимок джема: кто добавил, организатор, переход', () {
    JamSnapshot snap({List<String> adders = const [], String? host, int hostAt = 0, int? xf, bool? smart}) => JamSnapshot(
          jam: 'j',
          by: 'a@x',
          at: 100,
          queue: const ['t1', 't2', 't3', 't4'],
          index: 1,
          playing: true,
          posMs: 5,
          adders: adders,
          host: host,
          hostAt: hostAt,
          xf: xf,
          smart: smart,
        );

    test('кто добавил трек, переживает передачу по каналу', () {
      final s = snap(adders: const ['a@x', 'b@x', '', 'a@x'], host: 'a@x', hostAt: 7, xf: 4, smart: false);
      final back = JamSnapshot.fromJson(s.toJson())!;
      expect(back.adders, ['a@x', 'b@x', '', 'a@x']);
      expect(back.host, 'a@x');
      expect(back.hostAt, 7);
      expect(back.xf, 4);
      expect(back.smart, false);
    });

    test('запись компактная: на очередь из 80 треков — единицы байт на «кто добавил»', () {
      final q = [for (var i = 0; i < jamQueueWindow; i++) 'x$i'];
      final withWho = JamSnapshot(
        jam: 'j',
        by: 'a@x',
        at: 1,
        queue: q,
        index: 0,
        playing: true,
        posMs: 0,
        adders: [for (var i = 0; i < q.length; i++) i.isEven ? 'a@x' : 'b@x'],
      );
      final bare = JamSnapshot(jam: 'j', by: 'a@x', at: 1, queue: q, index: 0, playing: true, posMs: 0);
      final extra = withWho.toJson().toString().length - bare.toJson().toString().length;
      expect(extra, lessThan(jamQueueWindow + 60));
    });

    test('без этих полей снимок читается как раньше', () {
      final back = JamSnapshot.fromJson(snap().toJson())!;
      expect(back.adders, isEmpty);
      expect(back.host, isNull);
      expect(back.xf, isNull);
      expect(back.smart, isNull);
    });

    test('рассогласованный список «кто добавил» игнорируется, а не ломает чтение', () {
      final j = snap(adders: const ['a@x', 'b@x', '', 'a@x']).toJson();
      j['w'] = '01';
      final back = JamSnapshot.fromJson(j)!;
      expect(back.adders, isEmpty);
      expect(back.queue.length, 4);
    });
  });
}
