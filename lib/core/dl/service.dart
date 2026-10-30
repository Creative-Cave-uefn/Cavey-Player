// Загрузчик музыки внутри Cave Player: ссылка или название → лучший звук с YouTube
// → mp3 с тегами и обложкой → папка библиотеки на Google Диске. Задания идут по
// очереди, треки альбома — по три одновременно, как в music_downloaderV2.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library.dart';
import '../log.dart';
import 'sources.dart';
import 'text.dart';
import 'tools.dart';
import 'youtube.dart';

const albumWorkers = 3;

enum JobState { queued, running, done, failed }

class DownloadJob {
  final String input;
  final String sourceId; // папка библиотеки, куда класть
  final String folderName;
  JobState state = JobState.queued;
  String title;
  int total = 0;
  int done = 0;
  int failed = 0;
  final List<String> log = [];
  final List<String> failedNames = [];
  DownloadJob(this.input, this.sourceId, this.folderName) : title = input;

  void add(String line) {
    log.add(line);
    if (log.length > 400) log.removeRange(0, log.length - 400);
  }
}

class DownloadService extends ChangeNotifier {
  final LibraryController lib;
  final Tools tools;
  final Directory work;
  final List<DownloadJob> jobs = [];
  bool _running = false;
  String toolsVersion = '';
  bool installing = false;

  DownloadService(this.lib, this.tools, this.work);

  bool get busy => _running || installing;

