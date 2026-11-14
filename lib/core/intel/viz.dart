import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'features.dart';
import 'fft.dart';
import 'record.dart';
import 'similarity.dart';

// Данные для двух отладочных экранов: карта схожести всей библиотеки и спектрограмма одного трека.
// Спектрограмма в индексе не хранится: она считается по требованию из файла (то же БПФ, что и при разборе).

// ---------- карта схожести ----------

class MapPoint {
  final String id;

  /// Координаты на плоскости, −1…1 (после проекции главных компонент)
  final double x, y;
  final TrackFeatures f;
  const MapPoint(this.id, this.x, this.y, this.f);
}

/// Проецирует нормализованные векторы признаков библиотеки на плоскость двух главных компонент (PCA, степенной метод).
/// Близкие по звучанию треки оказываются рядом. Результат детерминирован
List<MapPoint> projectMap(IntelIndex index) {
  final n = index.count;
  if (n == 0) return const [];
  final dims = IntelIndex.embeddingDims;
  final x = List<Float64List>.generate(n, (i) {
    final v = Float64List(dims);
    index.embeddingInto(i, v);
    return v;
  });
  // Центрирование
  final mean = Float64List(dims);
  for (final r in x) {
    for (var d = 0; d < dims; d++) {
      mean[d] += r[d];
    }
  }
  for (var d = 0; d < dims; d++) {
    mean[d] /= n;
  }
  for (final r in x) {
    for (var d = 0; d < dims; d++) {
      r[d] -= mean[d];
    }
  }
  final c1 = _component(x, dims, null, 0);
  final c2 = _component(x, dims, c1, 1);
  final px = Float64List(n), py = Float64List(n);
  for (var i = 0; i < n; i++) {
    var a = 0.0, b = 0.0;
    for (var d = 0; d < dims; d++) {
      a += x[i][d] * c1[d];
      b += x[i][d] * c2[d];
    }
    px[i] = a;
    py[i] = b;
  }
  final sx = _spread(px), sy = _spread(py);
  return [
    for (var i = 0; i < n; i++)
      MapPoint(index.recordAt(i).trackId, (px[i] / sx).clamp(-1.0, 1.0).toDouble(), (py[i] / sy).clamp(-1.0, 1.0).toDouble(), index.recordAt(i)),
  ];
}

/// Одна главная компонента степенным методом; [other] — уже найденная, от неё компонента очищается (ортогональность)
Float64List _component(List<Float64List> x, int dims, Float64List? other, int salt) {
  final v = Float64List(dims);
  for (var d = 0; d < dims; d++) {
    v[d] = math.sin(d * 1.7 + salt * 2.3 + 0.5);
  }
  _unit(v, other);
  final w = Float64List(dims);
  for (var it = 0; it < 40; it++) {
    w.fillRange(0, dims, 0.0);
    for (final r in x) {
      var dot = 0.0;
      for (var d = 0; d < dims; d++) {
        dot += r[d] * v[d];
      }
      for (var d = 0; d < dims; d++) {
        w[d] += r[d] * dot;
      }
    }
    for (var d = 0; d < dims; d++) {
      v[d] = w[d];
    }
    _unit(v, other);
  }
  return v;
}

void _unit(Float64List v, Float64List? other) {
  if (other != null) {
    var dot = 0.0;
    for (var d = 0; d < v.length; d++) {
      dot += v[d] * other[d];
    }
    for (var d = 0; d < v.length; d++) {
      v[d] -= dot * other[d];
    }
  }
  var s = 0.0;
  for (final a in v) {
    s += a * a;
  }
  s = math.sqrt(s);
  if (s < 1e-12) {
    // Вырожденный случай (все треки одинаковы): любое направление
    v[0] = 1.0;
    return;
  }
  for (var d = 0; d < v.length; d++) {
    v[d] /= s;
  }
}

/// Масштаб по 98-му перцентилю модуля: единичные выбросы не сжимают всё облако
double _spread(Float64List v) {
  final a = [for (final e in v) e.abs()]..sort();
  if (a.isEmpty) return 1.0;
  final s = a[((a.length - 1) * 0.98).floor()];
  return s < 1e-9 ? 1.0 : s;
}

// ---------- спектрограмма ----------

class SpectroData {
  final int frames, bands;
  final double secPerFrame;

  /// frames × bands, 0…255; полоса 0 — самые низкие частоты
  final Uint8List values;
  const SpectroData(this.frames, this.bands, this.secPerFrame, this.values);

