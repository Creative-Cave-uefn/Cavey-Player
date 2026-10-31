import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/karaoke.dart';
import 'package:cave_player/core/lyrics.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('слоги', () {
    String parts(String text) => syllableRanges(text).map((r) => text.substring(r.$1, r.$2)).join('|');

    test('русский делится по гласным', () {
      expect(parts('молоко'), 'мо|ло|ко');
      expect(parts('Я иду домой'), 'Я|и|ду|до|мой');
    });

    test('английский и односложные слова', () {
      expect(parts('hello world'), 'hel|lo|world');
    });

    test('японский — по знаку, знаки препинания пропускаем', () {
      expect(parts('心に雲'), '心|に|雲');
      expect(syllableRanges('— ...'), isEmpty);
    });

    test('время слогов идёт по порядку и не выходит за строку', () {
      final w = syllables('мо ло ко', ms(1000), ms(4000));
      expect(w.length, 3);
      for (var i = 1; i < w.length; i++) {
        expect(w[i].start >= w[i - 1].start, isTrue);
      }
      expect(w.first.start, ms(1000));
      expect(w.last.end <= ms(4000), isTrue);
    });
  });

  group('расширенный LRC', () {
    test('отметки слов убираются из текста и дают время', () {
      final ly = Lyrics.fromLrclib({
        'syncedLyrics': '[00:10.00]<00:10.00>Я <00:10.50>иду <00:11.00>домой\n[00:13.00]дальше',
      })!;
      expect(ly.lines.first.text, 'Я иду домой');
      final w = ly.lines.first.words!;
      expect(w.length, 3);
      expect(ly.lines.first.text.substring(w[1].from, w[1].to).trim(), 'иду');
      expect(w[1].start, ms(10500));
      expect(w[1].end, ms(11000));
      expect(ly.lines[1].words, isNull);
    });
  });

  group('сопоставление с Whisper', () {
    final lines = [const LyricLine(Duration(seconds: 10), 'Я иду домой'), const LyricLine(Duration(seconds: 14), 'под дождём')];
    final ends = [ms(14000), ms(18000)];

    test('слова получают время из распознанного, даже с ошибками распознавания', () {
      final heard = [
        HeardWord('я', ms(10100), ms(10400)),
        HeardWord('иду', ms(10500), ms(10900)),
        HeardWord('домой.', ms(11000), ms(11800)),
        HeardWord('пот', ms(14200), ms(14500)), // ослышался
        HeardWord('дождем', ms(14600), ms(15400)),
      ];
      final r = KaraokeAligner.align(lines, ends, heard);
      expect(r[0]!.map((w) => w.start).toList(), [ms(10100), ms(10500), ms(11000)]);
      expect(r[1]!.length, 2);
      expect(r[1]![1].start, ms(14600));
    });

    test('строку, которую почти не узнали, оставляем для слогов', () {
      final r = KaraokeAligner.align(lines, ends, [HeardWord('совсем', ms(10100), ms(10400)), HeardWord('другое', ms(10500), ms(10900))]);
      expect(r[0], isNull);
      expect(r[1], isNull);
    });

    test('слово не цепляется к чужой строке далеко по времени', () {
      final r = KaraokeAligner.align(lines, ends, [HeardWord('домой', ms(30000), ms(30500))]);
      expect(r[0], isNull);
    });

    test('разбор ответа whisper.cpp', () {
      final h = KaraokeService.parseWhisper({
        'transcription': [
          {'offsets': {'from': 100, 'to': 400}, 'text': ' Я'},
          {'offsets': {'from': 500, 'to': 900}, 'text': ' иду'},
          {'offsets': {'from': 0, 'to': 0}, 'text': ''},
        ],
      });
      expect(h.length, 2);
      expect(h[1].text, 'иду');
      expect(h[1].start, ms(500));
    });

    test('сохранение и чтение таймингов', () {
      final w = [
        [const KWord(0, 1, Duration(seconds: 1), Duration(seconds: 2))],
        null,
      ];
      final back = KaraokeService.decode(KaraokeService.encode(w))!;
      expect(back[0]!.single.end, const Duration(seconds: 2));
      expect(back[1], isNull);
    });

    test('начало строк: по первому слову, остальные — на общий сдвиг песни', () {
      final marks = [for (var i = 0; i < 6; i++) ms(10000 + i * 4000)];
      final first = <Duration?>[ms(10600), ms(14500), null, ms(22600), ms(26500), null];
      final s = KaraokeAligner.lineStarts(marks, first);
      expect(s[0], ms(10600));
      expect(s[1], ms(14500));
      expect(s[2], ms(18600)); // медиана сдвига 600 мс
      expect(s[5], ms(30600));
    });

    test('начало строк без данных — как в тексте', () {
      final marks = [ms(1000), ms(2000)];
      expect(KaraokeAligner.lineStarts(marks, [null, null]), marks);
    });


    test('текст сдвинут на 5 с — слова всё равно находятся (Ж2)', () {
      final words = 'я иду домой под дождём по длинной дороге в ночь'.split(' ');
      final shifted = [
        for (var i = 0; i < 4; i++) LyricLine(ms(10000 + i * 4000), ['я иду домой', 'под дождём по', 'длинной дороге', 'в ночь домой'][i]),
      ];
      final ends = [for (var i = 0; i < 4; i++) ms(14000 + i * 4000)];
      // На записи те же слова звучат на 5 с позже
      final heard = <HeardWord>[];
      final texts = ['я иду домой', 'под дождём по', 'длинной дороге', 'в ночь домой'];
      for (var li = 0; li < texts.length; li++) {
        var t = 15000 + li * 4000; // каждая строка звучит ровно на 5 с позже отметки в тексте
        for (final w in texts[li].split(' ')) {
          heard.add(HeardWord(w, ms(t), ms(t + 300)));
          t += 1000;
        }
      }
      expect(words.isNotEmpty, true);
      final shift = KaraokeAligner.globalShift(shifted, heard);
      expect(shift.inMilliseconds, inInclusiveRange(4000, 6000));
      final r = KaraokeAligner.align(shifted, ends, heard);
      expect(r[0], isNotNull);
    });

    test('слоги: пропущенное длинное слово получает больше времени (Ж4)', () {
      expect(KaraokeAligner.syllables('дорога'), 3);
      expect(KaraokeAligner.syllables('в'), 1);
    });

    test('язык по тексту', () {
      expect(KaraokeService.langOf(Lyrics(lines, synced: true)), 'ru');
      expect(KaraokeService.langOf(const Lyrics([LyricLine(Duration.zero, '心に雲を持つ少年')], synced: true)), 'ja');
      expect(KaraokeService.langOf(const Lyrics([LyricLine(Duration.zero, 'Blinding lights')], synced: true)), 'en');
    });
  });
}
