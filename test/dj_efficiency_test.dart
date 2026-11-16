import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cave_player/core/audio_cache.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/dl/tools.dart';
import 'package:cave_player/core/intel/adaptive_dj.dart';
import 'package:cave_player/core/intel/intel_store.dart';
import 'package:cave_player/core/intel/rhythm.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intel_test.dart' show fakeRecord;
import 'intel_v3_test.dart' show rhythmic;

// Проверки того, что DJ-режим не тратит процессор и диск зря: тяжёлые проверки ритма считаются один раз,
// индекс читается и сжимается порциями, а неразобранный трек не вызывает обращение к диску на каждом отсчёте позиции.

class _NoCache implements AudioCache {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('кэш в этой проверке не нужен');
}

class _NoTools implements Tools {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('ffmpeg в этой проверке не нужен');
}

RhythmWindow _window(List<int> beats, {int start = 0, int end = 24000}) => RhythmWindow(
    startMs: start,
    endMs: end,
    bpm: 120,
    confidence: 0.9,
    support: 1,
    residualMs: 5,
    beatsMs: beats,
    groove: const [1, 0, 0, 0, 0, 0, 0, 0],
    lowGroove: const [1, 0, 0, 0, 0, 0, 0, 0]);

void main() {
  group('окно ритма', () {
    test('попадание в долю: поиск делением пополам совпадает с простым перебором', () {
      final rnd = math.Random(3);
      final beats = <int>[];
      for (var t = 137; t < 24000; t += 380 + rnd.nextInt(240)) {
        beats.add(t);
      }
      final w = _window(beats);
      expect(w.valid, isTrue);
      for (var at = -100; at < 24200; at += 7) {
        expect(w.onBeat(at), beats.any((b) => (b - at).abs() <= 25), reason: 'позиция $at мс');
      }
      expect(_window(const []).onBeat(500), isFalse);
    });

    test('доли не по порядку, вне окна или чужой длины рисунка — окно недействительно', () {
      expect(_window([500, 400]).valid, isFalse);
      expect(_window([500, 500]).valid, isFalse);
      expect(_window([500, 24000]).valid, isFalse);
      expect(_window([-1, 500]).valid, isFalse);
      expect(
          RhythmWindow(startMs: 0, endMs: 24000, bpm: 120, confidence: 0.9, support: 1, residualMs: 5,
              beatsMs: const [500], groove: const [1, 0], lowGroove: const [1, 0, 0, 0, 0, 0, 0, 0]).valid,
          isFalse);
      // Надёжным окно считается только с достаточным числом долей
      expect(_window([for (var t = 0; t < 5000; t += 500) t]).reliable, isFalse);
      expect(_window([for (var t = 0; t < 12000; t += 500) t]).reliable, isTrue);
    });

    test('запись из индекса хранится компактно и читается обратно без изменений', () {
      final w = _window([for (var t = 0; t < 12000; t += 500) t]);
      final json = jsonDecode(jsonEncode(w.toJson()));
      final back = RhythmWindow.fromJson(json)!;
      expect(back.beatsMs, isA<Int32List>());
      expect(back.groove, isA<Float64List>());
      expect(jsonEncode(back.toJson()), jsonEncode(w.toJson()));

      final region = AudioRegion(
          startMs: 0, endMs: 4000, energyDb: -18.4, centroidHz: 1500, bassRatio: 0.31, onsetDensity: 2.25, activeFraction: 1,
          mfcc: [for (var k = 0; k < 12; k++) k * 1.37 - 4], chroma: [for (var k = 0; k < 12; k++) (k + 1) / 78]);
      final regionBack = AudioRegion.fromJson(jsonDecode(jsonEncode(region.toJson())))!;
      expect(regionBack.mfcc, isA<Float64List>());
      expect(regionBack.chroma, isA<Float64List>());
      expect(jsonEncode(regionBack.toJson()), jsonEncode(region.toJson()));
      expect(identical(regionBack.vocalSource, 'unknown'), isTrue);
    });
  });

  test('планирование на три трека вперёд укладывается в отведённое время', () {
    final from = rhythmic('a'), pool = [for (final id in ['b', 'c', 'd', 'e', 'f']) rhythmic(id)];
    AdaptiveDj.choose(from, pool, earliestMs: 100000); // первый проход — прогрев
    final clock = Stopwatch()..start();
    const runs = 5;
    for (var i = 0; i < runs; i++) {
      AdaptiveDj.choose(from, pool, earliestMs: 100000);
    }
    // Планирование идёт в главном потоке: щедрая граница, которая ловит только возврат к пересчёту
    // проверок ритма внутри каждого сравнения (тогда один проход занимал сотни миллисекунд)
    expect(clock.elapsedMilliseconds / runs, lessThan(250));
  });

  group('индекс на диске', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('intel_eff'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    File features() => File('${tmp.path}${Platform.pathSeparator}features.jsonl');

    test('файл с устаревшими строками сжимается при чтении: остаётся последняя строка каждого трека', () async {
      final lines = <String>[];
      for (var round = 0; round < 40; round++) {
        for (var i = 0; i < 12; i++) {
          lines.add(jsonEncode(fakeRecord('t$i', i % 3, i, analyzedAt: 1000 + round).toJson()));
        }
      }
      await features().writeAsString('${lines.join('\n')}\n');
      final s = IntelStore(tmp);
      await s.load();
      expect(s.count, 12);
      expect(s.get('t5')!.analyzedAt, 1039);
      expect(features().readAsLinesSync().where((l) => l.isNotEmpty).length, 12);
      expect(File('${features().path}.tmp').existsSync(), isFalse);

      // Запись после сжатия не теряется
      s.put(fakeRecord('new', 1, 99), local: true);
      await s.flush();
      final again = IntelStore(tmp);
      await again.load();
      expect(again.count, 13);
      expect(again.get('t5')!.analyzedAt, 1039);
      expect(again.pendingRecords(10).map((r) => r.trackId), ['new']);
    });

    test('чтение большого индекса не занимает главный поток одним куском', () async {
      final sink = features().openWrite();
      for (var i = 0; i < 6000; i++) {
        sink.writeln(jsonEncode(fakeRecord('t$i', i % 3, i).toJson()));
      }
      await sink.close();
      // Пока индекс читается, таймер должен успевать срабатывать: раньше весь разбор шёл одним синхронным циклом
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
      final s = IntelStore(tmp);
      await s.load();
      timer.cancel();
      expect(s.count, 6000);
      expect(ticks, greaterThan(3));
    });

    test('сброс во время чтения не сжимает файл по неполному индексу', () async {
      final lines = <String>[];
      for (var round = 0; round < 30; round++) {
        for (var i = 0; i < 200; i++) {
          lines.add(jsonEncode(fakeRecord('t$i', i % 3, i, analyzedAt: 1000 + round).toJson()));
        }
      }
      await features().writeAsString('${lines.join('\n')}\n');
      final s = IntelStore(tmp);
      final loading = s.load();
      // Приложение закрывают, пока индекс ещё читается
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await s.flush();
      await loading;
      expect(s.count, 200);
      final again = IntelStore(tmp);
      await again.load();
      expect(again.count, 200);
      expect(again.get('t199')!.analyzedAt, 1029);
    });

    test('битые байты портят одну строку, а не весь индекс', () async {
      final good = [for (var i = 0; i < 3; i++) utf8.encode('${jsonEncode(fakeRecord('t$i', i, i).toJson())}\n')];
      await features().writeAsBytes([...good[0], 0xC3, 0x28, 0xFF, 0x0A, ...good[1], ...good[2]]);
      final s = IntelStore(tmp);
      await s.load();
      expect(s.count, 3);
    });
  });

  group('профиль звука', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('mix_eff'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('сохранённый профиль читается, а отсутствие профиля запоминается', () {
      const profile = MixProfile(durationMs: 200000, introMs: 500, outroMs: 190000, endMs: 198000, loudDb: -14);
      File('${tmp.path}${Platform.pathSeparator}mix_known.json').writeAsStringSync(jsonEncode(profile.toJson()));
      final m = MixAnalyzer(tmp, _NoCache(), _NoTools());
      expect(m.profile('known')!.endMs, 198000);
      expect(identical(m.profile('known'), m.profile('known')), isTrue);

      expect(m.profile('absent'), isNull);
      // Плеер спрашивает профиль на каждом отсчёте позиции. Файл профиля создаёт только сам анализатор (и сразу
      // кладёт профиль в память), поэтому повторно на диск за отсутствующим профилем не ходим
      tmp.deleteSync(recursive: true);
      expect(m.profile('absent'), isNull);
      expect(m.profileCached('absent'), isNull);
      expect(m.profile('known')!.durationMs, 200000);
    });
  });
}
