import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

// Покадровые признаки звука для Audio Intelligence: тембр (MFCC, центроид, спад, плоскостность, контраст),
// гармония (хрома), энергия (RMS, доля баса и средних частот).
//
// Всё считается по общеизвестным формулам цифровой обработки звука (окно Ханна, БПФ, мел-шкала в формуле HTK,
// ДКП-II, ключевые профили Крумхансл — Кесслера). Параметры подобраны под задачу Cavey и проверяются своими тестами.
// Работает в изоляте и ничего не тянет из Flutter.

/// Частота дискретизации анализа, Гц (моно). ffmpeg переводит звук к ней при декодировании
const int intelRate = 22050;

/// Длина кадра БПФ, отсчётов (≈93 мс)
const int intelFft = 2048;

/// Шаг между кадрами, отсчётов (≈46 мс)
const int intelHop = 1024;

/// Сколько коэффициентов MFCC храним (c1…c12; нулевой — это громкость, она считается отдельно)
const int mfccCount = 12;

/// Число полос мел-банка
const int melCount = 40;

/// Число октавных полос контраста
const int contrastBands = 6;

/// Кадры тише этого уровня (дБ относительно полной шкалы) считаются тишиной и не входят в средние
const double silenceDb = -55.0;

/// Кадров в секунде
const double intelFps = intelRate / intelHop;

/// Покадровые признаки одного куска звука
class FrameSet {
  final int count;
  final Float64List rmsDb; // громкость кадра, дБ
  final Float64List centroid; // спектральный центр тяжести, Гц
  final Float64List rolloff; // частота, ниже которой 85 % энергии, Гц
  final Float64List flatness; // плоскостность, 0…1
  final Float64List bass; // доля энергии 20–150 Гц
  final Float64List mid; // доля энергии 300–3400 Гц
  final Float64List mfcc; // count × mfccCount
  final Float64List contrast; // count × contrastBands, дБ (пик к среднему в октавной полосе)
  final Float64List chroma; // count × 12, сумма в кадре = 1 (или 0 у тишины)

  FrameSet._(this.count, this.rmsDb, this.centroid, this.rolloff, this.flatness, this.bass, this.mid, this.mfcc, this.contrast, this.chroma);

  factory FrameSet.empty(int count) => FrameSet._(
        count,
        Float64List(count),
        Float64List(count),
        Float64List(count),
        Float64List(count),
        Float64List(count),
        Float64List(count),
        Float64List(count * mfccCount),
        Float64List(count * contrastBands),
        Float64List(count * 12),
      );

  /// Склеивает несколько кусков (например, четыре отрывка трека) в один ряд кадров
  factory FrameSet.concat(List<FrameSet> parts) {
    var total = 0;
    for (final p in parts) {
      total += p.count;
    }
    final out = FrameSet.empty(total);
    var at = 0;
    for (final p in parts) {
      out.rmsDb.setRange(at, at + p.count, p.rmsDb);
      out.centroid.setRange(at, at + p.count, p.centroid);
      out.rolloff.setRange(at, at + p.count, p.rolloff);
      out.flatness.setRange(at, at + p.count, p.flatness);
      out.bass.setRange(at, at + p.count, p.bass);
      out.mid.setRange(at, at + p.count, p.mid);
      out.mfcc.setRange(at * mfccCount, (at + p.count) * mfccCount, p.mfcc);
      out.contrast.setRange(at * contrastBands, (at + p.count) * contrastBands, p.contrast);
      out.chroma.setRange(at * 12, (at + p.count) * 12, p.chroma);
      at += p.count;
    }
    return out;
  }

  /// Кадр звучит (громче порога тишины)
  bool active(int i) => rmsDb[i] > silenceDb;
}

