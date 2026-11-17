import 'dart:math' as math;
import 'dart:typed_data';

// Быстрое преобразование Фурье для разбора звука (Audio Intelligence).
// Обычный алгоритм Кули — Тьюки по основанию 2 на месте: общеизвестная схема, без заимствованного кода.
// Ничего не тянет из Flutter, поэтому работает в изоляте и проверяется обычными тестами.

/// БПФ фиксированной длины [n] (степень двойки). Таблицы считаются один раз, дальше можно звать [transform] много раз.
class Fft {
  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  Fft._(this.n, this._cos, this._sin, this._rev);

  factory Fft(int n) {
    if (n < 2 || (n & (n - 1)) != 0) {
      throw ArgumentError('Длина БПФ должна быть степенью двойки: $n');
    }
    final half = n >> 1;
    final cosT = Float64List(half);
    final sinT = Float64List(half);
    for (var i = 0; i < half; i++) {
      final a = -2.0 * math.pi * i / n;
      cosT[i] = math.cos(a);
      sinT[i] = math.sin(a);
    }
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    final rev = Int32List(n);
    for (var i = 0; i < n; i++) {
      var x = i;
      var r = 0;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      rev[i] = r;
    }
    return Fft._(n, cosT, sinT, rev);
  }

  /// Прямое преобразование на месте: [re] и [im] длиной [n]. Знак экспоненты — минус (обычная «прямая» схема)
  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        var k = 0;
        for (var j = start; j < start + half; j++) {
          final wr = _cos[k];
          final wi = _sin[k];
          final l = j + half;
          final tr = re[l] * wr - im[l] * wi;
          final ti = re[l] * wi + im[l] * wr;
          re[l] = re[j] - tr;
          im[l] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
          k += step;
        }
      }
    }
  }
}

/// Окно Ханна длиной [n] (периодическое — для спектрального анализа)
Float64List hannWindow(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / n);
  }
  return w;
}
