import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/beats.dart';
import 'package:cave_player/core/crossfade.dart';
import 'package:cave_player/core/dj.dart';

/// Звук для проверок: моно, 4 кГц, 16 бит
class _Pcm {
  final ByteData data;
  final int n;
  _Pcm(int seconds)
      : n = seconds * beatRate,
        data = ByteData(seconds * beatRate * 2);

  void add(int i, double v) {
    if (i < 0 || i >= n) return;
    final cur = data.getInt16(i * 2, Endian.little) / 32768.0;
    data.setInt16(i * 2, ((cur + v).clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }

  Uint8List get bytes => data.buffer.asUint8List();
}

/// Ровная бочка на каждой доле, первая — на [first] секунде; чуть шума, чтобы не было идеальной тишины
Uint8List kicks(double bpm, int seconds, {double first = 0.7}) {
  final p = _Pcm(seconds);
  final period = 60.0 / bpm;
  var seed = 12345;
  double noise() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed / 0x7fffffff - 0.5) * 0.02;
  }

  for (var i = 0; i < p.n; i++) {
    p.add(i, noise());
  }
  for (var t = first; t < seconds - 0.2; t += period) {
    final at = (t * beatRate).round();
    for (var k = 0; k < 480; k++) {
      p.add(at + k, math.sin(2 * math.pi * 60 * k / beatRate) * math.exp(-k / 120.0) * 0.8);
    }
  }
  return p.bytes;
}

/// Бочки с акцентом на первой доле такта (громкая, потом тихие), первая — на [first] секунде
Uint8List accented(double bpm, int seconds, {double first = 0.7}) {
  final p = _Pcm(seconds);
  final period = 60.0 / bpm;
  var seed = 777;
  for (var i = 0; i < p.n; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    p.add(i, (seed / 0x7fffffff - 0.5) * 0.02);
  }
  var k = 0;
  for (var t = first; t < seconds - 0.2; t += period, k++) {
    final at = (t * beatRate).round();
    final amp = k % 4 == 0 ? 0.8 : 0.2;
    for (var j = 0; j < 480; j++) {
      p.add(at + j, math.sin(2 * math.pi * 60 * j / beatRate) * math.exp(-j / 120.0) * amp);
    }
  }
  return p.bytes;
}

/// Аккорды в заданной тональности: [chords] — пары (смещение корня от тоники, терция)
Uint8List chords(int tonic, List<(int, int)> chords, {int seconds = 40}) {
  final p = _Pcm(seconds);
  final segment = p.n ~/ 16;
  for (var s = 0; s < 16; s++) {
    final (root, third) = chords[s % chords.length];
    for (final iv in [0, third, 7]) {
      final midi = 48 + (tonic + root + iv) % 12;
      final f0 = 440 * math.pow(2, (midi - 69) / 12);
      for (var i = s * segment; i < (s + 1) * segment; i++) {
        final t = i / beatRate;
        var v = 0.0;
        for (final h in [1, 2, 3, 4]) {
          if (f0 * h < 1900) v += math.sin(2 * math.pi * f0 * h * t) / h;
        }
        p.add(i, v * 0.12);
      }
    }
  }
  return p.bytes;
}

/// Расстояние между двумя положениями на сетке с периодом [period] (мс)
double _phaseGap(int a, int b, double period) {
  final d = ((a - b) % period + period) % period;
  return math.min(d, period - d);
}