/// 16-битный моно звук (little-endian) → числа −1…1
Float64List pcmToFloat(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final out = Float64List(n);
  final data = ByteData.sublistView(pcm);
  for (var i = 0; i < n; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

// ---------- таблицы (считаются один раз на изолят) ----------

class _Tables {
  final Fft fft = Fft(intelFft);
  final Float64List window = hannWindow(intelFft);
  final int half = intelFft >> 1;
  final double binHz = intelRate / intelFft;

  late final Int32List melStart;
  late final List<Float64List> melWeights;
  late final Float64List dct;
  late final Int8List chromaIdx;
  late final Int32List contrastEdge;
  late final int bassLo, bassHi, midLo, midHi, flatLo, flatHi;

  _Tables() {
    _buildMel();
    _buildDct();
    _buildChroma();
    _buildBands();
  }

  static double _hzToMel(double f) => 2595.0 * math.log(1.0 + f / 700.0) / math.ln10;
  static double _melToHz(double m) => 700.0 * (math.pow(10.0, m / 2595.0) - 1.0);

  void _buildMel() {
    const fmin = 40.0;
    const fmax = 10000.0;
    final lo = _hzToMel(fmin), hi = _hzToMel(fmax);
    final edges = List<double>.generate(melCount + 2, (i) => _melToHz(lo + (hi - lo) * i / (melCount + 1)));
    melStart = Int32List(melCount);
    melWeights = [];
    for (var m = 0; m < melCount; m++) {
      final left = edges[m], center = edges[m + 1], right = edges[m + 2];
      var first = (left / binHz).ceil();
      var last = (right / binHz).floor();
      if (first < 1) first = 1;
      if (last > half) last = half;
      if (last < first) {
        // Узкий фильтр между бинами: берём ближайший бин целиком
        first = (center / binHz).round().clamp(1, half).toInt();
        last = first;
      }
      final w = Float64List(last - first + 1);
      var sum = 0.0;
      for (var k = first; k <= last; k++) {
        final f = k * binHz;
        double v;
        if (last == first) {
          v = 1.0;
        } else if (f <= center) {
          v = center > left ? (f - left) / (center - left) : 1.0;
        } else {
          v = right > center ? (right - f) / (right - center) : 1.0;
        }
        if (v < 0) v = 0.0;
        w[k - first] = v;
        sum += v;
      }
      if (sum <= 0) {
        w[0] = 1.0;
        sum = 1.0;
      }
      for (var i = 0; i < w.length; i++) {
        w[i] /= sum;
      }
      melStart[m] = first;
      melWeights.add(w);
    }
  }

  void _buildDct() {
    // ДКП-II с ортонормированным масштабом; коэффициент c (1…mfccCount) лежит в строке c−1
    dct = Float64List(mfccCount * melCount);
    final scale = math.sqrt(2.0 / melCount);
    for (var c = 0; c < mfccCount; c++) {
      for (var m = 0; m < melCount; m++) {
        dct[c * melCount + m] = scale * math.cos(math.pi * (c + 1) * (m + 0.5) / melCount);
      }
    }
  }

  void _buildChroma() {
    chromaIdx = Int8List(half + 1);
    for (var k = 0; k <= half; k++) {
      final f = k * binHz;
      if (f < 100.0 || f > 4000.0) {
        chromaIdx[k] = -1;
        continue;
      }
      final midi = 69.0 + 12.0 * math.log(f / 440.0) / math.ln2;
      chromaIdx[k] = (((midi.round() % 12) + 12) % 12).toInt();
    }
  }

  void _buildBands() {
    const edgesHz = [200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0, 10000.0];
    contrastEdge = Int32List(edgesHz.length);
    for (var i = 0; i < edgesHz.length; i++) {
      contrastEdge[i] = (edgesHz[i] / binHz).round().clamp(1, half).toInt();
    }
    bassLo = math.max(1, (20.0 / binHz).round());
    bassHi = (150.0 / binHz).round();
    midLo = (300.0 / binHz).round();
    midHi = (3400.0 / binHz).round();
    flatLo = (100.0 / binHz).round();
    flatHi = (10000.0 / binHz).round();
  }
}

_Tables? _cached;
_Tables get _tables => _cached ??= _Tables();

double _db(double x) => 10.0 * math.log(x) / math.ln10;

/// Покадровые признаки для звука [x] (моно, [intelRate] Гц, −1…1). Короче одного кадра — пустой набор
FrameSet computeFrames(Float64List x) {
  final t = _tables;
  final n = x.length < intelFft ? 0 : 1 + (x.length - intelFft) ~/ intelHop;
  final out = FrameSet.empty(n);
  if (n == 0) return out;
  final half = t.half;
  final re = Float64List(intelFft);
  final im = Float64List(intelFft);
  final pw = Float64List(half + 1);
  final mag = Float64List(half + 1);
  final mel = Float64List(melCount);
  final chroma = Float64List(12);

  for (var f = 0; f < n; f++) {
    final off = f * intelHop;
    var ss = 0.0;
    for (var i = 0; i < intelFft; i++) {
      final v = x[off + i];
      ss += v * v;
      re[i] = v * t.window[i];
      im[i] = 0.0;
    }
    final rms = math.sqrt(ss / intelFft);
    out.rmsDb[f] = rms <= 1e-5 ? -100.0 : 20.0 * math.log(rms) / math.ln10;
    if (out.rmsDb[f] <= silenceDb) continue; // тишина: остальные признаки не нужны

    t.fft.transform(re, im);
    var total = 0.0, magSum = 0.0, weighted = 0.0;
    for (var k = 0; k <= half; k++) {
      final p = re[k] * re[k] + im[k] * im[k];
      pw[k] = p;
      final m = math.sqrt(p);
      mag[k] = m;
      if (k >= 1) {
        total += p;
        magSum += m;
        weighted += m * k * t.binHz;
      }
    }
    if (total <= 1e-12 || magSum <= 1e-12) continue;

    out.centroid[f] = weighted / magSum;

    var acc = 0.0;
    var roll = half;
    final target = total * 0.85;
    for (var k = 1; k <= half; k++) {
      acc += pw[k];
      if (acc >= target) {
        roll = k;
        break;
      }
    }
    out.rolloff[f] = roll * t.binHz;

    var logSum = 0.0, lin = 0.0;
    final flatCount = t.flatHi - t.flatLo + 1;
    for (var k = t.flatLo; k <= t.flatHi; k++) {
      final p = pw[k] + 1e-12;
      logSum += math.log(p);
      lin += p;
    }
    out.flatness[f] = flatCount > 0 && lin > 0 ? (math.exp(logSum / flatCount) / (lin / flatCount)).clamp(0.0, 1.0).toDouble() : 0.0;

    var bassSum = 0.0, midSum = 0.0;
    for (var k = t.bassLo; k <= t.bassHi; k++) {
      bassSum += pw[k];
    }
    for (var k = t.midLo; k <= t.midHi; k++) {
      midSum += pw[k];
    }
    out.bass[f] = (bassSum / total).clamp(0.0, 1.0).toDouble();
    out.mid[f] = (midSum / total).clamp(0.0, 1.0).toDouble();

    for (var m = 0; m < melCount; m++) {
      final w = t.melWeights[m];
      final s = t.melStart[m];
      var e = 0.0;
      for (var i = 0; i < w.length; i++) {
        e += w[i] * pw[s + i];
      }
      mel[m] = _db(e + 1e-10);
    }
    for (var c = 0; c < mfccCount; c++) {
      var s = 0.0;
      final base = c * melCount;
      for (var m = 0; m < melCount; m++) {
        s += t.dct[base + m] * mel[m];
      }
      out.mfcc[f * mfccCount + c] = s;
    }

    for (var b = 0; b < contrastBands; b++) {
      final a = t.contrastEdge[b], z = t.contrastEdge[b + 1];
      var peak = 0.0, sum = 0.0;
      final cnt = z - a + 1;
      for (var k = a; k <= z; k++) {
        final p = pw[k];
        if (p > peak) peak = p;
        sum += p;
      }
      out.contrast[f * contrastBands + b] = _db((peak + 1e-12) / (sum / cnt + 1e-12));
    }

    for (var i = 0; i < 12; i++) {
      chroma[i] = 0.0;
    }
    var cs = 0.0;
    for (var k = 1; k <= half; k++) {
      final ci = t.chromaIdx[k];
      if (ci < 0) continue;
      chroma[ci] += mag[k];
      cs += mag[k];
    }
    if (cs > 0) {
      for (var i = 0; i < 12; i++) {
        out.chroma[f * 12 + i] = chroma[i] / cs;
      }
    }
  }
  return out;
}

// ---------- простая статистика ----------

double mean(List<double> v) {
  if (v.isEmpty) return 0.0;
  var s = 0.0;
  for (final x in v) {
    s += x;
  }
  return s / v.length;
}

double stdDev(List<double> v, [double? m]) {
  if (v.length < 2) return 0.0;
  final mu = m ?? mean(v);
  var s = 0.0;
  for (final x in v) {
    s += (x - mu) * (x - mu);
  }
  return math.sqrt(s / v.length);
}

/// Процентиль [p] (0…100) без изменения исходного списка; пустой — 0
double percentile(List<double> v, double p) {
  if (v.isEmpty) return 0.0;
  final s = List<double>.of(v)..sort();
  final pos = (p / 100.0).clamp(0.0, 1.0) * (s.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  if (lo == hi) return s[lo];
  return s[lo] * (hi - pos) + s[hi] * (pos - lo);
}

// ---------- тональность ----------

// Профили Крумхансл — Кесслера (мажор и минор), опубликованы в научной литературе
const List<double> _majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const List<double> _minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

// Номер на круге Camelot по тонике (0 = до, 1 = до-диез …)
const List<int> _camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1];
const List<int> _camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];

double _corr(List<double> a, List<double> b) {
  final ma = mean(a), mb = mean(b);
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  if (da <= 1e-12 || db <= 1e-12) return 0.0;
  return num / math.sqrt(da * db);
}

/// Тональность по средней хроме: ($1 — запись Camelot («8A»), $2 — корреляция с лучшим профилем, −1…1,
/// $3 — отрыв от второго лучшего). null — хрома пустая
(String, double, double)? keyFromChroma(List<double> chroma) {
  if (chroma.length != 12) return null;
  var total = 0.0;
  for (final c in chroma) {
    total += c;
  }
  if (total <= 1e-9) return null;
  var best = -2.0, second = -2.0;
  var bestName = '';
  for (var tonic = 0; tonic < 12; tonic++) {
    final rot = List<double>.generate(12, (i) => chroma[(tonic + i) % 12]);
    final cm = _corr(rot, _majorProfile);
    final cn = _corr(rot, _minorProfile);
    for (final cand in [(cm, '${_camelotMajor[tonic]}B'), (cn, '${_camelotMinor[tonic]}A')]) {
      if (cand.$1 > best) {
        second = best;
        best = cand.$1;
        bestName = cand.$2;
      } else if (cand.$1 > second) {
        second = cand.$1;
      }
    }
  }
  return (bestName, best, best - second);
}

// ---------- атаки ----------

/// Сколько заметных атак в секунду на отрезке огибающей атак [o] (шаг 10 мс, см. beats.dart), кадры [from, to).
/// Атака — локальный максимум выше порога [threshold] (в тех же дБ, что и огибающая)
double onsetsPerSecond(Float64List o, {int from = 0, int? to, double threshold = 3.0}) {
  final end = math.min(o.length, to ?? o.length);
  final start = math.max(1, from);
  if (end - start < 100) return 0.0;
  var peaks = 0;
  for (var i = start; i < end - 1; i++) {
    if (o[i] > threshold && o[i] > o[i - 1] && o[i] >= o[i + 1]) peaks++;
  }
  return peaks / ((end - start) / 100.0);
}
