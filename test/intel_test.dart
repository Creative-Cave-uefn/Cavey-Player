import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cave_player/core/dj.dart' show Camelot;
import 'package:cave_player/core/intel/analyze.dart';
import 'package:cave_player/core/intel/features.dart';
import 'package:cave_player/core/intel/fft.dart';
import 'package:cave_player/core/intel/intel_store.dart';
import 'package:cave_player/core/intel/record.dart';
import 'package:cave_player/core/intel/service.dart' show IntelService, revisionOf;
import 'package:cave_player/core/intel/similarity.dart';
import 'package:cave_player/core/intel/sync.dart';
import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Моно 16 бит: ровная бочка 60 Гц на каждой доле, первая на [first] секунде, плюс непрерывный аккорд и чуть шума
Uint8List synthPcm(int rate, int seconds, {double bpm = 120, double first = 0.7, List<double> tones = const [261.63, 329.63, 392.0], double toneAmp = 0.1}) {
  final n = rate * seconds;
  final buf = Float64List(n);
  var seed = 4242;
  for (var i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    var v = (seed / 0x7fffffff - 0.5) * 0.01;
    for (final f in tones) {
      v += math.sin(2 * math.pi * f * i / rate) * toneAmp / tones.length;
    }
    buf[i] = v;
  }
  final period = 60.0 / bpm;
  final kickLen = (0.12 * rate).round();
  for (var t = first; t < seconds - 0.2; t += period) {
    final at = (t * rate).round();
    for (var k = 0; k < kickLen && at + k < n; k++) {
      buf[at + k] += math.sin(2 * math.pi * 60 * k / rate) * math.exp(-k / (0.03 * rate)) * 0.8;
    }
  }
  final data = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    data.setInt16(i * 2, (buf[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Запись для проверок похожести: кластер [c] (0…2) задаёт тембр, тональность, темп и громкость, [i] — небольшой разброс внутри кластера
TrackFeatures fakeRecord(String id, int c, int i, {bool noTempo = false, String rev = 'r1', int analyzedAt = 1000, String mode = 'full'}) {
  double j(double scale, int salt) => ((math.sin(i * 12.9898 + salt * 78.233) * 43758.5453) % 1.0) * scale - scale / 2;
  final chroma = List<double>.generate(12, (k) => (k == (c * 4) % 12 ? 0.5 : 0.04) + j(0.01, k).abs());
  final sum = chroma.fold<double>(0, (a, b) => a + b);
  return TrackFeatures(
    trackId: id,
    revision: rev,
    mode: mode,
    analyzedAt: analyzedAt,
    durationSec: 200.0 + i * 7,
    coverageSec: 200.0 + i * 7,
    bpm: noTempo ? null : [90.0, 128.0, 170.0][c] + j(2, 1),
    bpmConf: noTempo ? 0.0 : 0.5,
    tempoStability: 0.9,
    onsetDensity: 1.0 + c * 1.5 + j(0.2, 2),
    key: ['8A', '3B', '12A'][c],
    keyConf: 0.8,
    chroma: [for (final x in chroma) x / sum],
    mfccMean: List<double>.generate(12, (k) => c * 8.0 + k + j(0.6, 10 + k)),
    mfccStd: List<double>.generate(12, (k) => 3.0 + c + j(0.3, 30 + k)),
    centroidMean: 1500.0 + c * 1500 + j(150, 50),
    centroidStd: 400.0 + c * 100 + j(40, 51),
    rolloffMean: 4000.0 + c * 2000 + j(200, 52),
    rolloffStd: 800.0 + j(50, 53),
    flatnessMean: 0.02 + c * 0.03 + j(0.004, 54),
    flatnessStd: 0.01,
    contrast: List<double>.generate(6, (k) => 20.0 - c * 3 + j(0.5, 60 + k)),
    rmsDb: -24.0 + c * 5 + j(1, 70),
    dynamicRangeDb: 18.0 - c * 4 + j(1, 71),
    bassRatio: 0.3 + c * 0.2 + j(0.03, 72),
    midRatio: 0.4 + j(0.03, 73),
    energyStdDb: 4.0 + j(0.5, 74),
    timbreDrift: 2.0 + j(0.3, 75),
    lufs: -20.0 + c * 4 + j(0.5, 76),
    intro: SegmentStats(energyDb: -26.0 + c * 4, centroidHz: 1500, bassRatio: 0.3, onsetDensity: 2, mfcc: List<double>.filled(12, 0), silenceMs: 100),
    outro: SegmentStats(energyDb: -26.0 + c * 4, centroidHz: 1500, bassRatio: 0.3, onsetDensity: 2, mfcc: List<double>.filled(12, 0), silenceMs: 100),
  );
}

List<TrackFeatures> fakeLibrary({int perCluster = 10}) => [
      for (var c = 0; c < 3; c++)
        for (var i = 0; i < perCluster; i++) fakeRecord('c$c-$i', c, i),
    ];

void main() {
  group('БПФ и покадровые признаки', () {
    test('синус даёт пик в своём бине', () {
      const n = 256;
      final fft = Fft(n);
      final re = Float64List(n), im = Float64List(n);
      for (var i = 0; i < n; i++) {
        re[i] = math.cos(2 * math.pi * 10 * i / n);
      }
      fft.transform(re, im);
      expect(re[10], closeTo(n / 2, 1e-6));
      expect(re[11].abs(), lessThan(1e-6));
      expect(im[10].abs(), lessThan(1e-6));
    });

    test('длина БПФ не степень двойки — ошибка', () {
      expect(() => Fft(100), throwsArgumentError);
    });

    test('ля первой октавы: хрома в классе «ля», центроид около 440 Гц, громкость по амплитуде', () {
      final x = Float64List(intelRate * 3);
      for (var i = 0; i < x.length; i++) {
        x[i] = 0.5 * math.sin(2 * math.pi * 440 * i / intelRate);
      }
      final f = computeFrames(x);
      expect(f.count, 1 + (x.length - intelFft) ~/ intelHop);
      final mid = f.count ~/ 2;
      var best = 0;
      for (var k = 1; k < 12; k++) {
        if (f.chroma[mid * 12 + k] > f.chroma[mid * 12 + best]) best = k;
      }
      expect(best, 9);
      expect(f.centroid[mid], closeTo(440, 60));
      expect(f.rmsDb[mid], closeTo(-9.03, 0.5));
    });

    test('тишина не даёт признаков и не считается звучащей', () {
      final f = computeFrames(Float64List(intelRate * 2));
      expect(f.count, greaterThan(0));
      expect(f.active(0), isFalse);
      expect(f.mfcc.every((v) => v == 0), isTrue);
    });

    test('слишком короткий звук — пустой набор', () {
      expect(computeFrames(Float64List(100)).count, 0);
    });
  });

  group('тональность', () {
    List<double> triad(int root, {bool minor = false}) {
      final ch = List<double>.filled(12, 0.05);
      ch[root % 12] += 1.0;
      ch[(root + (minor ? 3 : 4)) % 12] += 0.8;
      ch[(root + 7) % 12] += 0.9;
      final s = ch.fold<double>(0, (a, b) => a + b);
      return [for (final v in ch) v / s];
    }

    test('до мажор — 8B, ля минор — 8A', () {
      expect(keyFromChroma(triad(0))!.$1, '8B');
      expect(keyFromChroma(triad(9, minor: true))!.$1, '8A');
    });

    test('все 24 тональности попадают в круг Camelot по таблице', () {
      const maj = {0: '8B', 7: '9B', 2: '10B', 9: '11B', 4: '12B', 11: '1B', 6: '2B', 1: '3B', 8: '4B', 3: '5B', 10: '6B', 5: '7B'};
      const min = {9: '8A', 4: '9A', 11: '10A', 6: '11A', 1: '12A', 8: '1A', 3: '2A', 10: '3A', 5: '4A', 0: '5A', 7: '6A', 2: '7A'};
      maj.forEach((root, name) => expect(keyFromChroma(triad(root))!.$1, name));
      min.forEach((root, name) => expect(keyFromChroma(triad(root, minor: true))!.$1, name));
    });

    test('пустая хрома — тональности нет', () {
      expect(keyFromChroma(List<double>.filled(12, 0)), isNull);
    });
  });

  group('разбор трека', () {
    test('ровный бит 120 BPM и аккорд до мажор: темп, тональность, сетка, фразы, кривые', () {
      const sec = 45;
      final input = AnalysisInput(
        trackId: 't1',
        revision: 'rev',
        mode: 'full',
        durationSec: sec.toDouble(),
        chunks: [AudioChunk(synthPcm(intelRate, sec), synthPcm(4000, sec))],
        lufs: -14.0,
        lra: 5.0,
        nowMs: 1700000000000,
      );
      final r = analyzeAudio(input);
      expect(r.mode, 'full');
      expect(r.coverageSec, closeTo(sec, 1.5));
      expect(r.hasFlag(TrackFeatures.flagShort), isFalse);
      expect(r.bpm, isNotNull);
      expect(tempoOctaveDistance(r.bpm!, 120), lessThan(0.03));
      final key = Camelot.parse(r.key);
      expect(key, isNotNull);
      expect(Camelot.compat(key!, const Camelot(8, false)), greaterThanOrEqualTo(0.85));
      expect(r.mfccMean.length, 12);
      expect(r.chroma.length, 12);
      expect(r.contrast.length, 6);
      expect(r.lufs, -14.0);
      expect(r.intro, isNotNull);
      expect(r.outro, isNotNull);
      final dj = r.dj;
      expect(dj, isNotNull);
      expect(dj!.energyCurve.length, sec);
      expect(dj.vocalCurve.length, sec);
      expect(dj.gridBpm, isNotNull);
      expect(tempoOctaveDistance(dj.gridBpm!, 120), lessThan(0.03));
      // Первая бочка на 0,7 с: сетка попадает в долю с точностью до долей секунды (период 500 мс)
      var off = (dj.firstBeatMs! - 700) % 500;
      if (off > 250) off -= 500;
      expect(off.abs(), lessThan(90));
      expect(r.hasFlag(TrackFeatures.flagVocalHeuristic), isTrue);
    });

    test('четыре отрывка: режим fast, помечено как частичное, темп найден', () {
      final chunks = [for (var i = 0; i < 4; i++) AudioChunk(synthPcm(intelRate, 16), synthPcm(4000, 16))];
      final r = analyzeAudio(AnalysisInput(trackId: 't2', revision: 'rev', mode: 'fast', durationSec: 200, chunks: chunks, nowMs: 5));
      expect(r.mode, 'fast');
      expect(r.hasFlag(TrackFeatures.flagPartial), isTrue);
      expect(r.hasFlag(TrackFeatures.flagNoLoudness), isTrue);
      expect(r.bpm, isNotNull);
      expect(tempoOctaveDistance(r.bpm!, 120), lessThan(0.04));
      expect(r.dj, isNull);
      expect(r.coverageSec, closeTo(64, 2));
    });

    test('тишина и пустой разбор не падают и помечаются', () {
      final silent = analyzeAudio(AnalysisInput(
        trackId: 't3',
        revision: 'rev',
        mode: 'full',
        durationSec: 30,
        chunks: [AudioChunk(Uint8List(intelRate * 2 * 30), Uint8List(4000 * 2 * 30))],
        nowMs: 1,
      ));
      expect(silent.hasFlag(TrackFeatures.flagShort), isTrue);
      expect(silent.hasFlag(TrackFeatures.flagNoRhythm), isTrue);
      expect(silent.bpm, isNull);
      final empty = analyzeAudio(AnalysisInput(trackId: 't4', revision: 'rev', mode: 'full', durationSec: 0, chunks: const [], decodeGap: true, nowMs: 1));
      expect(empty.hasFlag(TrackFeatures.flagDecodeGap), isTrue);
      expect(TrackFeatures.fromJson(jsonDecode(jsonEncode(empty.toJson()))), isNotNull);
    });
  });

  group('запись и сравнение версий', () {
    test('запись переживает JSON без потери полей', () {
      final dj = DjData(
        gridBpm: 124.5,
        firstBeatMs: 700,
        barAnchorMs: 700,
        driftMs: 12.3,
        gridStable: true,
        phrasesMs: const [700, 16700, 32700],
        phraseBars: 8,
        phraseConf: 0.6,
        energyCurve: Uint8List.fromList([60, 70, 80]),
        vocalCurve: Uint8List.fromList([0, 50, 100]),
      );
      final a = fakeRecord('x', 1, 3);
      final withDj = TrackFeatures(
        trackId: a.trackId,
        revision: a.revision,
        mode: a.mode,
        analyzedAt: a.analyzedAt,
        durationSec: a.durationSec,
        coverageSec: a.coverageSec,
        bpm: a.bpm,
        bpmConf: a.bpmConf,
        tempoStability: a.tempoStability,
        onsetDensity: a.onsetDensity,
        key: a.key,
        keyConf: a.keyConf,
        chroma: a.chroma,
        mfccMean: a.mfccMean,
        mfccStd: a.mfccStd,
        centroidMean: a.centroidMean,
        centroidStd: a.centroidStd,
        rolloffMean: a.rolloffMean,
        rolloffStd: a.rolloffStd,
        flatnessMean: a.flatnessMean,
        flatnessStd: a.flatnessStd,
        contrast: a.contrast,
        rmsDb: a.rmsDb,
        dynamicRangeDb: a.dynamicRangeDb,
        bassRatio: a.bassRatio,
        midRatio: a.midRatio,
        energyStdDb: a.energyStdDb,
        timbreDrift: a.timbreDrift,
        lufs: a.lufs,
        intro: a.intro,
        outro: a.outro,
        flags: const [TrackFeatures.flagPartial],
        dj: dj,
      );
      final back = TrackFeatures.fromJson(jsonDecode(jsonEncode(withDj.toJson())))!;
      expect(back.trackId, 'x');
      expect(back.revision, a.revision);
      expect(back.bpm, closeTo(a.bpm!, 0.01));
      expect(back.key, a.key);
      expect(back.mfccMean.length, 12);
      expect(back.flags, [TrackFeatures.flagPartial]);
      expect(back.intro!.hasBeat, isTrue);
      expect(back.dj!.phrasesMs, [700, 16700, 32700]);
      expect(back.dj!.energyAt(1), -30.0);
      expect(back.dj!.vocalAt(2), 1.0);
      expect(back.dj!.energyAt(5), isNull);
      expect(back.dj!.gridStable, isTrue);
    });

    test('повреждённые записи не читаются', () {
      expect(TrackFeatures.fromJson(null), isNull);
      expect(TrackFeatures.fromJson({'id': 'a'}), isNull);
      expect(TrackFeatures.fromJson({'id': 'a', 'rev': 'r', 'ch': [1, 2]}), isNull);
    });

    test('какая запись лучше: нужная версия файла, затем анализатор, полный разбор, время', () {
      final old = fakeRecord('a', 0, 0, rev: 'old', mode: 'full', analyzedAt: 5000);
      final cur = fakeRecord('a', 0, 0, rev: 'new', mode: 'fast', analyzedAt: 1000);
      expect(TrackFeatures.compare(cur, old, wantRevision: 'new'), greaterThan(0));
      expect(TrackFeatures.compare(old, cur), greaterThan(0)); // без «нужной» версии побеждает полный разбор
      final newer = fakeRecord('a', 0, 0, rev: 'new', mode: 'fast', analyzedAt: 9000);
      expect(TrackFeatures.compare(newer, cur), greaterThan(0));
      expect(TrackFeatures.compare(cur, cur), 0);
    });

    test('isCurrentFor учитывает версию файла', () {
      final r = fakeRecord('a', 0, 0, rev: 'abc');
      expect(r.isCurrentFor('abc'), isTrue);
      expect(r.isCurrentFor('zzz'), isFalse);
    });

    test('версия файла: контрольная сумма или время и размер', () {
      Track tr(String md5) => Track(
          id: 'i', source: 's', title: 't', artist: 'a', album: '', albumArtist: '', no: null, year: '', pic: null, cover: null, modified: '2026-01-01', size: 10, md5: md5, by: '', path: '');
      expect(revisionOf(tr('deadbeef')), 'deadbeef');
      expect(revisionOf(tr('')), '2026-01-01:10');
    });
  });

  group('похожесть', () {
    test('исходник из кластера: в первой выдаче только свой кластер', () {
      final idx = IntelIndex()..rebuild(fakeLibrary());
      for (var c = 0; c < 3; c++) {
        final hits = idx.similar(seeds: ['c$c-0'], limit: 9);
        expect(hits.length, 9);
        expect(hits.every((h) => h.id.startsWith('c$c-')), isTrue, reason: 'кластер $c: ${hits.map((h) => h.id).join(', ')}');
        expect(hits.any((h) => h.id == 'c$c-0'), isFalse);
      }
    });

    test('режимы дают разный взгляд, но все ставят свой кластер выше чужого', () {
      final idx = IntelIndex()..rebuild(fakeLibrary());
      for (final mode in SimilarityMode.values) {
        final own = idx.compare('c1-0', 'c1-5', mode: mode)!;
        final other = idx.compare('c1-0', 'c0-5', mode: mode)!;
        expect(own.score, greaterThan(other.score), reason: '$mode');
        expect(own.confidence, greaterThan(0.5));
        expect(own.groups.keys.toSet(), {groupTimbre, groupHarmony, groupRhythm, groupDynamics});
      }
    });

    test('выдача воспроизводима, исключения и фильтр работают', () {
      final idx = IntelIndex()..rebuild(fakeLibrary());
      final a = idx.similar(seeds: ['c0-0', 'c0-1'], limit: 12);
      final b = idx.similar(seeds: ['c0-0', 'c0-1'], limit: 12);
      expect([for (final h in a) h.id], [for (final h in b) h.id]);
      expect(a.any((h) => h.id == 'c0-0' || h.id == 'c0-1'), isFalse);
      final ex = idx.similar(seeds: ['c0-0'], limit: 9, exclude: {'c0-1', 'c0-2'});
      expect(ex.any((h) => h.id == 'c0-1' || h.id == 'c0-2'), isFalse);
      final al = idx.similar(seeds: ['c0-0'], limit: 30, allow: (id) => id.startsWith('c2-'));
      expect(al.every((h) => h.id.startsWith('c2-')), isTrue);
      expect(idx.similar(seeds: ['нет такого']), isEmpty);
      expect(idx.similar(seeds: ['c0-0'], limit: 0), isEmpty);
    });

    test('«отталкивающие» треки понижают похожих на них', () {
      final idx = IntelIndex()..rebuild(fakeLibrary());
      final plain = idx.similar(seeds: ['c0-0'], limit: 29, minScore: -10);
      final withNeg = idx.similar(taste: {'c0-0': 1.0, 'c1-0': -1.0}, limit: 29, minScore: -10);
      double score(List<SimilarityHit> l, String id) => l.firstWhere((h) => h.id == id).score;
      expect(score(withNeg, 'c1-3'), lessThan(score(plain, 'c1-3')));
    });

    test('без темпа трек не пропадает из выдачи, а уверенность ниже', () {
      final recs = fakeLibrary()..add(fakeRecord('noTempo', 0, 3, noTempo: true));
      final idx = IntelIndex()..rebuild(recs);
      final hits = idx.similar(seeds: ['c0-0'], limit: 40, mode: SimilarityMode.dj);
      final h = hits.firstWhere((x) => x.id == 'noTempo');
      final normal = hits.firstWhere((x) => x.id == 'c0-3');
      expect(h.confidence, lessThan(normal.confidence));
      expect(h.score.isNaN, isFalse);
      expect(idx.similar(seeds: ['c0-0'], limit: 40, minConfidence: 0.995), isEmpty);
    });

    test('явный повтор той же записи в выдачу не попадает', () {
      final recs = fakeLibrary();
      final copy = recs.first;
      recs.add(TrackFeatures.fromJson({...copy.toJson(), 'id': 'dup'})!);
      final idx = IntelIndex()..rebuild(recs);
      expect(idx.similar(seeds: [copy.trackId], limit: 40).any((h) => h.id == 'dup'), isFalse);
      expect(idx.similar(seeds: [copy.trackId], limit: 40, dropDuplicates: false).any((h) => h.id == 'dup'), isTrue);
    });

    test('пустой и совсем маленький индекс не падают', () {
      final empty = IntelIndex()..rebuild(const []);
      expect(empty.similar(seeds: ['a']), isEmpty);
      final one = IntelIndex()..rebuild([fakeRecord('a', 0, 0)]);
      expect(one.similar(seeds: ['a']), isEmpty);
      final two = IntelIndex()..rebuild([fakeRecord('a', 0, 0), fakeRecord('b', 1, 0)]);
      expect(two.similar(seeds: ['a']).single.id, 'b');
    });

    test('не больше N треков одного исполнителя', () {
      final hits = [for (var i = 0; i < 6; i++) SimilarityHit('t$i', 1 - i / 10, 1, const {})];
      final out = IntelIndex.diversify(hits, (id) => int.parse(id.substring(1)) < 4 ? 'A' : 'B', maxPerArtist: 2);
      expect([for (final h in out) h.id], ['t0', 't1', 't4', 't5']);
    });

    test('стык: близкие темп и тональность лучше далёких', () {
      final a = fakeRecord('a', 0, 0);
      final near = TrackFeatures.fromJson({...fakeRecord('near', 0, 1).toJson()})!;
      final far = fakeRecord('far', 2, 0);
      final idx = IntelIndex()..rebuild([a, near, far]);
      final good = idx.transition('a', 'near')!;
      final bad = idx.transition('a', 'far')!;
      expect(good.score, greaterThan(bad.score));
      expect(good.confidence, greaterThan(0.5));
      expect(idx.transition('a', 'нет'), isNull);
    });
  });

  group('общий файл на Диске', () {
    test('шард кодируется и читается обратно', () {
      final shard = IntelShard('abcd1234', [fakeRecord('a', 0, 0), fakeRecord('b', 1, 1)]);
      final back = IntelShard.decode(shard.encode())!;
      expect(back.device, 'abcd1234');
      expect(back.records.map((r) => r.trackId), ['a', 'b']);
    });

    test('оборванный, чужой или повреждённый шард пропускается', () {
      final text = IntelShard('abcd1234', [fakeRecord('a', 0, 0)]).encode();
      expect(IntelShard.decode(text.substring(0, text.length - 20)), isNull);
      expect(IntelShard.decode('не json'), isNull);
      expect(IntelShard.decode(jsonEncode({'v': 99, 'n': 0, 'records': []})), isNull);
      expect(IntelShard.decode(jsonEncode({'v': 1, 'n': 5, 'records': []})), isNull);
      final withBad = jsonEncode({
        'v': 1,
        'n': 2,
        'dev': 'x',
        'records': [fakeRecord('a', 0, 0).toJson(), {'id': 'bad'}]
      });
      expect(IntelShard.decode(withBad)!.records.length, 1);
    });

    test('имя шарда содержит устройство', () {
      expect(IntelShard.deviceOf(IntelShard.nameFor('0a1b2c3d', 1700000000000)), '0a1b2c3d');
      expect(IntelShard.deviceOf('library.json'), isNull);
      expect(IntelShard.deviceOf('ai-XYZ-1.json'), isNull);
    });
  });

  group('локальный индекс на диске', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('intel_test'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('записи и очередь публикации переживают перезапуск', () async {
      final s = IntelStore(tmp);
      await s.load();
      expect(s.deviceId, isNotEmpty);
      s.put(fakeRecord('a', 0, 0), local: true);
      s.put(fakeRecord('b', 1, 0), local: true);
      s.put(fakeRecord('c', 2, 0)); // пришла с Диска: публиковать не нужно
      expect(s.pendingCount, 2);
      s.markPublished([s.get('a')!]);
      await s.flush();

      final s2 = IntelStore(tmp);
      await s2.load();
      expect(s2.count, 3);
      expect(s2.deviceId, s.deviceId);
      expect(s2.pendingRecords(10).map((r) => r.trackId), ['b']);
    });

    test('худшая запись не заменяет лучшую, «нужная версия файла» побеждает', () async {
      final s = IntelStore(tmp);
      await s.load();
      expect(s.put(fakeRecord('a', 0, 0, mode: 'full', rev: 'old')), isTrue);
      expect(s.put(fakeRecord('a', 0, 0, mode: 'fast', rev: 'old', analyzedAt: 9999)), isFalse);
      s.wantRevision = (id) => 'new';
      expect(s.put(fakeRecord('a', 0, 0, mode: 'fast', rev: 'new')), isTrue);
      expect(s.get('a')!.revision, 'new');
      await s.flush();
    });

    test('принудительная замена переживает перезапуск', () async {
      final s = IntelStore(tmp);
      await s.load();
      s.put(fakeRecord('a', 0, 0, mode: 'full', analyzedAt: 100));
      s.put(fakeRecord('a', 0, 0, mode: 'fast', analyzedAt: 200), local: true, force: true);
      await s.flush();
      final s2 = IntelStore(tmp);
      await s2.load();
      expect(s2.get('a')!.mode, 'fast');
    });

    test('оборванная строка и мусор в файле пропускаются', () async {
      final s = IntelStore(tmp);
      await s.load();
      s.put(fakeRecord('a', 0, 0));
      await s.flush();
      final f = File('${tmp.path}${Platform.pathSeparator}features.jsonl');
      await f.writeAsString('{"id":"оборвано', mode: FileMode.append);
      final s2 = IntelStore(tmp);
      await s2.load();
      expect(s2.count, 1);
    });
  });

  group('громкость из ffmpeg', () {
    test('итог ebur128 читается', () {
      final r = IntelService.parseLoudness(const [
        '[Parsed_ebur128_0 @ 000001] Summary:',
        '',
        '  Integrated loudness:',
        '    I:         -14.3 LUFS',
        '    Threshold: -24.3 LUFS',
        '',
        '  Loudness range:',
        '    LRA:         6.2 LU',
      ]);
      expect(r.$1, -14.3);
      expect(r.$2, 6.2);
    });

    test('тишина и отсутствие итога — null', () {
      expect(IntelService.parseLoudness(const ['I:         -70.0 LUFS']).$1, isNull);
      expect(IntelService.parseLoudness(const ['ничего']), (null, null));
    });
  });
}
