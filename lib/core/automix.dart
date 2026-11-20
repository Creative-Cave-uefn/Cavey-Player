import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_cache.dart';
import 'beat_analysis.dart';
import 'dl/tools.dart';
import 'log.dart';

// Умный переход между треками (как «Automix» в Spotify). Готовых библиотек для Flutter нет,
// поэтому делаем сами: ffmpeg один раз переводит трек в тихую «огибающую» громкости,
// по ней находим, где в начале тишина, где в конце трек затихает и насколько он громкий.
// Переход начинается там, где песня на самом деле уходит, а не за N секунд до конца файла;
// следующий трек стартует без пустого вступления, громкость двух треков выравнивается,
// а длина перехода подгоняется под целое число тактов, если известен темп.

/// Что известно о звуке трека
class MixProfile {
  final int durationMs;
  final int introMs; // где кончается тишина в начале
  final int outroMs; // откуда трек начинает затихать к концу
  final int endMs; // где начинается тишина в конце
  final double loudDb; // типичная громкость тела трека

  const MixProfile({required this.durationMs, required this.introMs, required this.outroMs, required this.endMs, required this.loudDb});

  Map<String, dynamic> toJson() => {'d': durationMs, 'i': introMs, 'o': outroMs, 'e': endMs, 'l': loudDb};

