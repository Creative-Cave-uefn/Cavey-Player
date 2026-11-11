import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

// Разбор звука трека для АвтоDJ: темп (BPM), положение долей, тональность и форма волны.
// Работает с тем же «сырым» звуком, который ffmpeg уже отдаёт автомиксу: моно, 4 кГц, 16 бит.
// Ничего не тянет из Flutter: считается в отдельном изоляте и проверяется обычными тестами.
//
// Идеи те же, что в Mixxx (анализ темпа и тональности при добавлении трека в библиотеку),
// только проще: темп — по автокорреляции огибающей атак, тональность — по хромаграмме и профилям Крумхансл.

/// Частота дискретизации «сырого» звука
const int beatRate = 4000;

/// Один кадр анализа — 10 мс (40 отсчётов)
const int beatFrame = 40;

const double _frameMs = 10.0;

/// Что узнали о звуке трека
class AudioAnalysis {
  /// Темп в ударах в минуту; null — ритма не нашли (эмбиент, речь) или трек слишком короткий.
  /// Может быть вдвое больше или меньше «человеческого»: для подбора это учитывается (см. dj.dart)
  final double? bpm;

  /// Насколько уверенно найден темп, 0…1. Ниже 0,1 — скорее всего, случайность
  final double bpmConfidence;

  /// Где в начале трека (после тишины) стоит сильная доля, мс. Следующие доли — через период
  final int? headBeatMs;

  /// Где стоит сильная доля ближе к концу трека, мс
  final int? tailBeatMs;

  /// Где начинается такт (первая доля) в начале и ближе к концу трека, мс. null — какая из долей первая, определить не удалось
  final int? headBarMs;
  final int? tailBarMs;

  /// Тональность в записи Camelot: «8A» — Am, «8B» — C. null — не определилась
  final String? key;

  /// Насколько тональность похожа на эталон, −1…1. Надёжной считаем от 0,5
  final double keyConfidence;

  /// Форма волны для полосы перемотки: [waveBuckets] значений 0…255
  final List<int> wave;

  const AudioAnalysis({
    this.bpm,
    this.bpmConfidence = 0,
    this.headBeatMs,
    this.tailBeatMs,
    this.headBarMs,
    this.tailBarMs,
    this.key,
    this.keyConfidence = 0,
    this.wave = const [],
  });
}

/// Сколько столбиков в форме волны
const int waveBuckets = 200;

double _db(double rms) => rms <= 3e-5 ? -90.0 : math.max(-90.0, 20 * math.log(rms) / math.ln10);

/// Считает всё сразу. [introMs] — где кончается тишина в начале, [endMs] — где начинается тишина в конце
/// (из профиля автомикса); 0 — не известно, тогда берём весь трек.
/// Тяжёлая работа (секунды на длинном треке): вызывать в изоляте
AudioAnalysis analyzePcm(Uint8List pcm, {int introMs = 0, int endMs = 0}) {
  final frames = pcm.length ~/ 2 ~/ beatFrame;
  if (frames < 200) return const AudioAnalysis(); // короче 2 секунд
  final lv = frameLevels(pcm);
  final wave = waveShape(lv.$1);

  double? bpm;
  var conf = 0.0;
  int? head, tail, headBar, tailBar;
  // Для темпа нужно хотя бы 15 секунд звука
  if (frames >= 1500) {
    final broadO = onsetStrength(lv.$1);
    final t = findTempo(broadO);
    if (t != null) {
      bpm = t.$1;
      conf = t.$2;
      if (conf >= 0.1) {
        // Грубый темп (шаг 0,25) за четыре минуты уводит сетку почти на полсекунды: уточняем до сотых
        bpm = refineTempo(broadO, t.$1);
        final low = onsetStrength(lv.$2);
        final period = 6000.0 / bpm;
        final from = math.max(0, introMs ~/ 10);
        final to = endMs > 0 ? math.min(frames, endMs ~/ 10) : frames;
        final headTo = math.min(to, from + 3000);
        final h = beatPhase(low, period, from, headTo);
        if (h >= 0) {
          head = (h * _frameMs).round();
          final d = downbeatOf(low, broadO, period, h, headTo);
          if (d != null) headBar = ((h + d * period) * _frameMs).round();
        }
        final tailFrom = math.max(from, to - 4000);
        final tl = beatPhase(low, period, tailFrom, to);
        if (tl >= 0) {
          tail = (tl * _frameMs).round();
          final d = downbeatOf(low, broadO, period, tl, to);
          if (d != null) tailBar = ((tl + d * period) * _frameMs).round();
        }
      }
    }
  }

  String? key;
  var keyConf = 0.0;
  final k = findKey(pcm, lv.$1);
  if (k != null) {
    key = k.$1;
    keyConf = k.$2;
  }
  return AudioAnalysis(
      bpm: bpm,
      bpmConfidence: conf,
      headBeatMs: head,
      tailBeatMs: tail,
      headBarMs: headBar,
      tailBarMs: tailBar,
      key: key,
      keyConfidence: keyConf,
      wave: wave);
}

