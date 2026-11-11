import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../audio_cache.dart';
import '../automix.dart';
import '../dl/tools.dart';
import '../drive.dart';
import '../library.dart';
import '../log.dart';
import '../models.dart';
import 'analyze.dart';
import 'dj_plan.dart';
import 'features.dart' show intelFft, intelRate;
import 'intel_store.dart';
import 'record.dart';
import 'similarity.dart';
import 'sync.dart';

// Audio Intelligence Engine: локальный разбор оригинальных записей, общий индекс признаков и подбор похожих.
//
// • Разбирает треки в фоне на Windows (ffmpeg + расчёт в отдельном изоляте): интерфейс и воспроизведение не блокируются.
//   Звук берётся из кэша плеера, а если его там нет — скачивается во временный файл и удаляется (кэш плеера не вытесняется).
// • Результаты сохраняются на диск и публикуются в общую папку на Диске; на Android и других устройствах индекс только читается.
// • Неизменённые файлы не пересчитываются: запись привязана к версии файла (контрольная сумма) и версии анализатора.
// • Без индекса или с неполным индексом всё продолжает работать: у приложения просто меньше сигналов для подбора.

/// Версия содержимого файла: контрольная сумма с Диска, а если её нет — время изменения и размер
String revisionOf(Track t) => t.md5.isNotEmpty ? t.md5 : '${t.modified}:${t.size}';

class IntelService extends ChangeNotifier {
  final Directory dir;
  final LibraryController lib;
  final DriveApi drive;
  final AudioCache cache;
  final Tools tools;

  IntelService({required this.dir, required this.lib, required this.drive, required this.cache, required this.tools}) {
    store = IntelStore(Directory('${dir.path}${Platform.pathSeparator}index'));
    _sync = IntelSync(drive, lib, store);
  }

  late final IntelStore store;
  late final IntelSync _sync;
  final IntelIndex _index = IntelIndex();
  int _indexVersion = -1;

  // ---------- настройки (личные, лежат в settings.view) ----------

  /// Разбирать звук можно только на Windows (там есть ffmpeg и запас мощности); остальные устройства читают общий индекс
  static bool get canAnalyzeHere => Platform.isWindows;

  bool get enabled => lib.settings.viewOf('intel.on', '1') == '1';
  bool get syncEnabled => lib.settings.viewOf('intel.sync', '1') == '1';

  /// Доля процессорного времени для разбора, 10…100 %: между треками делается пауза, пропорциональная работе
  int get cpuPercent => (int.tryParse(lib.settings.viewOf('intel.cpu', '60')) ?? 60).clamp(10, 100).toInt();

  /// 'full' — весь трек (нужен для сетки долей и фраз), 'fast' — четыре отрывка по 16 секунд
  String get mode => lib.settings.viewOf('intel.mode', 'full') == 'fast' ? 'fast' : 'full';

  /// Уточнять DJ-переходы по разбору звука (границы фраз, вокал, LUFS)
  bool get planEnabled => lib.settings.viewOf('intel.plan', '1') == '1';

  /// Разрешить резкие стыки (hard cut) на границе фразы, когда оба трека на полной энергии или вокал мешает наложению
  bool get cutEnabled => lib.settings.viewOf('intel.cut', '1') == '1';

  void setPlanEnabled(bool on) {
    _set('intel.plan', on ? '1' : '0');
    _notify();
  }

  void setCutEnabled(bool on) {
    _set('intel.cut', on ? '1' : '0');
    _notify();
  }

  /// Уточняет план DJ-перехода [plan] между [from] и [to] по их разбору. Любая ошибка или нехватка данных — план остаётся как был
  MixPlan refinePlan(MixPlan plan, MixProfile a, MixProfile b, String from, String to) {
    if (!planEnabled || !plan.dj) return plan;
    try {
      final r = DjPlanner.refine(plan, a, b, store.get(from), store.get(to), allowCut: cutEnabled);
      if (r.kind != DjKind.unchanged || r.notes.isNotEmpty) AppLog.info('DJ-переход: ${r.notes.join('; ')}');
      return r.plan;
    } catch (e) {
      AppLog.info('DJ-переход: уточнение не удалось ($e), план без изменений');
      return plan;
    }
  }

  void _set(String key, String value) {
    lib.settings.view[key] = value;
    unawaited(lib.saveSettings());
  }

