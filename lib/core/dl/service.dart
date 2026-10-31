// Загрузчик музыки внутри Cave Player: ссылка или название → лучший звук с YouTube
// → mp3 с тегами и обложкой → папка библиотеки на Google Диске. Задания идут по
// очереди, треки альбома — по три одновременно, как в music_downloaderV2.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../image_tools.dart';
import '../library.dart';
import '../models.dart';
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
  int skipped = 0; // уже были в библиотеке
  final List<String> log = [];
  final List<String> failedNames = [];
  DownloadJob(this.input, this.sourceId, this.folderName,
      {this.folderId, this.path = '', this.quiet = false, this.onTrack, this.makePlaylist = true})
      : title = input;

  /// Своя папка для одиночных треков (например, «Моя волна»); иначе — корень источника
  final String? folderId;
  final String path;

  /// Без сообщений и записи в ленте: фоновые загрузки волны
  final bool quiet;

  /// Каждый загруженный на Диск трек
  final void Function(Track t)? onTrack;

  String get target => folderId ?? sourceId;

  /// Сделать из скачанного плейлиста плейлист в Cave Player (для ссылок на плейлисты)
  final bool makePlaylist;

  /// Плейлист Cave Player, собранный из этого задания
  String? playlistId;
  String? playlistName;

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
  DownloadJob? enqueue(String input, String sourceId,
      {String? folderId, String path = '', bool quiet = false, void Function(Track t)? onTrack, bool makePlaylist = true}) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final src = lib.data.sources.where((s) => s.id == sourceId).firstOrNull;
    final job = DownloadJob(text, sourceId, src?.name ?? 'Cave Player',
        folderId: folderId, path: path, quiet: quiet, onTrack: onTrack, makePlaylist: makePlaylist);
    jobs.insert(0, job);
    notifyListeners();
    unawaited(_pump());
    return job;
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
      if (job.done > 0 && !job.quiet) {
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
      if (yandexPlaylistApiUrl(q) != null) return _externalPlaylist(job, yt, temp, await yandexPlaylist(q), log);
      log('Поддерживаются ссылки на трек, альбом и плейлист Яндекс Музыки.');
      return false;
    }
    if (q.contains('deezer.com/')) {
      if (q.contains('/album/')) {
        final res = await deezerAlbum(q);
        return res != null && await _album(job, yt, temp, res.$1, res.$2, log);
      }
      if (q.contains('/track/')) return _single(job, yt, temp, await deezerTrack(q), 'Deezer', log);
      log('Поддерживаются ссылки на трек и на альбом Deezer.');
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
      if (q.contains('/playlist/') || q.startsWith('spotify:playlist:')) {
        return _externalPlaylist(job, yt, temp, await spotifyPlaylist(q), log);
      }
      log('Поддерживаются ссылки на трек, альбом и плейлист Spotify.');
      return false;
    }
    if ((q.contains('youtube.com') || q.contains('youtu.be')) && q.contains('/playlist') && q.contains('list=')) {
      return _playlist(job, yt, temp, q, log);
    }
    if (q.startsWith('http://') || q.startsWith('https://')) {
      job.total = 1;
      final entries = await yt.download('${temp.path}${Platform.pathSeparator}%(id)s.%(ext)s', q);
      return _finishYoutube(job, yt, entries, folderId: job.target, path: job.path);
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
    final t = await _sourceTrack(job, yt, temp, meta, folderId: job.target, path: job.path, cover: await yt.cover(meta.coverUrl));
    return t != null;
  }

  /// Возвращает трек из библиотеки: уже имевшийся или только что загруженный. null — не получилось
  Future<Track?> _sourceTrack(DownloadJob job, YouTube yt, Directory temp, TrackMeta meta,
      {required String folderId, required String path, File? cover, String prefix = ''}) async {
    // Такая песня уже есть в библиотеке — второй копии не нужно
    final same = lib.existing(meta.artist, meta.title);
    if (same != null) {
      yt.log('Уже есть в библиотеке: ${same.displayArtist} — ${same.title}, пропускаю');
      job.skipped++;
      return same;
    }
    final cands = await yt.ranked(meta);
    if (cands.isEmpty) {
      job.failed++;
      job.failedNames.add(meta.label);
      return null;
    }
    // У каждого трека своя папка: при параллельной загрузке альбома файлы не перепутаются
    final dir = Directory('${temp.path}${Platform.pathSeparator}${YouTube.unique()}');
    await dir.create();
    for (final c in cands.take(maxDownloadTries)) {
      final d = c.duration;
      final dur = d == null ? '?' : '${d ~/ 60}:${(d % 60).toInt().toString().padLeft(2, '0')}';
      yt.log('Выбрано на ${c.site}: ${c.title}  [${c.channel}, $dur]');
      if (YouTube.score(c, meta) < 0) yt.log('Внимание: надёжного варианта не нашлось, это может быть не оригинал.');
      final entries = await yt.download('${dir.path}${Platform.pathSeparator}%(id)s.%(ext)s',
          c.url, embedThumb: cover == null);
      if (entries.isEmpty) {
        yt.log('Не скачалось, пробую следующий вариант…');
        continue;
      }
      await yt.tag(entries.first.path, meta, coverFile: cover);
      final file = YouTube.moveTo(entries.first.path, dir.path, clampName(meta.label), prefix);
      return _upload(job, yt, File(file), folderId: folderId, path: path);
    }
    job.failed++;
    job.failedNames.add(meta.label);
    return null;
  }

  /// Плейлист из Spotify или Яндекс Музыки: скачивает недостающие треки и собирает из них плейлист Cave Player
  Future<bool> _externalPlaylist(DownloadJob job, YouTube yt, Directory temp, PlaylistInfo? info, void Function(String) log) async {
    if (info == null) {
      log('Не удалось получить список треков плейлиста.');
      return false;
    }
    if (info.truncated) {
      log('Внимание: Spotify без ключа отдаёт только первые $spotifyPlaylistLimit треков плейлиста. Остальные придётся добавить отдельно.');
    }
    return _album(job, yt, temp, info.name, info.metas, log, playlist: info, subfolder: safeName(info.name, 80));
  }

  Future<bool> _album(DownloadJob job, YouTube yt, Directory temp, String name, List<TrackMeta> metas, void Function(String) log,
      {PlaylistInfo? playlist, String? subfolder}) async {
    job.title = name;
    job.total = metas.length;
    log('Альбом: $name  (${metas.length} ${metas.length == 1 ? 'трек' : 'треков'})');
    final folder = subfolder ?? safeName(name);
    final folderId = await lib.ensureSubfolder(job.sourceId, job.sourceId, folder);
    log('Папка на Диске: ${job.folderName}/$folder');
    // Обложки заранее, по одной на адрес
    final covers = <String, File?>{};
    for (final url in metas.map((m) => m.coverUrl).whereType<String>().toSet()) {
      covers[url] = await yt.cover(url);
    }
    final ids = List<String?>.filled(metas.length, null);
    await _pool(List.generate(metas.length, (i) => i), albumWorkers, (i) async {
      final m = metas[i];
      final t = await _sourceTrack(job, yt, temp, m,
          folderId: folderId, path: folder, cover: covers[m.coverUrl], prefix: '${(i + 1).toString().padLeft(2, '0')} - ');
      ids[i] = t?.id;
      log('[${i + 1}/${metas.length}] ${t != null ? 'OK' : 'ОШИБКА'}: ${m.label}');
    });
    _summary(job, log);
    if (playlist != null && job.makePlaylist) {
      await _makePlaylist(job, yt, playlist.name, ids, playlist.coverUrl, log);
    }
    return job.done + job.skipped > 0;
  }

  Future<bool> _playlist(DownloadJob job, YouTube yt, Directory temp, String url, void Function(String) log) async {
    var title = 'Playlist';
    String? listCover;
    var items = <Map>[];
    try {
      final out = await Tools.run(tools.ytdlp.path, [...tools.jsArgs, '-J', '--flat-playlist', '--no-warnings', url]);
      final json = out.firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (json.isNotEmpty) {
        final data = (await compute(_decode, json)) as Map;
        title = '${data['title'] ?? 'Playlist'}';
        final thumbs = [for (final t in (data['thumbnails'] as List? ?? const [])) if (t is Map && t['url'] != null) '${t['url']}'];
        if (thumbs.isNotEmpty) listCover = thumbs.last;
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
    final ids = List<String?>.filled(items.length, null);
    await _pool(List.generate(items.length, (i) => i), albumWorkers, (i) async {
      final e = items[i];
      // Такая песня уже лежит в библиотеке — не качаем второй раз, в плейлист встанет имеющийся трек
      final have = _existingForVideo(e);
      if (have != null) {
        ids[i] = have.id;
        job.skipped++;
        log('[${i + 1}/${items.length}] Уже есть в библиотеке: ${have.displayArtist} — ${have.title}');
        return;
      }
      final dir = Directory('${temp.path}${Platform.pathSeparator}p$i');
      await dir.create();
      final entries = await yt.download('${dir.path}${Platform.pathSeparator}%(id)s.%(ext)s', 'https://www.youtube.com/watch?v=${e['id']}');
      final got = <String>[];
      final ok = await _finishYoutube(job, yt, entries, folderId: folderId, path: safeName(title, 80), number: i + 1, ids: got);
      if (got.isNotEmpty) ids[i] = got.first;
      if (!ok) {
        job.failed++;
        job.failedNames.add('${e['title'] ?? e['id']}');
      }
      log('[${i + 1}/${items.length}] ${ok ? 'OK' : 'ОШИБКА'}: ${e['title'] ?? e['id']}');
    });
    _summary(job, log);
    if (job.makePlaylist) await _makePlaylist(job, yt, title, ids, listCover, log);
    return job.done + job.skipped > 0;
  }

  /// Трек библиотеки, который совпадает с роликом из списка YouTube (по исполнителю и названию), или null
  Track? _existingForVideo(Map e) {
    final channel = '${e['channel'] ?? e['uploader'] ?? ''}'.replaceAll(RegExp(r'\s*-\s*Topic$'), '');
    final (a, t) = splitArtistTitle(stripLeadNum(channel), stripLeadNum('${e['title'] ?? ''}'));
    final artist = stripLeadNum(a);
    final title = cleanTitle(stripLeadNum(t));
    if (artist.isEmpty || title.isEmpty) return null;
    return lib.existing(artist, title);
  }

  /// Просто текст: лучший вариант с YouTube
  Future<bool> _search(DownloadJob job, YouTube yt, Directory temp, String text, void Function(String) log) async {
    // Сначала узнаём песню в Deezer: с её длительностью на YouTube выбирается студийная запись,
    // а теги и обложка берутся настоящие
    TrackMeta? found;
    try {
      found = await deezerFind(text);
    } catch (_) {}
    if (found != null) return _single(job, yt, temp, found, 'Deezer', log);
    final (artist, title) = text.contains(' - ') ? splitArtistTitle('', text) : ('', text);
    final meta = TrackMeta(artist: artist, title: title.isEmpty ? text : title);
    job.total = 1;
    final cands = await yt.ranked(meta);
    for (final c in cands.take(maxDownloadTries)) {
      log('Выбрано на ${c.site}: ${c.title}  [${c.channel}]');
      final entries = await yt.download('${temp.path}${Platform.pathSeparator}%(id)s.%(ext)s', c.url);
      if (entries.isNotEmpty) return _finishYoutube(job, yt, entries, folderId: job.target, path: job.path);
    }
    return false;
  }

  /// Обычные ролики YouTube: красивое имя и теги без дублей, мусора и лишних номеров
  Future<bool> _finishYoutube(DownloadJob job, YouTube yt, List<Entry> entries,
      {required String folderId, required String path, int? number, List<String>? ids}) async {
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
      final uploaded = await _upload(job, yt, File(file), folderId: folderId, path: path);
      ids?.add(uploaded.id);
    }
    return entries.isNotEmpty;
  }

  Future<Track> _upload(DownloadJob job, YouTube yt, File file, {required String folderId, required String path}) async {
    yt.log('Загружаю на Диск: ${file.uri.pathSegments.last}');
    final t = await lib.uploadOne(file, sourceId: job.sourceId, folderId: folderId, path: path);
    job.done++;
    try {
      job.onTrack?.call(t);
    } catch (e) {
      AppLog.warn('Загрузчик: после загрузки', e);
    }
    _notify();
    return t;
  }

  /// Собирает из скачанных треков плейлист Cave Player: название и порядок как в источнике.
  /// Плейлист с таким названием у вас уже есть — дополняет его недостающими треками.
  Future<void> _makePlaylist(DownloadJob job, YouTube yt, String name, List<String?> ids, String? coverUrl, void Function(String) log) async {
    final found = <String>[];
    for (final id in ids) {
      if (id != null && !found.contains(id)) found.add(id);
    }
    if (found.isEmpty) {
      log('В плейлист Cave Player добавлять нечего: ни один трек не скачался.');
      return;
    }
    final id = addToNamedPlaylist(lib, name, found);
    final created = id.created;
    job.playlistId = id.id;
    job.playlistName = name;
    if (created && coverUrl != null) {
      try {
        final file = await yt.cover(coverUrl);
        if (file != null) {
          final jpeg = await compressImage(await file.readAsBytes(), maxSide: 1000);
          lib.setPlaylistCover(id.id, await lib.uploadCover(jpeg, 'jpg'));
        }
      } catch (e) {
        log('Обложку плейлиста поставить не удалось: $e');
      }
    }
    log(created
        ? 'Создан плейлист «$name» в Cave Player: ${found.length} ${found.length == 1 ? 'трек' : 'треков'}.'
        : 'Плейлист «$name» уже был: добавлено недостающих треков — ${id.added}.');
    lib.messages.add(created ? 'Плейлист «$name» создан' : 'Плейлист «$name» дополнен');
  }

  void _summary(DownloadJob job, void Function(String) log) {
    log('Готово: скачано ${job.done} из ${job.total}'
        '${job.skipped > 0 ? ', уже были в библиотеке: ${job.skipped}' : ''}.');
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

/// Результат [addToNamedPlaylist]
class NamedPlaylistResult {
  final String id;
  final bool created;
  final int added;
  const NamedPlaylistResult(this.id, this.created, this.added);
}

/// Кладёт треки в ваш плейлист с таким названием (без учёта регистра). Если его нет — создаёт.
/// Порядок сохраняется, уже лежащие в плейлисте треки не дублируются.
NamedPlaylistResult addToNamedPlaylist(LibraryController lib, String name, List<String> trackIds) {
  final me = lib.me ?? '';
  final key = name.trim().toLowerCase();
  final same = lib.data.playlists.where((p) => (p.by.isEmpty || p.by == me) && p.name.trim().toLowerCase() == key).firstOrNull;
  if (same == null) {
    return NamedPlaylistResult(lib.createPlaylist(name.trim(), trackIds), true, trackIds.length);
  }
  final have = same.items.toSet();
  final fresh = [for (final t in trackIds) if (!have.contains(t)) t];
  if (fresh.isNotEmpty) lib.addToPlaylist(same.id, fresh);
  return NamedPlaylistResult(same.id, false, fresh.length);
}