/// То же, но в отдельном изоляте: интерфейс не подвисает, пока считается длинный трек.
/// Функция верхнего уровня, чтобы замыканию не достался лишний объект
Future<AudioAnalysis> analyzeInIsolate(Uint8List pcm, {int introMs = 0, int endMs = 0}) =>
    Isolate.run(() => analyzePcm(pcm, introMs: introMs, endMs: endMs));

/// Громкость в дБ на каждые 10 мс: целиком ($1) и только низкие частоты ($2, там бьёт бочка — по ней определяем долю)
(Float64List, Float64List) frameLevels(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final n = pcm.length ~/ 2;
  final frames = n ~/ beatFrame;
  final broad = Float64List(frames);
  final low = Float64List(frames);
  final a = math.exp(-2 * math.pi * 180.0 / beatRate);
  var y = 0.0;
  for (var f = 0; f < frames; f++) {
    var s = 0.0, sl = 0.0;
    final base = f * beatFrame;
    for (var k = 0; k < beatFrame; k++) {
      final v = data.getInt16((base + k) * 2, Endian.little) / 32768.0;
      y = (1 - a) * v + a * y;
      s += v * v;
      sl += y * y;
    }
    broad[f] = _db(math.sqrt(s / beatFrame));
    low[f] = _db(math.sqrt(sl / beatFrame));
  }
  return (broad, low);
}

/// Сила атак: насколько кадр громче двух предыдущих. Ровный фон вычитается
Float64List onsetStrength(Float64List db) {
  final n = db.length;
  final o = Float64List(n);
  var sum = 0.0;
  for (var i = 2; i < n; i++) {
    final d = db[i] - math.max(db[i - 1], db[i - 2]);
    if (d > 0) {
      o[i] = d;
      sum += d;
    }
  }
  final m = sum / math.max(1, n);
  for (var i = 0; i < n; i++) {
    final v = o[i] - m * 0.5;
    o[i] = v > 0 ? v : 0.0;
  }
  return o;
}

