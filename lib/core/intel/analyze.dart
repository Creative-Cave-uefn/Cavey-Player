import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../beats.dart' show beatPhase, downbeatOf, findTempo, frameLevels, onsetStrength, refineTempo;
import 'features.dart';
import 'record.dart';

// Сборка записи признаков из звука: тембр, гармония, ритм, энергия, вступление и концовка, данные для DJ.
// Чистая функция без обращений к диску и сети: звук приходит байтами, результат — запись. Поэтому её можно
// запускать в изоляте и проверять тестами на синтетических сигналах.

/// Один кусок звука: тот же участок трека в двух-трёх видах
class AudioChunk {
  /// Моно, [intelRate] Гц, 16 бит (little-endian) — для тембра, тональности и энергии
  final Uint8List pcm22;

  /// Моно (L+R)/2, 4 кГц, 16 бит — для темпа и долей (так же считает beats.dart)
  final Uint8List pcm4;

  /// Боковой канал (L−R)/2, 4 кГц, 16 бит — только для ширины стерео. null — не декодировался
  /// (источник сам моно, старая версия декодера или сбой ffmpeg — не критично, остальной разбор не зависит от этого)
  final Uint8List? pcm4Side;
  const AudioChunk(this.pcm22, this.pcm4, [this.pcm4Side]);
}

/// Что нужно знать, чтобы разобрать трек
class AnalysisInput {
  final String trackId;
  final String revision;

  /// 'full' — один кусок на весь трек; 'fast' — несколько отрывков в порядке следования по треку
  final String mode;
  final double durationSec;
  final List<AudioChunk> chunks;
  final double? lufs;
  final double? lra;

  /// Декодер отдал заметно меньше звука, чем длится трек
  final bool decodeGap;
  final int nowMs;

  const AnalysisInput({
    required this.trackId,
    required this.revision,
    required this.mode,
    required this.durationSec,
    required this.chunks,
    this.lufs,
    this.lra,
    this.decodeGap = false,
    required this.nowMs,
  });
}

/// Разбор в отдельном изоляте: интерфейс не подвисает. Функция верхнего уровня, чтобы замыканию не достался лишний объект
Future<TrackFeatures> analyzeAudioInIsolate(AnalysisInput input) => Isolate.run(() => analyzeAudio(input));

/// Расстояние между двумя темпами в октавах с учётом двойного и половинного темпа: 0 — тот же темп или ×2 / ÷2
double tempoOctaveDistance(double a, double b) {
  if (a <= 0 || b <= 0) return 9.0;
  final r = math.log(a / b) / math.ln2;
  return (r - r.roundToDouble()).abs();
}

// ---------- темп ----------

class _Tempo {
  final double? bpm;
  final double conf;
  final double stability;
  final double onsetDensity;

  /// Только для полного разбора: нужны для сетки долей и фраз
  final Float64List? broadDb;
  final Float64List? lowDb;
  final Float64List? broadO;
  final Float64List? lowO;

  const _Tempo({this.bpm, this.conf = 0, this.stability = 0, this.onsetDensity = 0, this.broadDb, this.lowDb, this.broadO, this.lowO});
}

/// Темп по всему треку (один кусок): грубая оценка, уточнение и согласие по окнам по 30 секунд
_Tempo _tempoFull(Uint8List pcm4) {
  final lv = frameLevels(pcm4);
  final broadO = onsetStrength(lv.$1);
  final lowO = onsetStrength(lv.$2);
  final density = onsetsPerSecond(broadO);
  final t = findTempo(broadO);
  if (t == null || t.$2 < 0.1) {
    return _Tempo(conf: t?.$2 ?? 0, onsetDensity: density, broadDb: lv.$1, lowDb: lv.$2, broadO: broadO, lowO: lowO);
  }
  final bpm = refineTempo(broadO, t.$1);
  // Согласие отрезков трека с общим темпом
  var agree = 0, total = 0;
  const win = 3000, step = 1500;
  for (var a = 0; a + 1500 <= broadO.length; a += step) {
    final b = math.min(broadO.length, a + win);
    if (b - a < 1500) break;
    final w = findTempo(Float64List.sublistView(broadO, a, b));
    total++;
    if (w != null && w.$2 >= 0.05 && tempoOctaveDistance(w.$1, bpm) <= 0.04) agree++;
    if (b >= broadO.length) break;
  }
  final stability = total >= 2 ? agree / total : math.min(1.0, t.$2 * 3);
  return _Tempo(bpm: bpm, conf: t.$2, stability: stability, onsetDensity: density, broadDb: lv.$1, lowDb: lv.$2, broadO: broadO, lowO: lowO);
}