  double get durationSec => frames * secPerFrame;
}

/// Спектрограмма на логарифмической частотной шкале 40 Гц … 10 кГц.
/// [pcm16] — моно 16 бит, [intelRate] Гц. Ширина ограничена [maxFrames] (шаг растёт для длинных треков)
SpectroData computeSpectrogram(Uint8List pcm16, {int bands = 96, int maxFrames = 1600}) {
  final s = pcmToFloat(pcm16);
  final n = s.length;
  if (n < intelFft * 2) return SpectroData(0, bands, 0, Uint8List(0));
  final hop = math.max(512, ((n - intelFft) / maxFrames).ceil());
  final frames = (n - intelFft) ~/ hop + 1;
  final fft = Fft(intelFft);
  final win = hannWindow(intelFft);
  final half = intelFft >> 1;
  final binHz = intelRate / intelFft;
  // Границы полос в бинах: логарифмическая шкала
  final edges = List<int>.generate(bands + 1, (b) {
    final hz = 40.0 * math.pow(10000.0 / 40.0, b / bands);
    return (hz / binHz).floor().clamp(1, half).toInt();
  });
  for (var b = 1; b <= bands; b++) {
    if (edges[b] <= edges[b - 1]) edges[b] = math.min(half, edges[b - 1] + 1);
  }
  final re = Float64List(intelFft), im = Float64List(intelFft);
  final db = Float32List(frames * bands);
  for (var f = 0; f < frames; f++) {
    final off = f * hop;
    for (var i = 0; i < intelFft; i++) {
      re[i] = s[off + i] * win[i];
      im[i] = 0.0;
    }
    fft.transform(re, im);
    for (var b = 0; b < bands; b++) {
      final lo = edges[b], hi = math.max(edges[b] + 1, edges[b + 1]);
      var p = 0.0;
      for (var k = lo; k < hi && k <= half; k++) {
        p += re[k] * re[k] + im[k] * im[k];
      }
      p /= (hi - lo);
      db[f * bands + b] = (10.0 * math.log(p + 1e-12) / math.ln10).toDouble();
    }
  }
  // Динамический диапазон 70 дБ ниже почти максимума (99,5-й перцентиль): тихие полосы не пропадают, одиночные пики не гасят картинку
  final sorted = Float32List.fromList(db)..sort();
  final ref = sorted[((sorted.length - 1) * 0.995).floor()];
  const range = 70.0;
  final out = Uint8List(db.length);
  for (var i = 0; i < db.length; i++) {
    out[i] = (((db[i] - (ref - range)) / range).clamp(0.0, 1.0) * 255).round();
  }
  return SpectroData(frames, bands, hop / intelRate, out);
}

Future<SpectroData> computeSpectrogramInIsolate(Uint8List pcm16) => Isolate.run(() => computeSpectrogram(pcm16));

/// Цветовая шкала спектрограммы: 256 цветов ARGB (тёмный → фиолетовый → красный → жёлтый → светлый)
Uint32List spectroPalette() {
  const stops = <List<int>>[
    [0, 0, 4],
    [40, 11, 84],
    [101, 21, 110],
    [159, 42, 99],
    [212, 72, 66],
    [245, 125, 21],
    [250, 193, 39],
    [252, 255, 164],
  ];
  final out = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    final t = i / 255 * (stops.length - 1);
    final k = math.min(stops.length - 2, t.floor());
    final f = t - k;
    int c(int ch) => (stops[k][ch] + (stops[k + 1][ch] - stops[k][ch]) * f).round();
    out[i] = 0xFF000000 | (c(0) << 16) | (c(1) << 8) | c(2);
  }
  return out;
}

/// Пиксели RGBA для [SpectroData]: строка 0 — самые высокие частоты (рисуется сверху)
Uint8List spectroPixels(SpectroData d) {
  final pal = spectroPalette();
  final px = Uint8List(d.frames * d.bands * 4);
  for (var y = 0; y < d.bands; y++) {
    final band = d.bands - 1 - y;
    for (var x = 0; x < d.frames; x++) {
      final c = pal[d.values[x * d.bands + band]];
      final o = (y * d.frames + x) * 4;
      px[o] = (c >> 16) & 0xFF;
      px[o + 1] = (c >> 8) & 0xFF;
      px[o + 2] = c & 0xFF;
      px[o + 3] = 0xFF;
    }
  }
  return px;
}