/// Темп по автокорреляции атак: ($1 — BPM с шагом 0,25, $2 — уверенность). null — ритма нет.
/// Совпадение через две и четыре доли тоже поддерживает ответ; привычные темпы (около 115) чуть предпочтительнее,
/// поэтому 174 может прийти как 87, а 75 как 150 — для подбора пары это равнозначно
(double, double)? findTempo(Float64List o) {
  final n = o.length;
  if (n < 1500) return null;
  var mean = 0.0;
  for (var i = 0; i < n; i++) {
    mean += o[i];
  }
  mean /= n;
  final z = Float64List(n);
  var variance = 0.0;
  for (var i = 0; i < n; i++) {
    z[i] = o[i] - mean;
    variance += z[i] * z[i];
  }
  variance /= n;
  if (variance <= 1e-9) return null;

  const lo = 20, hi = 420;
  final r = Float64List(hi + 2);
  for (var l = lo; l <= hi; l++) {
    var s = 0.0;
    final end = n - l;
    for (var i = 0; i < end; i++) {
      s += z[i] * z[i + l];
    }
    r[l] = s / end;
  }

  double at(double x) {
    final a = x.floor();
    if (a < lo) return 0.0;
    if (a >= hi) return r[hi];
    final f = x - a;
    return r[a] * (1 - f) + r[a + 1] * f;
  }

  var bestBpm = 0.0, bestScore = -1e30, bestRaw = 0.0;
  for (var b = 60.0; b <= 200.0; b += 0.25) {
    final l = 6000.0 / b;
    final raw = at(l) + 0.5 * at(2 * l) + 0.25 * at(4 * l);
    final oct = math.log(b / 115.0) / math.ln2 / 0.9;
    final score = raw * math.exp(-0.5 * oct * oct);
    if (score > bestScore) {
      bestScore = score;
      bestBpm = b;
      bestRaw = at(6000.0 / b);
    }
  }
  if (bestBpm <= 0 || bestRaw <= 0) return null;
  final conf = (bestRaw / variance).clamp(0.0, 1.0).toDouble();
  return (bestBpm, conf);
}

/// Уточняет темп около [bpm] (±0,6 с шагом 0,01): берётся тот, при котором доли по всему треку точнее всего попадают в атаки.
/// Нужно, потому что сетка долей строится от одной точки и ошибка темпа копится: 0,1 BPM за четыре минуты — это 0,2 % длины, около полусекунды
double refineTempo(Float64List o, double bpm) {
  final n = o.length;
  if (n < 1500) return bpm;
  var best = bpm, bestScore = -1.0;
  // Перебор от центра к краям: при равенстве остаётся ближайший к найденному грубо
  for (var i = 0; i <= 120; i++) {
    final step = i.isOdd ? (i + 1) ~/ 2 : -(i ~/ 2);
    final b = bpm + step * 0.01;
    if (b < 40) continue;
    final period = 6000.0 / b;
    var top = 0.0;
    for (var ph = 0.0; ph < period; ph += 2.0) {
      var sum = 0.0;
      var k = 0;
      for (var t = ph; t < n; t += period) {
        final idx = t.round();
        sum += o[idx < n ? idx : n - 1];
        k++;
      }
      final v = k > 0 ? sum / k : 0.0;
      if (v > top) top = v;
    }
    if (top > bestScore) {
      bestScore = top;
      best = b;
    }
  }
  return best;
}

/// Какая из четырёх долей считается первой в такте: номер 0…3 от доли [phase] (кадр) или null, если нет явного победителя.
/// Первая доля обычно самая сильная: бочка с басом, акцент. Смотрим низкие частоты ([low]) и весь звук ([broad]) на долях до кадра [to]
int? downbeatOf(Float64List low, Float64List broad, double period, double phase, int to) {
  if (period < 5) return null;
  final sums = List<double>.filled(4, 0);
  var beats = 0;
  double near(Float64List o, int i) {
    var m = 0.0;
    for (var j = i - 1; j <= i + 1; j++) {
      if (j >= 0 && j < o.length && o[j] > m) m = o[j];
    }
    return m;
  }

  var k = 0;
  for (var t = phase; t < to && t < low.length; t += period, k++) {
    final i = t.round();
    sums[k % 4] += near(low, i) + 0.5 * near(broad, i);
    beats++;
  }
  if (beats < 16) return null; // меньше четырёх тактов: судить рано
  var bi = 0;
  for (var i = 1; i < 4; i++) {
    if (sums[i] > sums[bi]) bi = i;
  }
  var others = 0.0;
  for (var i = 0; i < 4; i++) {
    if (i != bi) others += sums[i];
  }
  final ratio = sums[bi] / math.max(1e-9, others / 3);
  return ratio >= 1.08 ? bi : null;
}