/// Темп по нескольким отрывкам: голосование с учётом уверенности, двойной и половинный темп считаются своими
_Tempo _tempoFast(List<AudioChunk> chunks) {
  final est = <(double, double)>[];
  var peaks = 0.0, seconds = 0.0;
  for (final c in chunks) {
    final lv = frameLevels(c.pcm4);
    final o = onsetStrength(lv.$1);
    final sec = o.length / 100.0;
    peaks += onsetsPerSecond(o) * sec;
    seconds += sec;
    final t = findTempo(o);
    if (t != null && t.$2 >= 0.05) est.add(t);
  }
  final density = seconds > 0 ? peaks / seconds : 0.0;
  if (est.isEmpty) return _Tempo(onsetDensity: density);
  var totalConf = 0.0;
  for (final e in est) {
    totalConf += e.$2;
  }
  var bestIdx = 0;
  var bestSupport = -1.0;
  for (var i = 0; i < est.length; i++) {
    var s = 0.0;
    for (final e in est) {
      if (tempoOctaveDistance(est[i].$1, e.$1) <= 0.04) s += e.$2;
    }
    if (s > bestSupport || (s == bestSupport && est[i].$2 > est[bestIdx].$2)) {
      bestSupport = s;
      bestIdx = i;
    }
  }
  final ref = est[bestIdx].$1;
  var sumW = 0.0, sumB = 0.0, n = 0;
  for (final e in est) {
    if (tempoOctaveDistance(ref, e.$1) > 0.04) continue;
    final aligned = e.$1 * math.pow(2.0, (math.log(ref / e.$1) / math.ln2).roundToDouble());
    sumB += aligned * e.$2;
    sumW += e.$2;
    n++;
  }
  if (sumW <= 0 || n == 0) return _Tempo(onsetDensity: density);
  return _Tempo(bpm: sumB / sumW, conf: sumW / n, stability: totalConf > 0 ? bestSupport / totalConf : 0.0, onsetDensity: density);
}

// ---------- сборка ----------

/// Среднее и разброс столбца [col] у кадров из [idx]
(double, double) _meanStd(Float64List data, int stride, int col, List<int> idx) {
  if (idx.isEmpty) return (0.0, 0.0);
  var s = 0.0;
  for (final i in idx) {
    s += data[i * stride + col];
  }
  final m = s / idx.length;
  var v = 0.0;
  for (final i in idx) {
    final d = data[i * stride + col] - m;
    v += d * d;
  }
  return (m, math.sqrt(v / idx.length));
}

SegmentStats _segment(FrameSet f, int from, int to, double onsetDensity, int silenceMs) {
  final idx = <int>[for (var i = math.max(0, from); i < math.min(f.count, to); i++) if (f.active(i)) i];
  if (idx.isEmpty) {
    return SegmentStats(energyDb: -100, centroidHz: 0, bassRatio: 0, onsetDensity: onsetDensity, mfcc: List<double>.filled(mfccCount, 0.0), silenceMs: silenceMs);
  }
  final mfcc = [for (var c = 0; c < mfccCount; c++) _meanStd(f.mfcc, mfccCount, c, idx).$1];
  return SegmentStats(
    energyDb: _meanStd(f.rmsDb, 1, 0, idx).$1,
    centroidHz: _meanStd(f.centroid, 1, 0, idx).$1,
    bassRatio: _meanStd(f.bass, 1, 0, idx).$1,
    onsetDensity: onsetDensity,
    mfcc: mfcc,
    silenceMs: silenceMs,
  );
}