void main() {
  group('темп и доли', () {
    for (final bpm in [90.0, 120.0, 140.0]) {
      test('находит ${bpm.round()} ударов в минуту', () {
        final a = analyzePcm(kicks(bpm, 60));
        expect(a.bpm, isNotNull);
        expect(a.bpmConfidence, greaterThan(0.1));
        // Темп мог прийти вдвое больше или меньше: для подбора это одно и то же
        expect(bpmStretch(a.bpm!, bpm), lessThan(0.02));
      });
    }

    test('доли стоят там, где бьёт бочка', () {
      final a = analyzePcm(kicks(120, 60));
      expect(a.headBeatMs, isNotNull);
      expect(a.tailBeatMs, isNotNull);
      // Первая бочка на 700 мс, период 500 мс
      expect(_phaseGap(a.headBeatMs!, 700, 500), lessThan(40));
      expect(_phaseGap(a.tailBeatMs!, 700, 500), lessThan(40));
    });

    test('темп уточняется до сотых', () {
      final a = analyzePcm(kicks(123.37, 90));
      expect(a.bpm, closeTo(123.37, 0.06));
    });

    test('первая доля такта находится по акценту', () {
      final a = analyzePcm(accented(120, 60));
      expect(a.headBarMs, isNotNull);
      expect(a.tailBarMs, isNotNull);
      // Громкая бочка на 700 мс, такт — 2000 мс
      expect(_phaseGap(a.headBarMs!, 700, 2000), lessThan(60));
      expect(_phaseGap(a.tailBarMs!, 700, 2000), lessThan(60));
    });

    test('ровные бочки без акцента — первую долю не придумываем', () {
      final a = analyzePcm(kicks(120, 60));
      expect(a.headBeatMs, isNotNull);
      expect(a.headBarMs == null || _phaseGap(a.headBarMs!, 700, 500) < 40, isTrue);
    });

    test('шум без ритма не даёт уверенного темпа', () {
      final p = _Pcm(60);
      var seed = 99;
      for (var i = 0; i < p.n; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        p.add(i, (seed / 0x7fffffff - 0.5) * 0.4);
      }
      final a = analyzePcm(p.bytes);
      expect(a.bpmConfidence, lessThan(0.1));
      expect(a.headBeatMs, isNull);
    });

    test('слишком короткий трек не разбирается', () {
      final a = analyzePcm(kicks(120, 1));
      expect(a.bpm, isNull);
      expect(a.key, isNull);
    });

    test('привязка к доле: ближайшая точка сетки', () {
      expect(snapToBeat(1230, 200, 120), 1200); // сетка 200, 700, 1200 …
      expect(snapToBeat(1480, 200, 120), 1700);
      expect(snapToBeat(100, 200, 120), 200);
      expect(snapToBeat(5000, 200, 120, durationMs: 3000), 3000);
      expect(snapToBeat(4321, 0, 0), 4321); // темпа нет — не трогаем
    });
  });

  group('тональность', () {
    test('до мажор → 8B', () {
      final a = analyzePcm(chords(0, const [(0, 4), (5, 4), (7, 4), (0, 4)]));
      expect(a.key, '8B');
      expect(a.keyConfidence, greaterThan(0.5));
    });

    test('ля минор → 8A', () {
      // A = 9; i – iv – V – i
      final a = analyzePcm(chords(9, const [(0, 3), (5, 3), (7, 4), (0, 3)]));
      expect(a.key, '8A');
    });

    test('ре мажор → 10B', () {
      final a = analyzePcm(chords(2, const [(0, 4), (5, 4), (7, 4), (0, 4)]));
      expect(a.key, '10B');
    });

    test('запись Camelot по тонике', () {
      expect(camelotOf(0, false), '8B'); // C
      expect(camelotOf(9, true), '8A'); // Am
      expect(camelotOf(6, false), '2B'); // F#
      expect(camelotOf(3, true), '2A'); // D#m = Ebm
    });
  });

  group('форма волны', () {
    test('столько столбиков, сколько задано, и самый громкий — 255', () {
      final w = analyzePcm(kicks(120, 30)).wave;
      expect(w.length, waveBuckets);
      expect(w.reduce(math.max), 255);
      expect(w.every((v) => v >= 0 && v <= 255), isTrue);
    });
  });

  group('профиль трека', () {
    const base = MixProfile(durationMs: 200000, introMs: 1000, outroMs: 190000, endMs: 198000, loudDb: -14);

    test('JSON туда и обратно с темпом, тональностью, долями и волной', () {
      final p = base.withAnalysis(
        AudioAnalysis(bpm: 128, bpmConfidence: 0.6, headBeatMs: 250, tailBeatMs: 120, key: '8A', keyConfidence: 0.7, wave: [0, 10, 255, 128]),
        genre: 'house',
      );
      final back = MixProfile.fromJson(p.toJson())!;
      expect(back.v, MixProfile.version);
      expect(back.bpm, 128);
      expect(back.headBeatMs, 250);
      expect(back.tailBeatMs, 120);
      expect(back.key, '8A');
      expect(back.wave, [0, 10, 255, 128]);
      expect(back.genre, 'house');
    });

    test('старый профиль без новых полей читается и считается устаревшим', () {
      final old = MixProfile.fromJson({'d': 1000, 'i': 0, 'o': 900, 'e': 1000, 'l': -12})!;
      expect(old.v, 1);
      expect(old.bpm, isNull);
      expect(old.wave, isEmpty);
      expect(old.v < MixProfile.version, isTrue);
    });

    test('теги файла важнее своего разбора, спорящая сетка долей отбрасывается', () {
      const a = AudioAnalysis(bpm: 100, bpmConfidence: 0.5, headBeatMs: 100, tailBeatMs: 50, key: '3B', keyConfidence: 0.9);
      final tagged = base.withAnalysis(a, tagBpm: 128, tagKey: 'Am');
      expect(tagged.bpm, 128);
      expect(tagged.key, '8A');
      expect(tagged.headBeatMs, isNull); // 128 и 100 расходятся: сетке 100 верить нельзя
      final agree = base.withAnalysis(a, tagBpm: 101);
      expect(agree.bpm, 100); // сетка построена по своему темпу, он точнее округлённого в теге
      expect(agree.headBeatMs, 100);
    });

    test('неуверенный темп и тональность в профиль не попадают', () {
      const a = AudioAnalysis(bpm: 133, bpmConfidence: 0.05, headBeatMs: 10, key: '1A', keyConfidence: 0.3);
      final p = base.withAnalysis(a);
      expect(p.bpm, isNull);
      expect(p.key, isNull);
      expect(p.headBeatMs, isNull);
    });

    test('теги из текста ffmpeg: темп, тональность, жанр', () {
      const text = ';FFMETADATA1\ntitle=Song\nTBPM=127,5\nTKEY=Am\nGENRE=Deep House\n';
      final r = MixAnalyzer.parseTagText(text);
      expect(r.$1, 127.5);
      expect(r.$2, 'Am');
      expect(r.$3, 'deep house');
      final none = MixAnalyzer.parseTagText('title=x\nartist=y\n');
      expect(none.$1, isNull);
      expect(none.$2, isNull);
      expect(none.$3, '');
    });
  });

  group('переход по долям', () {
    test('старт на доле уходящего, вход на доле следующего', () {
      const out = MixProfile(
          durationMs: 200000, introMs: 0, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 120, headBeatMs: 200, tailBeatMs: 130);
      const inn = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 121, headBeatMs: 420, tailBeatMs: 130);
      final plan = MixPlan.make(out, inn, maxSec: 8);
      expect(_phaseGap(plan.start.inMilliseconds, 130, 500), lessThan(1));
      // Следующий входит на своей доле: 420 + k·(60000/121)
      expect(_phaseGap(plan.inStart.inMilliseconds, 420, 60000 / 121), lessThan(2));
      expect(plan.inStart.inMilliseconds, greaterThanOrEqualTo(700));
      // Конец перехода не сдвинулся: он по-прежнему там, где трек уходит в тишину
      expect((plan.start + plan.length).inMilliseconds, out.endMs);
    });

    test('темпы сильно расходятся — по долям не выравниваем', () {
      const out = MixProfile(
          durationMs: 200000, introMs: 0, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 120, headBeatMs: 200, tailBeatMs: 130);
      const inn = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 150, headBeatMs: 420, tailBeatMs: 130);
      final plain = MixPlan.make(
          MixProfile(durationMs: out.durationMs, introMs: 0, outroMs: out.outroMs, endMs: out.endMs, loudDb: -12, bpm: 120), inn,
          maxSec: 8);
      final plan = MixPlan.make(out, inn, maxSec: 8);
      expect(plan.inStart, plain.inStart);
    });
  });

  group('диджейский переход', () {
    const out = MixProfile(
        durationMs: 240000, introMs: 0, outroMs: 230000, endMs: 236000, loudDb: -12, v: 2, bpm: 120, headBeatMs: 200, tailBeatMs: 130);
    const inn = MixProfile(
        durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 124, headBeatMs: 420, tailBeatMs: 130);

    test('длина — целое число тактов, старт на доле, конец не позже затихания', () {
      final plan = MixPlan.make(out, inn, dj: const DjMix(bars: 8));
      expect(plan.dj, isTrue);
      expect(plan.length.inMilliseconds, 16000); // 8 тактов по 2 с
      expect(_phaseGap(plan.start.inMilliseconds, 130, 500), lessThan(1));
      expect((plan.start + plan.length).inMilliseconds, lessThanOrEqualTo(out.endMs));
      expect((plan.start + plan.length).inMilliseconds, greaterThan(out.endMs - 500));
    });

    test('темп следующего подгоняется, вход на его доле, басы меняются на середине', () {
      final plan = MixPlan.make(out, inn, dj: const DjMix(bars: 8));
      expect(plan.rate, closeTo(120 / 124, 1e-9));
      expect(_phaseGap(plan.inStart.inMilliseconds, 420, 60000 / 124), lessThan(2));
      expect(plan.inStart.inMilliseconds, greaterThanOrEqualTo(700));
      expect(plan.swapAt, const Duration(milliseconds: 8000));
      final noBass = MixPlan.make(out, inn, dj: const DjMix(bars: 8, bass: false));
      expect(noBass.swapAt, isNull);
    });

    test('двойной темп считается совпадением', () {
      const slow = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 61, headBeatMs: 420, tailBeatMs: 130);
      final plan = MixPlan.make(out, slow, dj: const DjMix());
      expect(plan.dj, isTrue);
      expect(plan.rate, closeTo(60 / 61, 1e-9)); // 61 — половина от 120: играем на 60, одна доля следующего на две уходящего
    });

    test('слишком разные темпы или нет сетки долей — обычный переход', () {
      const far = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 150, headBeatMs: 420, tailBeatMs: 130);
      expect(MixPlan.make(out, far, dj: const DjMix()).dj, isFalse);
      const noGrid = MixProfile(durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 2, bpm: 120);
      expect(MixPlan.make(out, noGrid, dj: const DjMix()).dj, isFalse);
    });

    test('длинный переход не залезает в начало короткого трека: укорачивается', () {
      const shortOut = MixProfile(
          durationMs: 40000, introMs: 0, outroMs: 36000, endMs: 38000, loudDb: -12, v: 2, bpm: 120, headBeatMs: 200, tailBeatMs: 130);
      final plan = MixPlan.make(shortOut, inn, dj: const DjMix(bars: 32));
      expect(plan.dj, isTrue);
      expect(plan.start.inMilliseconds, greaterThanOrEqualTo(10000 - 500));
    });

    test('привязка к тактам: старт на первой доле такта уходящего', () {
      const bars = MixProfile(
          durationMs: 240000,
          introMs: 0,
          outroMs: 230000,
          endMs: 236000,
          loudDb: -12,
          v: 3,
          bpm: 120,
          headBeatMs: 200,
          tailBeatMs: 130,
          headBarMs: 1200,
          tailBarMs: 630);
      final plan = MixPlan.make(bars, inn, dj: const DjMix(bars: 8));
      expect(_phaseGap(plan.start.inMilliseconds, 630, 2000), lessThan(1));
      expect((plan.start + plan.length).inMilliseconds, lessThanOrEqualTo(bars.endMs));
      expect(plan.grid, isNotNull);
      expect(plan.preroll, greaterThan(Duration.zero));
    });

    test('вход следующего — на первой доле его такта', () {
      const bars = MixProfile(
          durationMs: 200000,
          introMs: 700,
          outroMs: 190000,
          endMs: 198000,
          loudDb: -12,
          v: 3,
          bpm: 120,
          headBeatMs: 200,
          tailBeatMs: 130,
          headBarMs: 1200,
          tailBarMs: 130);
      final plan = MixPlan.make(out, bars, dj: const DjMix());
      // Такт следующего: 1200 + k·2000; первый после тишины (700 мс) — 1200
      expect(plan.inStart.inMilliseconds, 1200);
      expect(plan.preroll, const Duration(milliseconds: 700));
    });

    test('спорящие тональности укорачивают переход до двух тактов', () {
      const a = MixProfile(
          durationMs: 240000, introMs: 0, outroMs: 230000, endMs: 236000, loudDb: -12, v: 3, bpm: 120, headBeatMs: 200, tailBeatMs: 130, key: '8A');
      const clash = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 3, bpm: 120, headBeatMs: 420, tailBeatMs: 130, key: '3B');
      const friend = MixProfile(
          durationMs: 200000, introMs: 700, outroMs: 190000, endMs: 198000, loudDb: -12, v: 3, bpm: 120, headBeatMs: 420, tailBeatMs: 130, key: '9A');
      expect(MixPlan.make(a, clash, dj: const DjMix(bars: 16)).length.inMilliseconds, 4000);
      expect(MixPlan.make(a, friend, dj: const DjMix(bars: 16)).length.inMilliseconds, 32000);
      expect(MixPlan.make(a, clash, dj: const DjMix(bars: 16, harmonic: false)).length.inMilliseconds, 32000);
    });

    test('громкость: уходящий держится, пока следующий входит', () {
      final a = djGains(0.25);
      expect(a.$2, greaterThan(0.55));
      expect(a.$1, greaterThan(0.9));
      expect(djGains(0).$1, 1.0);
      expect(djGains(0).$2, 0.0);
      expect(djGains(1).$1, closeTo(0, 1e-9));
      expect(djGains(1).$2, closeTo(1, 1e-9));
    });
  });
}