  static MixProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      return MixProfile(
        durationMs: (j['d'] as num).toInt(),
        introMs: (j['i'] as num).toInt(),
        outroMs: (j['o'] as num).toInt(),
        endMs: (j['e'] as num).toInt(),
        loudDb: (j['l'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Огибающая: громкость в дБ на каждые [frameMs] миллисекунд
  static MixProfile? fromEnvelope(List<double> db, {int frameMs = 50}) {
    if (db.length < 40) return null;
    final peak = db.reduce(math.max);
    final silence = peak - 32; // тише этого — считаем тишиной
    var first = db.indexWhere((v) => v > silence);
    var last = db.lastIndexWhere((v) => v > silence);
    if (first < 0 || last <= first) return null;
    // Тело трека: середина, без вступления и концовки
    final body = db.sublist(first + (last - first) ~/ 5, last - (last - first) ~/ 5)..sort();
    final level = body.isEmpty ? peak - 10 : body[body.length ~/ 2];
    // Сглаживание в секунду — отдельные паузы между нотами не считаются концом
    final win = (1000 / frameMs).round();
    double avg(int i) {
      final a = math.max(first, i - win ~/ 2), b = math.min(last, i + win ~/ 2);
      var s = 0.0;
      for (var k = a; k <= b; k++) {
        s += db[k];
      }
      return s / (b - a + 1);
    }

    // Затихание: последний момент, когда трек ещё звучит почти в полную силу
    var outro = last;
    while (outro > first && avg(outro) < level - 5) {
      outro--;
    }
    return MixProfile(
      durationMs: db.length * frameMs,
      introMs: first * frameMs,
      outroMs: outro * frameMs,
      endMs: (last + 1) * frameMs,
      loudDb: level,
    );
  }
}

/// Как сделать переход между двумя треками
class MixPlan {
  final Duration start; // когда в уходящем треке начать
  final Duration length; // сколько длится
  final Duration inStart; // с какого места начать следующий
  final double inGain; // громкость следующего в начале перехода (выравнивание), к концу — 1

  const MixPlan(this.start, this.length, this.inStart, this.inGain);

  /// [maxSec] — самый длинный переход (настройка), [bpm] — темп уходящего трека, если известен
  static MixPlan make(MixProfile out, MixProfile inn, {int maxSec = 8, double? bpm}) {
    const minMs = 1500;
    final maxMs = math.max(minMs, maxSec * 1000);
    final tail = out.endMs;
    // Переход занимает затихание, но не короче 1,5 с и не длиннее настройки
    var len = (tail - out.outroMs).clamp(minMs, maxMs).toInt();
    // Под такт: целое число тактов по 4 доли, если темп разумный
    if (bpm != null && bpm >= 60 && bpm <= 200) {
      final bar = 4 * 60000 / bpm;
      final bars = math.max(1, (len / bar).round());
      final fitted = (bars * bar).round();
      if (fitted <= maxMs + bar / 2) len = math.max(minMs, fitted);
    }
    final start = math.max(out.introMs + 10000, tail - len); // никогда не раньше, чем через 10 с после начала
    // Вступление следующего пропускаем, только тишину и не больше 8 с
    final inStart = math.min(inn.introMs, 8000);
    final diff = (out.loudDb - inn.loudDb).clamp(-6.0, 6.0);
    return MixPlan(
      Duration(milliseconds: start),
      Duration(milliseconds: tail - start),
      Duration(milliseconds: inStart),
      math.pow(10, diff / 20).toDouble(),
    );
  }
}

/// Считает профили треков в фоне и хранит их на диске
class MixAnalyzer {
  final Directory dir;
  final AudioCache cache;
  final Tools tools;
  MixAnalyzer(this.dir, this.cache, this.tools);

  /// Профиль трека посчитан (плеер по нему подстраивает громкость)
  void Function(String id)? onProfile;

  /// Анализ для DJ-режима (доли, тональность, фразы): считается в той же очереди, если [beatEnabled]
  BeatAnalysis? beat;
  bool Function() beatEnabled = () => false;

  bool _needsBeat(String id) {
    final b = beat;
    return b != null && !b.failed && beatEnabled() && !b.isFresh(id);
  }

  final Map<String, MixProfile> _mem = {};
  final Set<String> _queue = {};
  bool _running = false;

  /// Разбор «про запас» (DJ-режим): уже скачанные треки, начиная с ближайших в очереди. Идёт, только когда
  /// основная очередь пуста, по одному треку с паузой — чтобы к переходу трек был разобран, а не ждал анализа
  final Set<String> _idle = {};

  /// Уже проверенные для разбора про запас (чтобы не читать их профили на каждом вызове)
  final Set<String> _idleSeen = {};

  /// Поставить в разбор про запас; [ids] — по важности (первые — раньше), проверяется не больше [limit] новых.
  /// Уже стоящие поднимаются вперёд
  void prepareIdle(Iterable<String> ids, {int limit = 40}) {
    final b = beat;
    if (b == null || b.failed || !beatEnabled()) return;
    final front = <String>[];
    var checked = 0;
    for (final id in ids) {
      if (_idle.contains(id)) {
        front.add(id);
        continue;
      }
      if (_idleSeen.contains(id) || !cache.has(id) || _queue.contains(id)) continue;
      if (++checked > limit) break;
      _idleSeen.add(id);
      if (_needsBeat(id) || (!_noTool && profile(id) == null)) front.add(id);
    }
    if (front.isEmpty) return;
    final rest = _idle.where((id) => !front.contains(id)).toList();
    _idle
      ..clear()
      ..addAll(front)
      ..addAll(rest);
    unawaited(_pump());
  }
  bool _noTool = false;

  File _file(String id) => File('${dir.path}${Platform.pathSeparator}mix_$id.json');

  /// Профиль, если уже посчитан
  MixProfile? profile(String id) {
    final m = _mem[id];
    if (m != null) return m;
    final f = _file(id);
    if (!f.existsSync()) return null;
    try {
      final p = MixProfile.fromJson(jsonDecode(f.readAsStringSync()));
      if (p != null) _mem[id] = p;
      return p;
    } catch (_) {
      return null;
    }
  }

  /// Посчитать профиль, когда звук трека будет в кэше
  void prepare(String id) {
    if ((_noTool || profile(id) != null) && !_needsBeat(id)) return;
    _queue.add(id);
    unawaited(_pump());
  }

  /// Когда трек встал в очередь: ждём, пока он докачается, не дольше 2 минут — но не задерживая остальных
  final Map<String, DateTime> _queuedAt = {};

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      for (;;) {
        // Срочные — по порядку, но только те, что уже лежат на компьютере: трек, который ещё качается (например,
        // играет с Диска), не держит очередь — к нему вернёмся, когда докачается
        String? ready;
        final now = DateTime.now();
        for (final id in _queue.toList()) {
          final at = _queuedAt.putIfAbsent(id, () => now);
          if (cache.has(id) && cache.fileFor(id).existsSync()) {
            ready = id;
            break;
          }
          if (now.difference(at) > const Duration(minutes: 2)) {
            _queue.remove(id);
            _queuedAt.remove(id);
          }
        }
        if (ready != null) {
          _queue.remove(ready);
          _queuedAt.remove(ready);
          await _analyze(ready, cache.fileFor(ready));
          continue;
        }
        // срочных готовых нет — про запас по одному, иначе ждём, пока срочные докачаются
        if (_idle.isNotEmpty) {
          final id = _idle.first;
          _idle.remove(id);
          final src = cache.fileFor(id);
          if (!cache.has(id) || !src.existsSync() || !(_needsBeat(id) || profile(id) == null)) continue;
          await _analyze(id, src);
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        if (_queue.isEmpty) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _analyze(String id, File src) async {
    if (profile(id) == null) await _analyzeEnvelope(id, src);
    final b = beat;
    if (b != null && _needsBeat(id)) {
      if (await b.analyze(id, src, tools.ffmpeg.existsSync() ? tools.ffmpeg.path : '')) onProfile?.call(id);
    }
  }

  Future<void> _analyzeEnvelope(String id, File src) async {
    try {
      if (!tools.ffmpeg.existsSync()) {
        await tools.ensure((_) {});
        if (!tools.ffmpeg.existsSync()) {
          _noTool = true;
          return;
        }
      }
      await dir.create(recursive: true);
      final raw = File('${dir.path}${Platform.pathSeparator}mix_work.raw');
      // Моно, 4 кГц, 16 бит — для огибающей громкости этого хватает с запасом
      await Tools.run(tools.ffmpeg.path, ['-y', '-v', 'error', '-i', src.path, '-ac', '1', '-ar', '4000', '-f', 's16le', raw.path]);
      if (!raw.existsSync()) return;
      final bytes = await raw.readAsBytes();
      await raw.delete();
      final p = MixProfile.fromEnvelope(envelope(bytes));
      if (p == null) return;
      _mem[id] = p;
      await _file(id).writeAsString(jsonEncode(p.toJson()));
      onProfile?.call(id);
    } catch (e) {
      AppLog.warn('Умный переход: не посчитался звук', e);
    }
  }

  /// PCM 16 бит моно 4 кГц → громкость в дБ на каждые 50 мс
  static List<double> envelope(Uint8List pcm, {int rate = 4000, int frameMs = 50}) {
    final data = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    final frame = rate * frameMs ~/ 1000;
    final out = <double>[];
    for (var i = 0; i + frame <= n; i += frame) {
      var s = 0.0;
      for (var k = i; k < i + frame; k++) {
        final v = data.getInt16(k * 2, Endian.little) / 32768.0;
        s += v * v;
      }
      final rms = math.sqrt(s / frame);
      out.add(rms <= 1e-6 ? -120 : 20 * math.log(rms) / math.ln10);
    }
    return out;
  }
}
