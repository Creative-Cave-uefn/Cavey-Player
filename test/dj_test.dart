import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dj.dart';

void main() {
  group('тональность', () {
    test('Camelot, Open Key и обычная запись', () {
      expect(Camelot.parse('8A'), const Camelot(8, true));
      expect(Camelot.parse('08b'), const Camelot(8, false));
      expect(Camelot.parse(' 12A '), const Camelot(12, true));
      expect(Camelot.parse('1d'), const Camelot(8, false)); // Open Key: 1d = C
      expect(Camelot.parse('1m'), const Camelot(8, true)); // Open Key: 1m = Am
      expect(Camelot.parse('C'), const Camelot(8, false));
      expect(Camelot.parse('Am'), const Camelot(8, true));
      expect(Camelot.parse('A minor'), const Camelot(8, true));
      expect(Camelot.parse('F#m'), const Camelot(11, true));
      expect(Camelot.parse('Gb'), const Camelot(2, false));
      expect(Camelot.parse('Bb'), const Camelot(6, false));
      expect(Camelot.parse('D major'), const Camelot(10, false));
      expect(Camelot.parse('F♯'), const Camelot(2, false));
    });

    test('мусор не разбирается', () {
      expect(Camelot.parse(null), isNull);
      expect(Camelot.parse(''), isNull);
      expect(Camelot.parse('13A'), isNull);
      expect(Camelot.parse('0B'), isNull);
      expect(Camelot.parse('hello'), isNull);
    });

    test('запись и обратный разбор совпадают', () {
      for (var n = 1; n <= 12; n++) {
        for (final minor in [false, true]) {
          final k = Camelot(n, minor);
          expect(Camelot.parse(k.toString()), k);
        }
      }
    });

    test('совместимость: та же, соседи, относительные, далёкие', () {
      const a = Camelot(8, true);
      expect(Camelot.compat(a, const Camelot(8, true)), 1.0);
      expect(Camelot.compat(a, const Camelot(9, true)), 0.85);
      expect(Camelot.compat(a, const Camelot(7, true)), 0.85);
      expect(Camelot.compat(a, const Camelot(8, false)), 0.9); // относительный мажор
      expect(Camelot.compat(a, const Camelot(2, true)), 0.0);
      // Круг замкнут: 12 и 1 — соседи
      expect(Camelot.compat(const Camelot(12, false), const Camelot(1, false)), 0.85);
      // Симметрия
      expect(Camelot.compat(a, const Camelot(10, true)), Camelot.compat(const Camelot(10, true), a));
    });
  });

  group('темп', () {
    test('двойной и половинный темп — свои', () {
      expect(bpmStretch(80, 160), closeTo(0, 1e-9));
      expect(bpmStretch(160, 80), closeTo(0, 1e-9));
      expect(bpmStretch(120, 126), closeTo(0.05, 1e-9));
      expect(bpmStretch(100, 100), 0);
    });

    test('неизвестный или нулевой темп — бесконечно далеко', () {
      expect(bpmStretch(0, 100), double.infinity);
      expect(bpmStretch(100, -1), double.infinity);
    });
  });

  group('АвтоDJ', () {
    test('близкий темп и тональность лучше далёкого', () {
      const cur = DjSong('a', bpm: 124, key: Camelot(8, true));
      const good = DjSong('b', bpm: 126, key: Camelot(9, true));
      const badTempo = DjSong('c', bpm: 170, key: Camelot(8, true));
      const badKey = DjSong('d', bpm: 124, key: Camelot(2, true));
      final g = AutoDj.transition(cur, good);
      expect(g, greaterThan(AutoDj.transition(cur, badTempo)));
      expect(g, greaterThan(AutoDj.transition(cur, badKey)));
    });

    test('неизвестное лучше известного несовпадения, но хуже совпадения', () {
      const cur = DjSong('a', bpm: 124, key: Camelot(8, true));
      const same = DjSong('s', bpm: 124, key: Camelot(8, true));
      const unknown = DjSong('u');
      const mismatch = DjSong('m', bpm: 170, key: Camelot(2, false));
      expect(AutoDj.transition(cur, same), greaterThan(AutoDj.transition(cur, unknown)));
      expect(AutoDj.transition(cur, unknown), greaterThan(AutoDj.transition(cur, mismatch)));
    });

    test('гармоничное сведение можно выключить', () {
      const cur = DjSong('a', bpm: 124, key: Camelot(8, true));
      const far = DjSong('f', bpm: 124, key: Camelot(2, true));
      const near = DjSong('n', bpm: 124, key: Camelot(8, true));
      const off = DjOptions(harmonic: false);
      expect(AutoDj.transition(cur, far, off), AutoDj.transition(cur, near, off));
      expect(AutoDj.transition(cur, far), lessThan(AutoDj.transition(cur, near)));
    });

    test('предел разницы в темпе настраивается', () {
      const cur = DjSong('a', bpm: 100);
      const b = DjSong('b', bpm: 112); // 12 %
      expect(AutoDj.transition(cur, b, const DjOptions(maxBpmAdjust: 0.25)), greaterThan(0.1));
      expect(AutoDj.transition(cur, b, const DjOptions(maxBpmAdjust: 0.10)), lessThan(0.1));
    });

    test('следующий не из недавно игравших, пока есть другие', () {
      const cur = DjSong('cur', bpm: 120);
      const pool = [DjSong('a', bpm: 120), DjSong('b', bpm: 121), DjSong('c', bpm: 119)];
      final now = DateTime(2026, 1, 1, 12);
      final recent = {'a': now.subtract(const Duration(minutes: 5)), 'b': now.subtract(const Duration(minutes: 10))};
      final rnd = math.Random(7);
      for (var i = 0; i < 40; i++) {
        final next = AutoDj.pickNext(cur, pool, recent: recent, rnd: rnd, now: now);
        expect(next!.id, 'c');
      }
    });

    test('давно игравшие снова доступны', () {
      const cur = DjSong('cur', bpm: 120);
      const pool = [DjSong('a', bpm: 120)];
      final now = DateTime(2026, 1, 1, 12);
      final next = AutoDj.pickNext(cur, pool, recent: {'a': now.subtract(const Duration(hours: 3))}, now: now);
      expect(next?.id, 'a');
    });

    test('всё уже играло — всё равно что-то выбираем, но не текущий', () {
      const cur = DjSong('cur', bpm: 120);
      const pool = [DjSong('cur', bpm: 120), DjSong('a', bpm: 120)];
      final now = DateTime(2026, 1, 1, 12);
      final next = AutoDj.pickNext(cur, pool, recent: {'a': now}, now: now);
      expect(next?.id, 'a');
    });

    test('выбирать не из чего — null', () {
      const cur = DjSong('cur');
      expect(AutoDj.pickNext(cur, const [DjSong('cur')]), isNull);
      expect(AutoDj.pickNext(cur, const []), isNull);
    });

    test('цепочка: от самого медленного, каждый следующий — ближайший по темпу', () {
      const songs = [
        DjSong('100', bpm: 100),
        DjSong('80', bpm: 80),
        DjSong('104', bpm: 104),
        DjSong('82', bpm: 82),
        DjSong('98', bpm: 98),
      ];
      expect(AutoDj.chain(songs), ['80', '82', '98', '100', '104']);
    });

    test('цепочка начинается с указанного трека', () {
      const songs = [DjSong('a', bpm: 100), DjSong('b', bpm: 80), DjSong('c', bpm: 102)];
      expect(AutoDj.chain(songs, startId: 'a').first, 'a');
    });

    test('цепочка: ничего не теряется и не повторяется, неизвестные — в конце в прежнем порядке', () {
      const songs = [
        DjSong('u1'),
        DjSong('a', bpm: 128, key: Camelot(8, true)),
        DjSong('u2'),
        DjSong('b', bpm: 126, key: Camelot(9, true)),
        DjSong('c', bpm: 90),
      ];
      final r = AutoDj.chain(songs);
      expect(r.length, 5);
      expect(r.toSet().length, 5);
      expect(r.sublist(3), ['u1', 'u2']);
    });

    test('цепочка: пустой и одиночный список', () {
      expect(AutoDj.chain(const []), isEmpty);
      expect(AutoDj.chain(const [DjSong('x', bpm: 100)]), ['x']);
      expect(AutoDj.chain(const [DjSong('x'), DjSong('y')]), ['x', 'y']);
    });

    test('цепочка: один исполнитель не подряд, если есть выбор', () {
      const songs = [
        DjSong('a1', bpm: 100, artist: 'a'),
        DjSong('a2', bpm: 100, artist: 'a'),
        DjSong('b1', bpm: 101, artist: 'b'),
      ];
      final r = AutoDj.chain(songs, startId: 'a1');
      expect(r[1], 'b1');
    });
  });

  group('похожесть без интернета', () {
    test('один альбом и исполнитель — очень похожи', () {
      const a = SimTrack('a', artists: {'x'}, album: 'x\u0001album');
      const b = SimTrack('b', artists: {'x'}, album: 'x\u0001album');
      expect(similarity(a, b), closeTo(0.9, 1e-9));
    });

    test('ничего общего — ноль, трек сам себе не похож', () {
      const a = SimTrack('a', artists: {'x'}, album: 'x1', genres: {'rock'});
      const b = SimTrack('b', artists: {'y'}, album: 'y1', genres: {'jazz'});
      expect(similarity(a, b), 0);
      expect(similarity(a, a), 0);
    });

    test('общие плейлисты и жанры повышают сходство', () {
      const a = SimTrack('a', artists: {'x'}, genres: {'house', 'deep house'}, lists: {'p1', 'p2'});
      const b = SimTrack('b', artists: {'y'}, genres: {'house'}, lists: {'p1'});
      const c = SimTrack('c', artists: {'z'}, genres: {'house'});
      expect(similarity(a, b), greaterThan(similarity(a, c)));
      expect(similarity(a, c), greaterThan(0));
    });

    test('эпоха, темп и тональность дают небольшой плюс', () {
      const a = SimTrack('a', year: 2019, bpm: 120, key: Camelot(8, true));
      const near = SimTrack('b', year: 2020, bpm: 121, key: Camelot(8, true));
      const far = SimTrack('c', year: 1975, bpm: 70, key: Camelot(2, false));
      expect(similarity(a, near), greaterThan(similarity(a, far)));
      expect(similarity(a, near), lessThan(0.5));
    });

    test('результат не больше 1 и симметричен', () {
      const a = SimTrack('a', artists: {'x'}, album: 'al', genres: {'g'}, lists: {'p1', 'p2', 'p3'}, year: 2000);
      const b = SimTrack('b', artists: {'x'}, album: 'al', genres: {'g'}, lists: {'p1', 'p2', 'p3'}, year: 2000);
      expect(similarity(a, b), lessThanOrEqualTo(1));
      expect(similarity(a, b), similarity(b, a));
    });
  });

  group('настроение по звуку', () {
    const energyTags = ['energetic', 'dance'];
    const energyAnti = ['sleep', 'ambient'];
    const calmTags = ['chill', 'ambient'];

    test('про трек ничего не известно — null', () {
      expect(moodFitLocal('energy', energyTags, energyAnti), isNull);
    });

    test('быстрый и громкий — бодрое, медленный и тихий — спокойное', () {
      final fast = moodFitLocal('energy', energyTags, energyAnti, bpm: 140, loudDb: -11)!;
      final slow = moodFitLocal('energy', energyTags, energyAnti, bpm: 70, loudDb: -22)!;
      expect(fast, greaterThan(slow));
      final calmFast = moodFitLocal('calm', calmTags, const [], bpm: 140, loudDb: -11)!;
      final calmSlow = moodFitLocal('calm', calmTags, const [], bpm: 70, loudDb: -22)!;
      expect(calmSlow, greaterThan(calmFast));
    });

    test('двойной темп приводится к привычному', () {
      final a = moodFitLocal('energy', energyTags, energyAnti, bpm: 90, loudDb: -14)!;
      final b = moodFitLocal('energy', energyTags, energyAnti, bpm: 180, loudDb: -14)!;
      expect(a, closeTo(b, 1e-9));
      final half = moodFitLocal('energy', energyTags, energyAnti, bpm: 50, loudDb: -14)!;
      final whole = moodFitLocal('energy', energyTags, energyAnti, bpm: 100, loudDb: -14)!;
      expect(half, closeTo(whole, 1e-9));
    });

    test('минор добавляет грусти и мрака', () {
      const sadTags = ['sad'];
      final minor = moodFitLocal('sad', sadTags, const [], bpm: 80, loudDb: -18, key: const Camelot(8, true))!;
      final major = moodFitLocal('sad', sadTags, const [], bpm: 80, loudDb: -18, key: const Camelot(8, false))!;
      expect(minor, greaterThan(major));
      final darkMinor = moodFitLocal('dark', const ['dark'], const [], key: const Camelot(5, true))!;
      final darkMajor = moodFitLocal('dark', const ['dark'], const [], key: const Camelot(5, false))!;
      expect(darkMinor, greaterThan(darkMajor));
    });

    test('жанр с подсказкой поднимает оценку, с антитегом — опускает', () {
      final plain = moodFitLocal('energy', energyTags, energyAnti, bpm: 120, loudDb: -14)!;
      final withTag = moodFitLocal('energy', energyTags, energyAnti, bpm: 120, loudDb: -14, genre: 'Dance Pop')!;
      final withAnti = moodFitLocal('energy', energyTags, energyAnti, bpm: 120, loudDb: -14, genre: 'Dark Ambient')!;
      expect(withTag, greaterThan(plain));
      expect(withAnti, lessThan(plain));
    });

    test('оценка всегда от 0 до 1', () {
      for (final mood in ['energy', 'calm', 'sad', 'love', 'dark', 'focus']) {
        for (final bpm in [50.0, 90.0, 130.0, 200.0]) {
          final v = moodFitLocal(mood, const ['x'], const ['y'], bpm: bpm, loudDb: -30, key: const Camelot(3, true), genre: 'x y')!;
          expect(v, inInclusiveRange(0, 1));
        }
      }
    });
  });
}