  void setEnabled(bool on) {
    _set('intel.on', on ? '1' : '0');
    if (on) {
      _scan();
    }
    _notify();
  }

  void setSyncEnabled(bool on) {
    _set('intel.sync', on ? '1' : '0');
    if (on) unawaited(syncNow());
    _notify();
  }

  void setCpuPercent(int v) {
    _set('intel.cpu', '${v.clamp(10, 100)}');
    _notify();
  }

  void setMode(String m) {
    _set('intel.mode', m == 'fast' ? 'fast' : 'full');
    _scan();
    _notify();
  }

  // ---------- состояние ----------

  final ListQueue<String> _queue = ListQueue();
  final Set<String> _queued = {};
  final Set<String> _force = {};
  final Map<String, int> _failed = {};
  bool _paused = false;
  bool _running = false;
  bool _noTool = false;
  bool _disposed = false;
  bool _opened = false;
  Track? _currentTrack;
  String _status = '';
  String lastError = '';
  int _done = 0;
  int _total = 0;
  int _consecutiveFailures = 0;

  bool get paused => _paused;
  bool get running => _running;
  bool get canRun => canAnalyzeHere && enabled && !_noTool;
  int get total => _total;

  /// Сколько треков библиотеки уже разобрано
  int get done => _done;

  /// Сколько ждёт разбора
  int get pending => _queue.length + (_currentTrack == null ? 0 : 1);
  int get failed => _failed.values.where((n) => n >= 2).length;
  Track? get current => _currentTrack;
  String get syncStatus => _syncStatus;
  String _syncStatus = '';

  /// Сколько записей в общем индексе (включая те, что пришли с других устройств)
  int get indexed => store.count;

  /// Строка для настроек: что сейчас происходит
  String get statusLine {
    if (!canAnalyzeHere) return 'На этом устройстве индекс только читается: разбор звука идёт на компьютере с Windows.';
    if (!enabled) return 'Разбор звука выключен.';
    if (_noTool) return 'Не удалось установить FFmpeg: разбор остановлен.';
    if (_paused && pending > 0) return 'Пауза. Осталось треков: $pending.';
    final cur = _currentTrack;
    if (cur != null) return 'Разбираю «${cur.title}». Осталось треков: $pending.';
    if (_status.isNotEmpty) return _status;
    if (pending > 0) return 'Ожидает разбора: $pending.';
    return 'Всё разобрано: $_done из $_total.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------- запуск ----------

  Timer? _syncTimer;
  Timer? _scanTimer;
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  bool _syncedOnce = false;

  /// Читает локальный индекс и запускает фоновые задачи. Вызывать без ожидания: в запуск приложения это не вмешивается
  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    await store.load();
    store.wantRevision = (id) {
      final t = lib.data.tracks[id];
      return t == null ? null : revisionOf(t);
    };
    lib.addListener(_onLibrary);
    _syncTimer = Timer.periodic(const Duration(minutes: 10), (_) => unawaited(syncNow()));
    _scanTimer = Timer(const Duration(seconds: 6), () => unawaited(_boot()));
    _recount();
    _notify();
  }

  Future<void> _boot() async {
    // Сначала читаем чужие результаты: возможно, трек уже разобран на другом компьютере
    if (syncEnabled) await syncNow(publish: false);
    _syncedOnce = true;
    _scan();
  }