/// Где стоит доля: кадр в окне [start, end), с которого с шагом [period] кадров набирается больше всего атак.
/// −1 — окно слишком короткое
double beatPhase(Float64List o, double period, int start, int end) {
  final s = math.max(0, start);
  final e = math.min(o.length, end);
  if (period < 5 || e - s < period * 4) return -1;
  var best = 0.0, bestScore = -1.0;
  for (var ph = 0.0; ph < period; ph += 1.0) {
    var sum = 0.0;
    var k = 0;
    for (var t = s + ph; t < e; t += period) {
      final i = t.round();
      if (i < o.length) sum += o[i];
      k++;
    }
    if (k > 0 && sum / k > bestScore) {
      bestScore = sum / k;
      best = ph;
    }
  }
  return s + best;
}

/// Ближайшая к [targetMs] доля сетки: [firstBeatMs] + k·период. Время всегда внутри [0, durationMs]
int snapToBeat(int targetMs, int firstBeatMs, double bpm, {int durationMs = 1 << 30}) {
  if (bpm <= 0) return targetMs;
  final period = 60000.0 / bpm;
  final k = ((targetMs - firstBeatMs) / period).round();
  final t = (firstBeatMs + k * period).round();
  return t.clamp(0, durationMs).toInt();
}

/// Форма волны: [waveBuckets] значений 0…255 по средней амплитуде кусочка трека
List<int> waveShape(Float64List db) {
  final n = db.length;
  if (n < waveBuckets) return const [];
  final amp = List<double>.filled(waveBuckets, 0);
  var peak = 0.0;
  for (var b = 0; b < waveBuckets; b++) {
    final from = b * n ~/ waveBuckets;
    final to = math.max(from + 1, (b + 1) * n ~/ waveBuckets);
    var s = 0.0;
    for (var i = from; i < to && i < n; i++) {
      s += math.pow(10.0, db[i] / 20.0);
    }
    amp[b] = s / (to - from);
    if (amp[b] > peak) peak = amp[b];
  }
  if (peak <= 0) return const [];
  return [for (final v in amp) (math.sqrt(v / peak) * 255).round().clamp(0, 255).toInt()];
}

// ---------- тональность ----------

// Профили Крумхансл — Кесслера: насколько каждая из 12 нот от тоники «своя» в мажоре и миноре
const List<double> _major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const List<double> _minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

// Номер на круге Camelot по тонике C, C#, D … B
const List<int> _camMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1];
const List<int> _camMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];

/// Запись Camelot для тоники [tonic] (0 — C … 11 — B)
String camelotOf(int tonic, bool minor) => '${(minor ? _camMinor : _camMajor)[tonic % 12]}${minor ? 'A' : 'B'}';

/// Обратное к [camelotOf]: тоника (0 — C … 11 — B) по номеру на круге Camelot. null — такого номера нет (1…12)
int? tonicOf(int n, bool minor) {
  final t = minor ? _camMinor : _camMajor;
  for (var i = 0; i < 12; i++) {
    if (t[i] == n) return i;
  }
  return null;
}

double _corr(List<double> a, List<double> b) {
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < 12; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= 12;
  mb /= 12;
  var dot = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < 12; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    dot += x * y;
    da += x * x;
    db += y * y;
  }
  return da > 0 && db > 0 ? dot / math.sqrt(da * db) : 0.0;
}