int _frameMs(int frame) => (frame * intelHop * 1000 / intelRate).round();

double _sumSquares(Uint8List pcm, int sampleCount) {
  final data = ByteData.sublistView(pcm);
  var s = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final v = data.getInt16(i * 2, Endian.little) / 32768.0;
    s += v * v;
  }
  return s;
}

/// Ширина стерео по всем кускам трека: RMS бокового (L−R)/2 к RMS среднего (L+R)/2, в линейных единицах.
/// null — ни у одного куска не декодировался боковой канал (источник сам моно, старый декодер, сбой ffmpeg)
double? _stereoWidthOf(List<AudioChunk> chunks) {
  var sumSide = 0.0, sumMid = 0.0, samples = 0;
  for (final c in chunks) {
    final side = c.pcm4Side;
    if (side == null) continue;
    final n = math.min(side.length, c.pcm4.length) ~/ 2;
    if (n < 1000) continue; // короче 0,25 с — нечего измерять
    sumSide += _sumSquares(side, n);
    sumMid += _sumSquares(c.pcm4, n);
    samples += n;
  }
  if (samples < 4000 || sumMid <= 1e-9) return null; // меньше секунды суммарно, или средний канал — тишина
  return math.sqrt(sumSide / sumMid).clamp(0.0, 3.0).toDouble();
}