  void _onLibrary() {
    if (!_opened || _disposed) return;
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 4), () {
      if (_syncedOnce) {
        _scan();
      } else {
        unawaited(_boot());
      }
    });
  }

  /// Индекс для сравнения; пересобирается, если записи изменились
  IntelIndex get index {
    if (_indexVersion != store.version) {
      _index.rebuild(store.records);
      _indexVersion = store.version;
    }
    return _index;
  }

  TrackFeatures? features(String id) => store.get(id);

  /// Насколько каждый трек библиотеки похож на один из [seeds]: id → 0…1, только выше [floor].
  /// Пусто, если признаков у исходных треков ещё нет
  Map<String, double> similarMap(Iterable<String> seeds,
      {SimilarityMode mode = SimilarityMode.sound, double floor = 0.35, int limit = 500, Map<String, double> taste = const {}}) {
    if (store.count == 0) return const {};
    final hits = index.similar(
      seeds: seeds,
      taste: taste,
      mode: mode,
      limit: limit,
      minScore: floor,
      minConfidence: 0.25,
      allow: (id) => lib.data.tracks.containsKey(id),
    );
    return {for (final h in hits) h.id: h.score};
  }

  // ---------- очередь ----------

  void _recount() {
    var done = 0;
    final tracks = lib.allTracks;
    for (final t in tracks) {
      final rec = store.get(t.id);
      if (rec != null && rec.isCurrentFor(revisionOf(t))) done++;
    }
    _done = done;
    _total = tracks.length;
  }

  /// Находит треки без актуального разбора и ставит их в очередь
  void _scan() {
    if (_disposed) return;
    final missing = <String>[];
    final upgrade = <String>[];
    var done = 0;
    final tracks = lib.allTracks;
    final wantFull = mode == 'full';
    for (final t in tracks) {
      final rec = store.get(t.id);
      if (rec == null || !rec.isCurrentFor(revisionOf(t))) {
        if ((_failed[t.id] ?? 0) < 2) missing.add(t.id);
      } else {
        done++;
        // Раньше разбирали отрывками, а теперь нужен весь трек: переразбираем после новых
        if (wantFull && rec.mode == 'fast' && (_failed[t.id] ?? 0) < 2 && rec.durationSec <= 15 * 60) upgrade.add(t.id);
      }
    }
    _done = done;
    _total = tracks.length;
    if (canRun) {
      for (final id in [...missing, ...upgrade]) {
        if (_queued.add(id)) _queue.add(id);
      }
      if (_queue.isNotEmpty && !_paused) unawaited(_pump());
    }
    _notify();
  }

  void pause() {
    _paused = true;
    _notify();
  }

  void resume() {
    _paused = false;
    _scan();
    if (_queue.isNotEmpty) unawaited(_pump());
    _notify();
  }

  /// Поставить трек первым (например, тот, что играет сейчас)
  void prioritize(String id) {
    if (!canRun) return;
    final rec = store.get(id);
    final t = lib.data.tracks[id];
    if (t == null || (rec != null && rec.isCurrentFor(revisionOf(t)))) return;
    _queue.remove(id);
    _queue.addFirst(id);
    _queued.add(id);
    if (!_paused) unawaited(_pump());
  }

  /// Пересчитать выбранные треки заново (даже если разбор актуален)
  void reanalyze(Iterable<String> ids) {
    for (final id in ids) {
      if (!lib.data.tracks.containsKey(id)) continue;
      _failed.remove(id);
      _force.add(id);
      if (_queued.add(id)) _queue.add(id);
    }
    if (canRun && !_paused) unawaited(_pump());
    _notify();
  }

  void reanalyzeAll() => reanalyze([for (final t in lib.allTracks) t.id]);

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    _notify();
    try {
      while (_queue.isNotEmpty && canRun && !_paused && !_disposed) {
        final id = _queue.removeFirst();
        _queued.remove(id);
        final t = lib.data.tracks[id];
        if (t == null) continue;
        _currentTrack = t;
        _status = '';
        _notify();
        final sw = Stopwatch()..start();
        try {
          await _analyzeOne(t);
          _consecutiveFailures = 0;
          _recount();
        } catch (e) {
          _failed[id] = (_failed[id] ?? 0) + 1;
          _consecutiveFailures++;
          lastError = '$e';
          AppLog.warn('Разбор звука: не получилось «${t.title}»', e);
        }
        sw.stop();
        _currentTrack = null;
        _force.remove(id);
        _notify();
        if (_consecutiveFailures >= 3) {
          // Несколько неудач подряд — скорее всего, нет сети: не крутим процессор вхолостую
          _status = 'Нет доступа к файлам, повторю через две минуты.';
          _notify();
          await Future<void>.delayed(const Duration(minutes: 2));
          _consecutiveFailures = 0;
          _status = '';
        } else {
          // Лимит процессора: после работы длиной W отдыхаем W·(100−p)/p
          final p = cpuPercent;
          if (p < 100) {
            final rest = (sw.elapsedMilliseconds * (100 - p) / p).round().clamp(0, 30000).toInt();
            if (rest > 0) await Future<void>.delayed(Duration(milliseconds: rest));
          }
        }
        if (store.pendingCount >= IntelSync.shardSize) unawaited(syncNow());
      }
    } finally {
      _running = false;
      _currentTrack = null;
      _notify();
    }
    if (_queue.isEmpty && store.pendingCount > 0) unawaited(syncNow());
  }

  // ---------- обмен с Диском ----------

  Future<void> syncNow({bool publish = true}) async {
    if (_disposed || !syncEnabled || _sync.busy) return;
    if (DateTime.now().difference(_lastSync) < const Duration(seconds: 20)) return;
    _lastSync = DateTime.now();
    _syncStatus = 'Синхронизирую индекс…';
    _notify();
    final r = await _sync.sync(publish: publish);
    if (_disposed) return;
    if (r.ok) {
      _syncStatus = 'Индекс обновлён: прочитано файлов ${r.shardsRead}, новых записей ${r.recordsMerged}, опубликовано ${r.recordsPublished}.';
      if (r.recordsMerged > 0) _scan();
    } else {
      _syncStatus = 'Синхронизация не удалась, работаю с локальной копией.';
      AppLog.warn('Индекс звука: обмен с Диском', r.error);
    }
    _notify();
  }

  // ---------- разбор одного трека ----------

  String get _sep => Platform.pathSeparator;
  Directory get _work => Directory('${dir.path}${_sep}work');

  Future<void> _ensureTools() async {
    if (tools.ffmpeg.existsSync() && tools.ffprobe.existsSync()) return;
    await tools.ensure((s) {
      _status = s;
      _notify();
    });
    if (!tools.ffmpeg.existsSync() || !tools.ffprobe.existsSync()) {
      _noTool = true;
      throw Exception('FFmpeg не установлен');
    }
  }

  Future<double?> _probeDuration(File src) async {
    try {
      final lines = await Tools.run(tools.ffprobe.path, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', src.path]);
      for (final l in lines) {
        final v = double.tryParse(l.trim());
        if (v != null && v > 0) return v;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _analyzeOne(Track t) async {
    await _ensureTools();
    await _work.create(recursive: true);
    // Звук: из кэша плеера, а если его там нет — во временный файл (и удалим после разбора)
    final cached = cache.fileFor(t.id);
    File src;
    var temp = false;
    if (cache.has(t.id) && cached.existsSync()) {
      src = cached;
    } else {
      src = File('${_work.path}${_sep}src.audio');
      temp = true;
      for (final f in [src, File('${src.path}.part'), File('${src.path}.part.version')]) {
        if (f.existsSync()) f.deleteSync();
      }
      final email = await lib.accessFor(t.source);
      _status = 'Скачиваю «${t.title}» для разбора…';
      _notify();
      await drive.downloadToFile(email, t.id, src, expectedModified: t.modified);
    }
    try {
      final rev = revisionOf(t);
      final known = t.durationMs != null && t.durationMs! > 0 ? t.durationMs! / 1000.0 : await _probeDuration(src);
      var m = mode;
      if (known != null && known > 15 * 60) m = 'fast'; // длинные миксы целиком не грузим в память
      if (known != null && known < 90) m = 'full';
      if (known == null) m = 'full';
      final input = m == 'full' ? await _decodeFull(t, src, rev, known) : await _decodeExcerpts(t, src, rev, known!);
      final rec = await analyzeAudioInIsolate(input);
      store.put(rec, local: true, force: _force.contains(t.id));
    } finally {
      if (temp) {
        for (final f in [src, File('${src.path}.part'), File('${src.path}.part.version')]) {
          try {
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  List<String> get _threads => cpuPercent <= 50 ? const ['-threads', '1'] : const [];

  File _w(String name) => File('${_work.path}$_sep$name');

  void _clean(Iterable<File> files) {
    for (final f in files) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  AnalysisInput _stub(Track t, String rev, double? dur, String mode) => AnalysisInput(
        trackId: t.id,
        revision: rev,
        mode: mode,
        durationSec: dur ?? 0,
        chunks: const [],
        decodeGap: true,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Весь трек одним проходом: звук для тембра, звук для темпа и громкость по BS.1770
  Future<AnalysisInput> _decodeFull(Track t, File src, String rev, double? known) async {
    final w22 = _w('a22.raw'), w4 = _w('a4.raw');
    double? lufs, lra;
    var ok = false;
    try {
      for (final withLoudness in [true, false]) {
        _clean([w22, w4]);
        final lines = await Tools.run(tools.ffmpeg.path, [
          '-y',
          '-v',
          withLoudness ? 'info' : 'error',
          '-nostats',
          ..._threads,
          '-i',
          src.path,
          '-map', '0:a:0', '-ac', '1', '-ar', '$intelRate', '-f', 's16le', w22.path,
          '-map', '0:a:0', '-ac', '1', '-ar', '4000', '-f', 's16le', w4.path,
          if (withLoudness) ...['-map', '0:a:0', '-af', 'ebur128=framelog=quiet', '-f', 'null', '-'],
        ]);
        if (w22.existsSync() && w22.lengthSync() > intelRate && w4.existsSync() && w4.lengthSync() > 8000) {
          ok = true;
          if (withLoudness) {
            final r = parseLoudness(lines);
            lufs = r.$1;
            lra = r.$2;
          }
          break;
        }
      }
      if (!ok) return _stub(t, rev, known, 'full');
      final b22 = await w22.readAsBytes();
      final b4 = await w4.readAsBytes();
      final decoded = b22.length / 2 / intelRate;
      return AnalysisInput(
        trackId: t.id,
        revision: rev,
        mode: 'full',
        durationSec: known ?? decoded,
        chunks: [AudioChunk(b22, b4)],
        lufs: lufs,
        lra: lra,
        decodeGap: known != null && decoded < known * 0.85,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
    } finally {
      _clean([w22, w4]);
    }
  }

  /// Четыре отрывка по 16 секунд: начало, две части из середины, концовка
  Future<AnalysisInput> _decodeExcerpts(Track t, File src, String rev, double dur) async {
    const len = 16.0;
    final starts = <double>[0, dur * 0.35 - len / 2, dur * 0.65 - len / 2, dur - len - 1];
    final chunks = <AudioChunk>[];
    final w22 = _w('e22.raw'), w4 = _w('e4.raw');
    try {
      for (final s in starts) {
        _clean([w22, w4]);
        await Tools.run(tools.ffmpeg.path, [
          '-y', '-v', 'error', ..._threads,
          '-ss', math.max(0.0, s).toStringAsFixed(2), '-t', '$len', '-i', src.path,
          '-map', '0:a:0', '-ac', '1', '-ar', '$intelRate', '-f', 's16le', w22.path,
          '-map', '0:a:0', '-ac', '1', '-ar', '4000', '-f', 's16le', w4.path,
        ]);
        if (!w22.existsSync() || !w4.existsSync()) continue;
        final b22 = await w22.readAsBytes();
        final b4 = await w4.readAsBytes();
        // Отрывок короче 15 секунд для темпа не годится, а для тембра — годится; оставляем только полные
        if (b22.length ~/ 2 < intelFft * 4 || b4.length < 3200) continue;
        chunks.add(AudioChunk(Uint8List.fromList(b22), Uint8List.fromList(b4)));
      }
    } finally {
      _clean([w22, w4]);
    }
    if (chunks.isEmpty) return _stub(t, rev, dur, 'fast');
    return AnalysisInput(
      trackId: t.id,
      revision: rev,
      mode: 'fast',
      durationSec: dur,
      chunks: chunks,
      decodeGap: chunks.length < starts.length,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Интегральная громкость и диапазон громкости из итога фильтра ebur128 в тексте ffmpeg.
  /// ($1 — LUFS, $2 — LU); null, если итога нет (старая сборка, тишина)
  @visibleForTesting
  static (double?, double?) parseLoudness(Iterable<String> lines) {
    double? i, lra;
    final reI = RegExp(r'^I:\s*(-?\d+(?:\.\d+)?)\s*LUFS');
    final reL = RegExp(r'^LRA:\s*(\d+(?:\.\d+)?)\s*LU');
    // Итог идёт в конце: берём последние совпадения
    for (final raw in lines) {
      final l = raw.trim();
      final a = reI.firstMatch(l);
      if (a != null) i = double.tryParse(a.group(1)!);
      final b = reL.firstMatch(l);
      if (b != null) lra = double.tryParse(b.group(1)!);
    }
    if (i != null && i <= -69.5) i = null; // порог тишины, не громкость
    return (i, lra);
  }

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    _scanTimer?.cancel();
    lib.removeListener(_onLibrary);
    unawaited(store.close());
    super.dispose();
  }
}