/// Тональность по 12 нотам хромаграммы: ($1 — Camelot, $2 — похожесть на эталон). null — звука нет
(String, double)? keyFromChroma(List<double> chroma) {
  if (chroma.length != 12) return null;
  var total = 0.0;
  for (final v in chroma) {
    total += v;
  }
  if (total <= 0) return null;
  var best = -2.0, bestTonic = 0;
  var bestMinor = false;
  for (var tonic = 0; tonic < 12; tonic++) {
    final rot = [for (var i = 0; i < 12; i++) chroma[(tonic + i) % 12]];
    for (final minor in const [false, true]) {
      final c = _corr(rot, minor ? _minor : _major);
      if (c > best) {
        best = c;
        bestTonic = tonic;
        bestMinor = minor;
      }
    }
  }
  return (camelotOf(bestTonic, bestMinor), best);
}

/// Хромаграмма трека: энергия по 12 нотам (C = 0), собранная из окон БПФ примерно раз в секунду
List<double> chromagram(Uint8List pcm, Float64List levelDb) {
  const size = 4096; // 1 с звука, шаг по частоте около 1 Гц
  final samples = pcm.length ~/ 2;
  final chroma = List<double>.filled(12, 0);
  if (samples < size * 2) return chroma;
  final data = ByteData.sublistView(pcm);

  // Каким нотам соответствует каждая частотная полоса (65…1800 Гц: ниже — шум, выше — обертоны)
  final pitch = List<int>.filled(size ~/ 2, -1);
  for (var k = 1; k < size ~/ 2; k++) {
    final f = k * beatRate / size;
    if (f >= 65 && f <= 1800) pitch[k] = ((12 * math.log(f / 440.0) / math.ln2).round() + 9) % 12;
  }
  final window = Float64List(size);
  for (var i = 0; i < size; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
  }
  final cosT = Float64List(size ~/ 2);
  final sinT = Float64List(size ~/ 2);
  for (var k = 0; k < size ~/ 2; k++) {
    cosT[k] = math.cos(-2 * math.pi * k / size);
    sinT[k] = math.sin(-2 * math.pi * k / size);
  }

  // Не больше ~150 окон на трек: длинные треки просматриваем реже
  final span = samples - size;
  final hop = math.max(beatRate, span ~/ 150);
  final re = Float64List(size);
  final im = Float64List(size);
  final frame = List<double>.filled(12, 0);
  for (var start = 0; start < span; start += hop) {
    final mid = (start + size ~/ 2) ~/ beatFrame;
    if (mid < levelDb.length && levelDb[mid] < -50) continue; // тишина
    for (var i = 0; i < size; i++) {
      re[i] = data.getInt16((start + i) * 2, Endian.little) / 32768.0 * window[i];
      im[i] = 0.0;
    }
    _fft(re, im, cosT, sinT);
    for (var i = 0; i < 12; i++) {
      frame[i] = 0.0;
    }
    for (var k = 1; k < size ~/ 2; k++) {
      final p = pitch[k];
      if (p >= 0) frame[p] += math.sqrt(re[k] * re[k] + im[k] * im[k]);
    }
    var m = 0.0;
    for (final v in frame) {
      if (v > m) m = v;
    }
    if (m <= 1e-9) continue;
    for (var i = 0; i < 12; i++) {
      chroma[i] += frame[i] / m;
    }
  }
  return chroma;
}

/// Тональность целого трека: ($1 — Camelot, $2 — похожесть на эталон)
(String, double)? findKey(Uint8List pcm, Float64List levelDb) => keyFromChroma(chromagram(pcm, levelDb));

/// БПФ на месте, длина — степень двойки; [cosT]/[sinT] — таблицы поворотов для этой длины
void _fft(Float64List re, Float64List im, Float64List cosT, Float64List sinT) {
  final n = re.length;
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
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
    for (var i = 0; i < n; i += size) {
      for (var k = 0; k < half; k++) {
        final wr = cosT[k * step], wi = sinT[k * step];
        final a = i + k, b = i + k + half;
        final vr = re[b] * wr - im[b] * wi;
        final vi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - vr;
        im[b] = im[a] - vi;
        re[a] += vr;
        im[a] += vi;
      }
    }
  }
}