/// Собирает запись признаков из звука
TrackFeatures analyzeAudio(AnalysisInput input) {
  final sets = <FrameSet>[for (final c in input.chunks) computeFrames(pcmToFloat(c.pcm22))];
  final all = FrameSet.concat(sets);
  final act = <int>[for (var i = 0; i < all.count; i++) if (all.active(i)) i];
  final flags = <String>[];
  final coverage = all.count * intelHop / intelRate;
  if (input.mode != 'full') flags.add(TrackFeatures.flagPartial);
  if (input.decodeGap) flags.add(TrackFeatures.flagDecodeGap);
  if (input.lufs == null) flags.add(TrackFeatures.flagNoLoudness);

  if (act.length < 40) {
    // Меньше двух секунд звучащего материала: сравнивать нечего, но запись нужна, чтобы не разбирать трек снова и снова
    flags.add(TrackFeatures.flagShort);
    flags.add(TrackFeatures.flagNoRhythm);
    flags.add(TrackFeatures.flagWeakKey);
    return TrackFeatures(
      trackId: input.trackId,
      revision: input.revision,
      mode: input.mode,
      analyzedAt: input.nowMs,
      durationSec: input.durationSec,
      coverageSec: coverage,
      chroma: List<double>.filled(12, 1 / 12),
      mfccMean: List<double>.filled(mfccCount, 0.0),
      mfccStd: List<double>.filled(mfccCount, 0.0),
      centroidMean: 0,
      centroidStd: 0,
      rolloffMean: 0,
      rolloffStd: 0,
      flatnessMean: 0,
      flatnessStd: 0,
      contrast: List<double>.filled(contrastBands, 0.0),
      rmsDb: -100,
      dynamicRangeDb: 0,
      bassRatio: 0,
      midRatio: 0,
      energyStdDb: 0,
      timbreDrift: 0,
      lufs: input.lufs,
      lra: input.lra,
      stereoWidth: _stereoWidthOf(input.chunks),
      flags: flags,
    );
  }
  final activeSec = act.length / intelFps;
  if (activeSec < 20) flags.add(TrackFeatures.flagShort);

  // Тембр
  final mm = <double>[], ms = <double>[];
  for (var c = 0; c < mfccCount; c++) {
    final r = _meanStd(all.mfcc, mfccCount, c, act);
    mm.add(r.$1);
    ms.add(r.$2);
  }
  final cen = _meanStd(all.centroid, 1, 0, act);
  final rol = _meanStd(all.rolloff, 1, 0, act);
  final fla = _meanStd(all.flatness, 1, 0, act);
  final ct = [for (var b = 0; b < contrastBands; b++) _meanStd(all.contrast, contrastBands, b, act).$1];

  // Гармония: хрома с весом по громкости кадра, чтобы тихие хвосты не размывали профиль
  final chroma = List<double>.filled(12, 0.0);
  var wSum = 0.0;
  for (final i in act) {
    final w = math.pow(10.0, all.rmsDb[i] / 20.0).toDouble();
    for (var k = 0; k < 12; k++) {
      chroma[k] += all.chroma[i * 12 + k] * w;
    }
    wSum += w;
  }
  if (wSum > 0) {
    for (var k = 0; k < 12; k++) {
      chroma[k] /= wSum;
    }
  }
  final key = keyFromChroma(chroma);
  final keyName = key?.$1;
  final keyConf = key?.$2 ?? 0.0;
  if (key == null || keyConf < 0.5) flags.add(TrackFeatures.flagWeakKey);

  // Энергия и динамика
  final db = [for (final i in act) all.rmsDb[i]];
  final rmsMean = mean(db);
  final dyn = percentile(db, 95) - percentile(db, 10);
  final bass = _meanStd(all.bass, 1, 0, act).$1;
  final mid = _meanStd(all.mid, 1, 0, act).$1;
  final third = math.max(1, act.length ~/ 3);
  final head = act.sublist(0, third), tail = act.sublist(act.length - third);
  var drift = 0.0;
  for (var c = 0; c < mfccCount; c++) {
    final d = _meanStd(all.mfcc, mfccCount, c, head).$1 - _meanStd(all.mfcc, mfccCount, c, tail).$1;
    drift += d * d;
  }
  drift = math.sqrt(drift / mfccCount);

  // Ритм
  final full = input.mode == 'full' && input.chunks.length == 1;
  final tempo = full ? _tempoFull(input.chunks.first.pcm4) : _tempoFast(input.chunks);
  final bpm = tempo.bpm;
  final tempoOk = bpm != null && tempo.conf >= 0.1;
  if (!tempoOk) flags.add(TrackFeatures.flagNoRhythm);

  // Вступление и концовка
  final first = act.first, last = act.last;
  SegmentStats intro, outro;
  if (full) {
    final env = tempo.broadO ?? Float64List(0);
    final span = (20 * intelFps).round();
    final leadMs = _frameMs(first), tailMs = _frameMs(all.count - 1 - last);
    final iFrom = first, iTo = math.min(all.count, first + span);
    final oTo = last + 1, oFrom = math.max(0, oTo - span);
    intro = _segment(all, iFrom, iTo, onsetsPerSecond(env, from: leadMs ~/ 10, to: _frameMs(iTo) ~/ 10), leadMs);
    outro = _segment(all, oFrom, oTo, onsetsPerSecond(env, from: _frameMs(oFrom) ~/ 10, to: _frameMs(oTo) ~/ 10), tailMs);
  } else {
    // Отрывки: вступление — первый, концовка — последний
    final firstEnv = onsetStrength(frameLevels(input.chunks.first.pcm4).$1);
    final lastEnv = onsetStrength(frameLevels(input.chunks.last.pcm4).$1);
    final n0 = sets.first.count;
    final nL = sets.last.count;
    var lead = 0;
    while (lead < n0 && !all.active(lead)) {
      lead++;
    }
    var trail = 0;
    while (trail < nL && !all.active(all.count - 1 - trail)) {
      trail++;
    }
    intro = _segment(all, 0, n0, onsetsPerSecond(firstEnv), _frameMs(lead));
    outro = _segment(all, all.count - nL, all.count, onsetsPerSecond(lastEnv), _frameMs(trail));
  }

  DjData? dj;
  if (full) {
    dj = _djData(all: all, tempo: tempo, bpm: tempoOk ? bpm : null, durationSec: input.durationSec, leadMs: _frameMs(first), tailMs: _frameMs(all.count - 1 - last), flags: flags);
  }

  return TrackFeatures(
    trackId: input.trackId,
    revision: input.revision,
    mode: input.mode,
    analyzedAt: input.nowMs,
    durationSec: input.durationSec,
    coverageSec: coverage,
    bpm: tempoOk ? bpm : null,
    bpmConf: tempo.conf,
    tempoStability: tempoOk ? tempo.stability : 0,
    onsetDensity: tempo.onsetDensity,
    key: keyName,
    keyConf: keyConf,
    chroma: chroma,
    mfccMean: mm,
    mfccStd: ms,
    centroidMean: cen.$1,
    centroidStd: cen.$2,
    rolloffMean: rol.$1,
    rolloffStd: rol.$2,
    flatnessMean: fla.$1,
    flatnessStd: fla.$2,
    contrast: ct,
    rmsDb: rmsMean,
    dynamicRangeDb: dyn,
    bassRatio: bass,
    midRatio: mid,
    energyStdDb: stdDev(db, rmsMean),
    timbreDrift: drift,
    lufs: input.lufs,
    lra: input.lra,
    stereoWidth: _stereoWidthOf(input.chunks),
    intro: intro,
    outro: outro,
    flags: flags,
    dj: dj,
  );
}

