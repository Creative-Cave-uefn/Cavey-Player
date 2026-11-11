import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cave_player/core/intel/features.dart';
import 'package:cave_player/core/intel/similarity.dart';
import 'package:cave_player/core/intel/viz.dart';
import 'package:flutter_test/flutter_test.dart';

import 'intel_test.dart' show fakeLibrary;

Uint8List sine(double hz, int seconds) {
  final n = intelRate * seconds;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (math.sin(2 * math.pi * hz * i / intelRate) * 12000).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('карта: кластеры библиотеки разделяются на плоскости', () {
    final idx = IntelIndex()..rebuild(fakeLibrary(perCluster: 12));
    final pts = projectMap(idx);
    expect(pts.length, 36);
    for (final p in pts) {
      expect(p.x.abs(), lessThanOrEqualTo(1.0));
      expect(p.y.abs(), lessThanOrEqualTo(1.0));
    }
    // центры кластеров по id (c0-…, c1-…, c2-…) должны быть заметно дальше друг от друга, чем разброс внутри
    final cx = <double>[0, 0, 0], cy = <double>[0, 0, 0];
    for (final p in pts) {
      final c = int.parse(p.id[1]);
      cx[c] += p.x / 12;
      cy[c] += p.y / 12;
    }
    var within = 0.0;
    for (final p in pts) {
      final c = int.parse(p.id[1]);
      within += math.sqrt(math.pow(p.x - cx[c], 2) + math.pow(p.y - cy[c], 2));
    }
    within /= pts.length;
    for (var a = 0; a < 3; a++) {
      for (var b = a + 1; b < 3; b++) {
        final d = math.sqrt(math.pow(cx[a] - cx[b], 2) + math.pow(cy[a] - cy[b], 2));
        expect(d, greaterThan(within * 2));
      }
    }
  });

  test('карта: детерминирована и не падает на пустом индексе', () {
    final idx = IntelIndex()..rebuild(fakeLibrary(perCluster: 5));
    final a = projectMap(idx), b = projectMap(idx);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].x, b[i].x);
      expect(a[i].y, b[i].y);
    }
    expect(projectMap(IntelIndex()), isEmpty);
  });

  test('спектрограмма: синус 1 кГц даёт яркую полосу на нужной высоте', () {
    final d = computeSpectrogram(sine(1000, 6), bands: 96);
    expect(d.frames, greaterThan(100));
    expect(d.values.length, d.frames * d.bands);
    // средняя яркость по полосам
    final mean = List<double>.filled(d.bands, 0);
    for (var f = 0; f < d.frames; f++) {
      for (var b = 0; b < d.bands; b++) {
        mean[b] += d.values[f * d.bands + b] / d.frames;
      }
    }
    var best = 0;
    for (var b = 1; b < d.bands; b++) {
      if (mean[b] > mean[best]) best = b;
    }
    // 40 Гц … 10 кГц, логарифмическая шкала: 1 кГц лежит на log(25)/log(250) ≈ 0,58 высоты
    expect(best / d.bands, closeTo(0.58, 0.05));
    expect(mean[best], greaterThan(200));
  });

  test('спектрограмма: слишком короткий звук — пустой результат; шаг растёт для длинного', () {
    expect(computeSpectrogram(Uint8List(1000)).frames, 0);
    final long = computeSpectrogram(sine(440, 120), maxFrames: 300);
    expect(long.frames, lessThanOrEqualTo(310));
    expect(long.durationSec, closeTo(120, 3));
  });

  test('палитра: от тёмного к светлому, пиксели соответствуют размеру', () {
    final p = spectroPalette();
    int lum(int c) => ((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) + (c & 0xFF);
    expect(lum(p[0]), lessThan(lum(p[255])));
    final d = SpectroData(3, 4, 0.1, Uint8List.fromList(List<int>.generate(12, (i) => i * 20)));
    expect(spectroPixels(d).length, 3 * 4 * 4);
  });
}
