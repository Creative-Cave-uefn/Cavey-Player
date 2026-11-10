import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'audio_cache.dart';
import 'beats.dart';
import 'dj.dart';
import 'dl/tools.dart';
import 'log.dart';

// Умный переход между треками (как «Automix» в Spotify). Готовых библиотек для Flutter нет,
// поэтому делаем сами: ffmpeg один раз переводит трек в тихую «огибающую» громкости,
// по ней находим, где в начале тишина, где в конце трек затихает и насколько он громкий.
// Переход начинается там, где песня на самом деле уходит, а не за N секунд до конца файла;
// следующий трек стартует без пустого вступления, громкость двух треков выравнивается,
// а длина перехода подгоняется под целое число тактов, если известен темп.
//
// Тот же разбор звука кормит АвтоDJ (как в Mixxx): темп, положение долей, тональность по кругу Camelot
// и форма волны для полосы перемотки. Темп, тональность и жанр, вписанные в теги файла, главнее собственного разбора.

/// Что известно о звуке трека
class MixProfile {
  /// Версия разбора. У профилей старше этой нет темпа, тональности и волны: их досчитаем, когда трек снова будет в кэше
  static const version = 2;

  final int durationMs;
  final int introMs; // где кончается тишина в начале
  final int outroMs; // откуда трек начинает затихать к концу
  final int endMs; // где начинается тишина в конце
  final double loudDb; // типичная громкость тела трека

  /// Версия разбора, которым получен профиль
  final int v;

  /// Темп (удары в минуту); null — не известен
  final double? bpm;

  /// Где стоит сильная доля после вступления и ближе к концу, мс. Только если сетку долей можно считать верной
  final int? headBeatMs;
  final int? tailBeatMs;

  /// Тональность в записи Camelot («8A»); null — не известна
  final String? key;

  /// Форма волны трека: [waveBuckets] значений 0…255; пусто — не посчитана
  final List<int> wave;

  /// Жанр из тегов файла (нижний регистр)
  final String genre;

  const MixProfile({
    required this.durationMs,
    required this.introMs,
    required this.outroMs,
    required this.endMs,
    required this.loudDb,
    this.v = 1,
    this.bpm,
    this.headBeatMs,
    this.tailBeatMs,
    this.key,
    this.wave = const [],
    this.genre = '',
  });

  /// Профиль с темпом, тональностью, волной и жанром. [tagBpm], [tagKey] — что вписано в теги файла:
  /// им верим больше. Сетка долей остаётся, только если темп из тегов с найденным не спорит
  MixProfile withAnalysis(AudioAnalysis? a, {double? tagBpm, String? tagKey, String genre = ''}) {
    final detected = (a != null && a.bpm != null && a.bpmConfidence >= 0.1) ? a.bpm : null;
    final tag = (tagBpm != null && tagBpm >= 40 && tagBpm <= 250) ? tagBpm : null;
    double? bpmNow;
    int? head = a?.headBeatMs, tail = a?.tailBeatMs;
    if (tag != null) {
      bpmNow = tag;
      if (detected == null || bpmStretch(tag, detected) > 0.03) {
        head = null;
        tail = null;
      }
    } else if (detected != null) {
      bpmNow = detected;
    } else {
      head = null;
      tail = null;
    }
    String? keyNow;
    final tk = Camelot.parse(tagKey);
    if (tk != null) {
      keyNow = tk.toString();
    } else if (a != null && a.key != null && a.keyConfidence >= 0.5) {
      keyNow = a.key;
    }
    return MixProfile(
      durationMs: durationMs,
      introMs: introMs,
      outroMs: outroMs,
      endMs: endMs,
      loudDb: loudDb,
      v: version,
      bpm: bpmNow,
      headBeatMs: head,
      tailBeatMs: tail,
      key: keyNow,
      wave: (a != null && a.wave.isNotEmpty) ? a.wave : wave,
      genre: genre.isNotEmpty ? genre : this.genre,
    );
  }

  Map<String, dynamic> toJson() => {
        'd': durationMs,
        'i': introMs,
        'o': outroMs,
        'e': endMs,
        'l': loudDb,
        if (v > 1) 'v': v,
        if (bpm != null) 'bpm': bpm,
        if (headBeatMs != null) 'hb': headBeatMs,
        if (tailBeatMs != null) 'tb': tailBeatMs,
        if (key != null) 'k': key,
        if (wave.isNotEmpty) 'w': base64Encode(Uint8List.fromList(wave)),
        if (genre.isNotEmpty) 'g': genre,
      };

