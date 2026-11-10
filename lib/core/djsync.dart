import 'dart:math' as math;

import 'dj.dart' show Camelot;

// Математика DJ-пульта без звука и Flutter: сетка долей, подгонка темпа и фазы (SYNC), сдвиг тональности под соседний трек,
// длины петель. Всё проверяется обычными тестами.

/// Сетка долей трека: доля с номером k стоит в [anchorMs] + k · [periodMs]
class BeatGrid {
  final double bpm;
  final double anchorMs;

  /// true — якорь стоит на первой доле такта; false — просто на какой-то сильной доле
  final bool barKnown;

  const BeatGrid(this.bpm, this.anchorMs, {this.barKnown = false});

  double get periodMs => 60000.0 / bpm;

  /// Номер доли (дробный) в момент [ms]; целое число — ровно на доле
  double beatAt(double ms) => (ms - anchorMs) / periodMs;

  /// Время доли с номером [beat]
  double timeOf(double beat) => anchorMs + beat * periodMs;

  /// Ближайшая доля к [ms]
  double snap(double ms) => timeOf(beatAt(ms).roundToDouble());

  /// Ближайшая доля не раньше [ms]
  double nextBeat(double ms) => timeOf(beatAt(ms).ceilToDouble());

  /// Ближайшее начало такта (по 4 доли) не раньше [ms]
  double nextBar(double ms) {
    final b = (beatAt(ms) / 4).ceilToDouble() * 4;
    return timeOf(b);
  }

  /// Время, отстоящее от [ms] на [beats] долей
  double shiftBeats(double ms, double beats) => ms + beats * periodMs;

  /// Дробная часть доли в момент [ms], 0…1
  double phaseAt(double ms) {
    final b = beatAt(ms);
    return b - b.floorToDouble();
  }
}

/// Во сколько раз изменить темп [slaveBpm], чтобы он совпал с [masterBpm] (с учётом двойного и половинного темпа).
/// Возвращает пару: коэффициент темпа деки и во сколько раз доли второго трека чаще долей первого (0,5; 1 или 2)
({double ratio, double k}) syncRatio(double masterBpm, double slaveBpm) {
  var best = (ratio: 1.0, k: 1.0);
  var bestD = double.infinity;
  for (final k in const [1.0, 0.5, 2.0]) {
    final r = masterBpm * k / slaveBpm;
    final d = (r - 1).abs();
    if (d < bestD - 1e-9) {
      bestD = d;
      best = (ratio: r, k: k);
    }
  }
  return best;
}

/// Насколько надо сдвинуть позицию второго трека (мс в его времени), чтобы его доли встали на доли первого.
/// [masterMs] и [slaveMs] — текущие позиции; [k] — из [syncRatio]. Результат в пределах половины доли второго трека
double phaseShiftMs(BeatGrid master, double masterMs, BeatGrid slave, double slaveMs, double k) {
  final m = master.beatAt(masterMs);
  final mPhase = m - m.floorToDouble();
  final s = slave.beatAt(slaveMs) / k;
  final sPhase = s - s.floorToDouble();
  var diff = sPhase - mPhase;
  if (diff > 0.5) diff -= 1;
  if (diff < -0.5) diff += 1;
  // Одна доля первого трека — k долей второго
  return -diff * k * slave.periodMs;
}

/// Ошибка фазы в долях (−0,5…0,5): >0 — второй трек опережает
double phaseError(BeatGrid master, double masterMs, BeatGrid slave, double slaveMs, double k) {
  return -phaseShiftMs(master, masterMs, slave, slaveMs, k) / (k * slave.periodMs);
}

/// Тональность после сдвига на [semitones] полутонов: на круге Camelot каждый полутон — это +7 по номеру
Camelot shiftKey(Camelot k, int semitones) {
  final n = (((k.n - 1 + 7 * semitones) % 12) + 12) % 12 + 1;
  return Camelot(n, k.minor);
}

/// На сколько полутонов сдвинуть [incoming], чтобы он зазвучал в ладу с [current] (как в autodj: подгонка тона).
/// Берётся самый маленький сдвиг в пределах [maxShift], после которого совместимость не меньше [need];
/// 0 — сдвиг не нужен или подходящего нет
int keyShiftFor(Camelot? current, Camelot? incoming, {int maxShift = 3, double need = 0.85}) {
  if (current == null || incoming == null) return 0;
  if (Camelot.compat(current, incoming) >= need) return 0;
  var bestShift = 0;
  var best = Camelot.compat(current, incoming);
  for (var a = 1; a <= maxShift; a++) {
    for (final s in [a, -a]) {
      final c = Camelot.compat(current, shiftKey(incoming, s));
      if (c > best + 1e-9) {
        best = c;
        bestShift = s;
      }
    }
    if (best >= need) break;
  }
  return best >= need ? bestShift : 0;
}

/// Длина перехода в мс: [bars] тактов при темпе [bpm]; без темпа — [fallbackSec] секунд. Не короче 4 и не длиннее 45 секунд
int transitionMs(double? bpm, int bars, {int fallbackSec = 8}) {
  final ms = bpm != null && bpm > 0 ? bars * 4 * 60000.0 / bpm : fallbackSec * 1000.0;
  return ms.clamp(4000, 45000).round();
}

/// Петля в [beats] долей от [startMs]: (начало, конец) в мс. Начало прижимается к ближайшей доле
(double, double) loopSpan(BeatGrid? grid, double startMs, double beats, {double fallbackBpm = 120}) {
  if (grid == null) {
    return (startMs, startMs + beats * 60000.0 / fallbackBpm);
  }
  final s = grid.snap(startMs);
  return (s, s + beats * grid.periodMs);
}

/// Громкость в дБ из линейного коэффициента
double toDb(double gain) => gain <= 0 ? -120 : 20 * math.log(gain) / math.ln10;

/// Положение регулятора −1…1 в децибелы для эквалайзера: влево до −26 (убрать), вправо до +6
double eqKnobToDb(double v) {
  final x = v.clamp(-1.0, 1.0);
  return x < 0 ? x * 26 : x * 6;
}