  void _notify() {
    // Журнал пишется часто — перерисовываем не чаще нескольких раз в секунду
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 250), notifyListeners);
  }

  Timer? _notifyTimer;

  Future<void> refreshVersion() async {
    toolsVersion = await tools.version();
    notifyListeners();
  }

  Future<void> updateTools() async {
    if (busy) return;
    installing = true;
    final job = DownloadJob('Обновление yt-dlp', '', '')..state = JobState.running;
    jobs.insert(0, job);
    notifyListeners();
    try {
      await tools.updateYtdlp((l) {
        job.add(l);
        _notify();
      });
      job.state = JobState.done;
    } catch (e) {
      job
        ..state = JobState.failed
        ..add('Ошибка: $e');
    } finally {
      installing = false;
      await refreshVersion();
    }
  }

  /// Добавляет задание в очередь
  void enqueue(String input, String sourceId) {
    final text = input.trim();
    if (text.isEmpty) return;
    final src = lib.data.sources.where((s) => s.id == sourceId).firstOrNull;
    jobs.insert(0, DownloadJob(text, sourceId, src?.name ?? 'Cave Player'));
    notifyListeners();
    unawaited(_pump());
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.state == JobState.done || j.state == JobState.failed);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = jobs.reversed.where((j) => j.state == JobState.queued).firstOrNull;
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _run(DownloadJob job) async {
    job.state = JobState.running;
    notifyListeners();
    void log(String l) {
      job.add(l);
      _notify();
    }

    final temp = Directory('${work.path}${Platform.pathSeparator}job-${DateTime.now().millisecondsSinceEpoch}');
    await temp.create(recursive: true);
    AppLog.info('Загрузчик: ${job.input}');
    try {
      if (!tools.ready) {
        log('Первый запуск: устанавливаю программы для скачивания…');
        installing = true;
        notifyListeners();
        try {
          await tools.ensure(log);
        } finally {
          installing = false;
        }
        unawaited(refreshVersion());
      } else {
        await tools.updateIfOld(log);
      }
      final yt = YouTube(tools, temp, log);
      final ok = await _route(job, yt, temp, log);
      job.state = ok ? JobState.done : JobState.failed;
      if (job.done > 0) {
        lib.onEvent?.call({'k': 'upload', 'n': job.done, 'folder': job.folderName});
        lib.messages.add('Скачано и загружено на Диск: ${job.done} ${job.done == 1 ? 'трек' : 'треков'}');
      }
      if (!ok) log('Ничего не скачалось. Смотрите сообщения выше.');
    } catch (e) {
      job.state = JobState.failed;
      log('Ошибка: $e');
      AppLog.warn('Загрузчик: ${job.input}', e);
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
      notifyListeners();
    }
  }

  // ---------- маршрутизация, как в download() скрипта ----------

  Future<bool> _route(DownloadJob job, YouTube yt, Directory temp, void Function(String) log) async {
    final q = job.input;
    if (q.contains('music.yandex.')) {
      if (q.contains('/track/')) return _single(job, yt, temp, await yandexTrack(q), 'Яндекс Музыке', log);
      if (q.contains('/album/')) {
        final res = await yandexAlbum(q);
        return res != null && await _album(job, yt, temp, res.$1, res.$2, log);
      }
      log('Поддерживаются ссылки на трек и на альбом Яндекс Музыки.');
      return false;
    }
    if (q.contains('open.spotify.com') || q.startsWith('spotify:')) {
      if (q.contains('/album/') || q.startsWith('spotify:album:')) {
        final res = await spotifyAlbum(q);
        return res != null && await _album(job, yt, temp, res.$1, res.$2, log);
      }
      if (q.contains('/track/') || q.startsWith('spotify:track:')) {
        return _single(job, yt, temp, await spotifyTrack(q, log), 'Spotify', log);
      }
      log('Поддерживаются ссылки на трек и на альбом Spotify.');
      return false;
    }
    if ((q.contains('youtube.com') || q.contains('youtu.be')) && q.contains('/playlist') && q.contains('list=')) {
      return _playlist(job, yt, temp, q, log);
    }
    if (q.startsWith('http://') || q.startsWith('https://')) {
      job.total = 1;
      final entries = await yt.download('${temp.path}${Platform.pathSeparator}%(id)s.%(ext)s', q);
      return _finishYoutube(job, yt, entries, folderId: job.sourceId, path: '');
    }
    return _search(job, yt, temp, q, log);
  }

  /// Трек из Яндекса или Spotify: лучшая версия с YouTube + теги и обложка источника
  Future<bool> _single(DownloadJob job, YouTube yt, Directory temp, TrackMeta? meta, String where, void Function(String) log) async {
    if (meta == null || looksGeneric(meta.title) || looksGeneric(meta.artist)) {
      log('Не удалось получить название трека. Вставьте его текстом, например: Исполнитель - Название.');
      return false;
    }
    job.title = meta.label;
    job.total = 1;
    log('Нашёл в $where: ${meta.label}');
    log('Ищу лучшую версию на YouTube…');
    final ok = await _sourceTrack(job, yt, temp, meta, folderId: job.sourceId, path: '', cover: await yt.cover(meta.coverUrl));
    return ok;
  }

  Future<bool> _sourceTrack(DownloadJob job, YouTube yt, Directory temp, TrackMeta meta,
      {required String folderId, required String path, File? cover, String prefix = ''}) async {
    final cands = await yt.ranked(meta);
    if (cands.isEmpty) {
      job.failed++;
      job.failedNames.add(meta.label);
      return false;
    }
    // У каждого трека своя папка: при параллельной загрузке альбома файлы не перепутаются
    final dir = Directory('${temp.path}${Platform.pathSeparator}${YouTube.unique()}');
    await dir.create();
    for (final c in cands.take(maxDownloadTries)) {
      final d = c.duration;
      final dur = d == null ? '?' : '${d ~/ 60}:${(d % 60).toInt().toString().padLeft(2, '0')}';
      yt.log('Выбрано на YouTube: ${c.title}  [${c.channel}, $dur]');
      if (YouTube.score(c, meta) < 0) yt.log('Внимание: надёжного варианта не нашлось, это может быть не оригинал.');
      final entries = await yt.download('${dir.path}${Platform.pathSeparator}%(id)s.%(ext)s',
          'https://www.youtube.com/watch?v=${c.id}', embedThumb: cover == null);
      if (entries.isEmpty) {
        yt.log('Не скачалось, пробую следующий вариант…');
        continue;
      }
      await yt.tag(entries.first.path, meta, coverFile: cover);
      final file = YouTube.moveTo(entries.first.path, dir.path, clampName(meta.label), prefix);
      await _upload(job, yt, File(file), folderId: folderId, path: path);
      return true;
    }
    job.failed++;
    job.failedNames.add(meta.label);
    return false;
  }

  Future<bool> _album(DownloadJob job, YouTube yt, Directory temp, String name, List<TrackMeta> metas, void Function(String) log) async {
    job.title = name;
    job.total = metas.length;
    log('Альбом: $name  (${metas.length} ${metas.length == 1 ? 'трек' : 'треков'})');
    final folderId = await lib.ensureSubfolder(job.sourceId, job.sourceId, safeName(name));
    log('Папка на Диске: ${job.folderName}/${safeName(name)}');
    // Обложки заранее, по одной на адрес
    final covers = <String, File?>{};
    for (final url in metas.map((m) => m.coverUrl).whereType<String>().toSet()) {
      covers[url] = await yt.cover(url);
    }
    await _pool(List.generate(metas.length, (i) => i), albumWorkers, (i) async {
      final m = metas[i];
      final ok = await _sourceTrack(job, yt, temp, m,
          folderId: folderId, path: safeName(name), cover: covers[m.coverUrl], prefix: '${(i + 1).toString().padLeft(2, '0')} - ');
      log('[${i + 1}/${metas.length}] ${ok ? 'OK' : 'ОШИБКА'}: ${m.label}');
    });
    _summary(job, log);
    return job.done > 0;
  }

  Future<bool> _playlist(DownloadJob job, YouTube yt, Directory temp, String url, void Function(String) log) async {
    var title = 'Playlist';
    var items = <Map>[];
    try {
      final out = await Tools.run(tools.ytdlp.path, [...tools.jsArgs, '-J', '--flat-playlist', '--no-warnings', url]);
      final json = out.firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (json.isNotEmpty) {
        final data = (await compute(_decode, json)) as Map;
        title = '${data['title'] ?? 'Playlist'}';
        items = [for (final e in (data['entries'] as List? ?? const [])) if (e is Map && e['id'] != null) e];
      }
    } catch (e) {
      log('Не удалось получить список плейлиста: $e');
    }
    if (items.isEmpty) {
      log('Список плейлиста пуст.');
      return false;
    }
    job.title = title;
    job.total = items.length;
    final folderId = await lib.ensureSubfolder(job.sourceId, job.sourceId, safeName(title, 80));
    log('Плейлист: $title  (${items.length} ${items.length == 1 ? 'трек' : 'треков'})');
    log('Папка на Диске: ${job.folderName}/${safeName(title, 80)}');
    await _pool(List.generate(items.length, (i) => i), albumWorkers, (i) async {
      final e = items[i];
      final dir = Directory('${temp.path}${Platform.pathSeparator}p$i');
      await dir.create();
      final entries = await yt.download('${dir.path}${Platform.pathSeparator}%(id)s.%(ext)s', 'https://www.youtube.com/watch?v=${e['id']}');
      final ok = await _finishYoutube(job, yt, entries, folderId: folderId, path: safeName(title, 80), number: i + 1);
      if (!ok) {
        job.failed++;
        job.failedNames.add('${e['title'] ?? e['id']}');
      }
      log('[${i + 1}/${items.length}] ${ok ? 'OK' : 'ОШИБКА'}: ${e['title'] ?? e['id']}');
    });
    _summary(job, log);
    return job.done > 0;
  }

  /// Просто текст: лучший вариант с YouTube
  Future<bool> _search(DownloadJob job, YouTube yt, Directory temp, String text, void Function(String) log) async {
    final (artist, title) = text.contains(' - ') ? splitArtistTitle('', text) : ('', text);
    final meta = TrackMeta(artist: artist, title: title.isEmpty ? text : title);
    job.total = 1;
    final cands = await yt.ranked(meta);
    for (final c in cands.take(maxDownloadTries)) {
      log('Выбрано на YouTube: ${c.title}  [${c.channel}]');
      final entries = await yt.download('${temp.path}${Platform.pathSeparator}%(id)s.%(ext)s', 'https://www.youtube.com/watch?v=${c.id}');
      if (entries.isNotEmpty) return _finishYoutube(job, yt, entries, folderId: job.sourceId, path: '');
    }
    return false;
  }

  /// Обычные ролики YouTube: красивое имя и теги без дублей, мусора и лишних номеров
  Future<bool> _finishYoutube(DownloadJob job, YouTube yt, List<Entry> entries,
      {required String folderId, required String path, int? number}) async {
    for (final e in entries) {
      var title = e.title;
      final lead = leadNumRe.firstMatch(title);
      title = stripLeadNum(title);
      var (artist, t) = splitArtistTitle(e.artist, title);
      artist = stripLeadNum(artist);
      t = cleanTitle(stripLeadNum(t));
      final n = number ?? int.tryParse(e.index) ?? (lead != null ? int.tryParse(lead.group(1)!) : null);
      final meta = TrackMeta(title: t, artist: artist, track: n?.toString() ?? '');
      job.title = entries.length == 1 && number == null ? meta.label : job.title;
      await yt.tag(e.path, meta);
      final dir = File(e.path).parent.path;
      final file = YouTube.moveTo(e.path, dir, clampName(meta.label), n != null && number != null ? '${n.toString().padLeft(2, '0')} - ' : '');
      await _upload(job, yt, File(file), folderId: folderId, path: path);
    }
    return entries.isNotEmpty;
  }

  Future<void> _upload(DownloadJob job, YouTube yt, File file, {required String folderId, required String path}) async {
    yt.log('Загружаю на Диск: ${file.uri.pathSegments.last}');
    await lib.uploadOne(file, sourceId: job.sourceId, folderId: folderId, path: path);
    job.done++;
    _notify();
  }

  void _summary(DownloadJob job, void Function(String) log) {
    log('Готово: скачано ${job.done} из ${job.total}.');
    if (job.failedNames.isNotEmpty) {
      log('Не удалось скачать:');
      for (final n in job.failedNames) {
        log('  - $n');
      }
    }
  }

  static Future<void> _pool<T>(List<T> items, int n, Future<void> Function(T) fn) async {
    var i = 0;
    Future<void> worker() async {
      while (i < items.length) {
        final item = items[i++];
        await fn(item);
      }
    }

    await Future.wait(List.generate(n, (_) => worker()));
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}

/// Разбор большого JSON плейлиста в отдельном потоке, чтобы не подвисал интерфейс
Object? _decode(String s) => jsonDecode(s);