  static MixProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      var wave = const <int>[];
      final w = j['w'];
      if (w is String && w.isNotEmpty) wave = base64Decode(w).toList();
      return MixProfile(
        durationMs: (j['d'] as num).toInt(),
        introMs: (j['i'] as num).toInt(),
        outroMs: (j['o'] as num).toInt(),
        endMs: (j['e'] as num).toInt(),
        loudDb: (j['l'] as num).toDouble(),
        v: (j['v'] as num?)?.toInt() ?? 1,
        bpm: (j['bpm'] as num?)?.toDouble(),
        headBeatMs: (j['hb'] as num?)?.toInt(),
        tailBeatMs: (j['tb'] as num?)?.toInt(),
        key: j['k'] as String?,
        wave: wave,
        genre: (j['g'] as String?) ?? '',
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
  /// (свой разбор звука важнее, он в профиле). Если у обоих треков известна сетка долей и темпы близки,
  /// переход начинается на доле уходящего трека, а следующий входит на своей доле
  static MixPlan make(MixProfile out, MixProfile inn, {int maxSec = 8, double? bpm}) {
    const minMs = 1500;
    final maxMs = math.max(minMs, maxSec * 1000);
    final tail = out.endMs;
    final tempo = out.bpm ?? bpm;
    // Переход занимает затихание, но не короче 1,5 с и не длиннее настройки
    var len = (tail - out.outroMs).clamp(minMs, maxMs).toInt();
    // Под такт: целое число тактов по 4 доли, если темп разумный
    if (tempo != null && tempo >= 60 && tempo <= 200) {
      final bar = 4 * 60000 / tempo;
      final bars = math.max(1, (len / bar).round());
      final fitted = (bars * bar).round();
      if (fitted <= maxMs + bar / 2) len = math.max(minMs, fitted);
    }
    var start = math.max(out.introMs + 10000, tail - len); // никогда не раньше, чем через 10 с после начала
    // Вступление следующего пропускаем, только тишину и не больше 8 с
    var inStart = math.min(inn.introMs, 8000);
    // По долям: сетка нужна у обоих, и темпы не должны сильно расходиться, иначе доли «поплывут» во время перехода
    final ob = out.bpm, ib = inn.bpm, oh = out.tailBeatMs, ih = inn.headBeatMs;
    if (ob != null && ib != null && oh != null && ih != null && bpmStretch(ob, ib) <= 0.03) {
      final snapped = snapToBeat(start, oh, ob, durationMs: tail - minMs);
      if (snapped >= out.introMs + 10000 - 100) start = snapped;
      var enter = snapToBeat(inStart, ih, ib, durationMs: 8000 + (60000 / ib).round());
      // Не раньше, чем кончится тишина: тогда берём следующую долю
      if (enter < inn.introMs) enter += (60000 / ib).round();
      if (enter >= 0 && enter <= 12000) inStart = enter;
    }
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

  final Map<String, MixProfile> _mem = {};
  final Set<String> _queue = {};
  final Set<String> _tried = {}; // уже разбирали в этом запуске: упавший разбор не повторяем на каждом прослушивании
  bool _running = false;
  bool _noTool = false;

  /// Сколько треков ещё ждут разбора (для строки «Анализ: осталось N»)
  final ValueNotifier<int> pending = ValueNotifier(0);

  void _publish() => pending.value = _queue.length;

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

  /// Профиль из памяти, без чтения диска: для проходов по всей библиотеке
  MixProfile? profileCached(String id) => _mem[id];

  /// Сколько профилей в памяти: по этому числу видно, что появились новые разборы
  int get profileCount => _mem.length;

  /// Читает сохранённые профили в память. Запускается в фоне при старте: потом по библиотеке можно ходить без диска
  Future<void> preload() async {
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('mix_') || !name.endsWith('.json')) continue;
        final id = name.substring(4, name.length - 5);
        if (_mem.containsKey(id)) continue;
        try {
          final p = MixProfile.fromJson(jsonDecode(await e.readAsString()));
          if (p != null) _mem[id] = p;
        } catch (_) {
          // битый файл: профиль посчитается заново
        }
      }
    } catch (e) {
      AppLog.warn('АвтоDJ: не прочитались сохранённые профили', e);
    }
  }

  /// Посчитать профиль, когда звук трека будет в кэше
  void prepare(String id) {
    if (_noTool) return;
    final p = profile(id);
    // Старый профиль без темпа и тональности досчитываем, только если звук уже в кэше: ради этого трек не качаем
    if (p != null && (p.v >= MixProfile.version || _tried.contains(id) || !cache.has(id))) return;
    _queue.add(id);
    _publish();
    unawaited(_pump());
  }

  /// Пакетный разбор, например плейлиста для АвтоDJ: недостающие треки докачиваются в кэш и разбираются по очереди.
  /// Возвращает, сколько треков поставлено в очередь
  int prepareMany(Iterable<String> ids) {
    if (_noTool) return 0;
    var n = 0;
    for (final id in ids) {
      final p = profile(id);
      if (p != null && p.v >= MixProfile.version) continue;
      if (!cache.has(id)) cache.enqueue(id);
      _tried.remove(id);
      if (_queue.add(id)) n++;
    }
    _publish();
    unawaited(_pump());
    return n;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.first;
        final src = cache.fileFor(id);
        // Звука ещё нет — ждём, пока кэш его докачает (плеер качает следующий трек заранее)
        var waited = 0;
        while (!(cache.has(id) && src.existsSync()) && waited < 120) {
          await Future<void>.delayed(const Duration(seconds: 2));
          waited += 2;
        }
        _queue.remove(id);
        _publish();
        if (!(cache.has(id) && src.existsSync())) continue;
        await _analyze(id, src);
      }
    } finally {
      _running = false;
      _publish();
    }
  }

  Future<void> _analyze(String id, File src) async {
    _tried.add(id);
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
      final base = MixProfile.fromEnvelope(envelope(bytes));
      if (base == null) return;
      // Темп, доли и тональность — в отдельном изоляте: на длинном треке это секунды работы
      AudioAnalysis? a;
      var failed = false;
      try {
        a = await analyzeInIsolate(bytes, introMs: base.introMs, endMs: base.endMs);
      } catch (e) {
        failed = true;
        AppLog.warn('АвтоDJ: не посчитались темп и тональность', e);
      }
      final tags = await _readTags(src);
      // Если разбор упал, сохраняем прежний профиль без отметки о новой версии: попробуем в следующий раз
      final p = failed ? base : base.withAnalysis(a, tagBpm: tags.$1, tagKey: tags.$2, genre: tags.$3);
      _mem[id] = p;
      await _file(id).writeAsString(jsonEncode(p.toJson()));
      onProfile?.call(id);
    } catch (e) {
      AppLog.warn('Умный переход: не посчитался звук', e);
    }
  }

  /// Теги из самого файла: темп, тональность и жанр (их вписывают Mixxx, Traktor, Beatport и другие)
  Future<(double?, String?, String)> _readTags(File src) async {
    try {
      final out = File('${dir.path}${Platform.pathSeparator}mix_tags.txt');
      if (out.existsSync()) await out.delete();
      await Tools.run(tools.ffmpeg.path, ['-y', '-v', 'error', '-i', src.path, '-f', 'ffmetadata', out.path]);
      if (!out.existsSync()) return (null, null, '');
      final text = utf8.decode(await out.readAsBytes(), allowMalformed: true);
      await out.delete();
      return parseTagText(text);
    } catch (_) {
      return (null, null, '');
    }
  }

  /// Темп, тональность и жанр из текста, который отдаёт ffmpeg (`ключ=значение` построчно)
  static (double?, String?, String) parseTagText(String text) {
    double? bpm;
    String? key;
    var genre = '';
    for (final line in text.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0 || line.startsWith(';')) continue;
      final k = line.substring(0, i).trim().toLowerCase();
      final v = line.substring(i + 1).trim();
      if (v.isEmpty) continue;
      switch (k) {
        case 'bpm':
        case 'tbpm':
        case 'tempo':
        case 'tmpo':
          bpm ??= double.tryParse(v.replaceAll(',', '.'));
        case 'initialkey':
        case 'initial_key':
        case 'tkey':
        case 'key':
          key ??= v;
        case 'genre':
        case 'tcon':
          if (genre.isEmpty) genre = v.toLowerCase();
      }
    }
    return (bpm, key, genre);
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