// ---------- данные для DJ ----------

/// Кривые по секундам, сетка долей, границы фраз. Сетка строится от одного темпа на весь трек и проверяется по ходу трека:
/// если атаки уходят от неё больше чем на 35 мс, [DjData.gridStable] = false, и планировщик должен вести себя осторожнее
DjData _djData({
  required FrameSet all,
  required _Tempo tempo,
  required double? bpm,
  required double durationSec,
  required int leadMs,
  required int tailMs,
  required List<String> flags,
}) {
  final secs = math.max(1, durationSec.ceil());
  final energy = Uint8List(secs);
  final vocal = Uint8List(secs);
  final perSecMid = List<double>.filled(secs, 0.0);
  for (var s = 0; s < secs; s++) {
    final a = (s * intelFps).floor();
    final b = math.min(all.count, ((s + 1) * intelFps).floor());
    if (a >= all.count) break;
    var eSum = 0.0, mSum = 0.0;
    var frames = 0, activeFrames = 0;
    for (var i = a; i < math.max(b, a + 1) && i < all.count; i++) {
      eSum += all.rmsDb[i];
      frames++;
      if (all.active(i)) {
        mSum += all.mid[i];
        activeFrames++;
      }
    }
    if (frames > 0) energy[s] = (eSum / frames + 100.0).round().clamp(0, 255).toInt();
    perSecMid[s] = activeFrames > 0 ? mSum / activeFrames : -1.0;
  }
  // Присутствие вокала: доля средних частот (300–3400 Гц) в секунде относительно остального трека. Это эвристика
  final valid = [for (final v in perSecMid) if (v >= 0) v];
  if (valid.length >= 10) {
    final lo = percentile(valid, 10), hi = percentile(valid, 90);
    final span = hi - lo;
    if (span > 1e-6) {
      for (var s = 0; s < secs; s++) {
        if (perSecMid[s] < 0) continue;
        vocal[s] = (((perSecMid[s] - lo) / span).clamp(0.0, 1.0) * 100).round();
      }
    }
  }
  flags.add(TrackFeatures.flagVocalHeuristic);

  final broadDb = tempo.broadDb, lowO = tempo.lowO, broadO = tempo.broadO;
  if (bpm == null || broadDb == null || lowO == null || broadO == null || broadDb.length < 1500) {
    return DjData(energyCurve: energy, vocalCurve: vocal);
  }
  final period = 6000.0 / bpm; // кадров по 10 мс
  final n = broadDb.length;
  final from = math.max(0, leadMs ~/ 10);
  final to = math.max(from + 1, n - tailMs ~/ 10);
  final headTo = math.min(to, from + 3000);
  final h = beatPhase(lowO, period, from, headTo);
  if (h < 0) return DjData(gridBpm: bpm, energyCurve: energy, vocalCurve: vocal);
  final hd = downbeatOf(lowO, broadO, period, h, headTo);
  final headBeatMs = (h * 10).round();
  final headBarMs = hd != null ? ((h + hd * period) * 10).round() : null;
  int? tailBeatMs, tailBarMs;
  final tailFrom = math.max(from, to - 4000);
  final tl = beatPhase(lowO, period, tailFrom, to);
  if (tl >= 0) {
    tailBeatMs = (tl * 10).round();
    final td = downbeatOf(lowO, broadO, period, tl, to);
    if (td != null) tailBarMs = ((tl + td * period) * 10).round();
  }

  // Проверка сетки по ходу трека: окна по 20 секунд
  var maxDrift = 0.0;
  var windows = 0;
  for (var s = from; s + 2000 <= to; s += 2000) {
    final p = beatPhase(lowO, period, s, s + 2000);
    if (p < 0) continue;
    var d = (p - h) % period;
    if (d < 0) d += period;
    if (d > period / 2) d -= period;
    if (d.abs() > maxDrift) maxDrift = d.abs();
    windows++;
  }
  final driftMs = windows >= 3 ? maxDrift * 10 : null;
  final stable = driftMs != null && driftMs <= 35;

  // Границы фраз: длина 4, 8 или 16 тактов и сдвиг, при которых на границах энергия меняется сильнее всего
  final anchor = hd != null ? h + hd * period : h;
  final barLen = 4 * period;
  final bars = ((to - anchor) / barLen).floor();
  var phraseBars = 8;
  var offset = 0;
  var conf = 0.0;
  if (bars >= 12) {
    final prefix = Float64List(n + 1);
    for (var i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + broadDb[i];
    }
    double barEnergy(int b) {
      final a = (anchor + b * barLen).round().clamp(0, n).toInt();
      final z = (anchor + (b + 1) * barLen).round().clamp(0, n).toInt();
      return z > a ? (prefix[z] - prefix[a]) / (z - a) : -90.0;
    }

    final e = [for (var b = 0; b < bars; b++) barEnergy(b)];
    final novelty = List<double>.filled(bars, 0.0);
    var total = 0.0;
    for (var b = 1; b < bars; b++) {
      novelty[b] = (e[b] - e[b - 1]).abs();
      total += novelty[b];
    }
    final base = total / math.max(1, bars - 1);
    if (base > 1e-6) {
      var bestScore = 0.0;
      for (final len in const [4, 8, 16]) {
        for (var off = 0; off < len; off++) {
          var s = 0.0;
          var k = 0;
          for (var b = off; b < bars; b += len) {
            if (b < 1) continue;
            s += novelty[b];
            k++;
          }
          if (k < 3) continue;
          // Слегка предпочитаем привычные 8 тактов и начало на первом такте
          final prior = (len == 8 ? 1.05 : 1.0) * (off == 0 ? 1.05 : 1.0);
          final score = s / k / base * prior;
          if (score > bestScore) {
            bestScore = score;
            phraseBars = len;
            offset = off;
          }
        }
      }
      conf = ((bestScore - 1.15) / 0.85).clamp(0.0, 1.0).toDouble();
    }
  }
  if (conf <= 0) {
    phraseBars = 8;
    offset = 0;
    flags.add(TrackFeatures.flagPhraseGuess);
  }
  final phrases = <int>[];
  for (var b = offset; b < bars && phrases.length < 400; b += phraseBars) {
    phrases.add(((anchor + b * barLen) * 10).round());
  }

  return DjData(
    gridBpm: bpm,
    firstBeatMs: headBeatMs,
    barAnchorMs: headBarMs,
    headBeatMs: headBeatMs,
    tailBeatMs: tailBeatMs,
    headBarMs: headBarMs,
    tailBarMs: tailBarMs,
    driftMs: driftMs,
    gridStable: stable,
    phrasesMs: phrases,
    phraseBars: phraseBars,
    phraseConf: conf,
    energyCurve: energy,
    vocalCurve: vocal,
  );
}
