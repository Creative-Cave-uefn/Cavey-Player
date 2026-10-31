// Очередь загрузок Cavey. Скачивает отдельный модуль cave-downloader
// (YouTube, Sockseek, Bandcamp — см. module.dart и session.dart), а плеер
// отвечает на его вопросы: есть ли песня в библиотеке, в какую папку Диска
// положить альбом, загружает готовые файлы и собирает плейлисты.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../image_tools.dart';
import '../library.dart';
import '../log.dart';
import '../models.dart';
import 'module.dart';
import 'session.dart';

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
  final DownloaderModule module;

  /// Папка программ (yt-dlp, ffmpeg, Deno, Sockseek) — общая с караоке и automix
  final Directory tools;

  /// Временные файлы заданий
  final Directory work;

  final List<DownloadJob> jobs = [];
  bool _running = false;

  /// Версия yt-dlp, как её сообщил модуль
  String toolsVersion = '';

  DownloadService(this.lib, this.module, this.tools, this.work);

  // Ставятся программы: сам модуль, программы внутри модуля, обновление по кнопке
  bool _moduleInstalling = false;
  bool _toolsInstalling = false;
  bool _updating = false;
  bool get installing => _moduleInstalling || _toolsInstalling || _updating;

  bool get busy => _running || installing;

  /// Версия установленного модуля скачки ('' — ещё не скачан)
  String get moduleVersion => module.version;

  void _notify() {
    // Журнал пишется часто — перерисовываем не чаще нескольких раз в секунду
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 250), notifyListeners);
  }

  Timer? _notifyTimer;

  // Модуль запускается по одному заданию за раз: так его можно спокойно обновлять
  Future<void> _tail = Future.value();
  Future<T> _locked<T>(Future<T> Function() fn) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }

  Future<void> _ensureModule(void Function(String) log, {bool check = false}) async {
    final first = !module.installed;
    if (first) {
      _moduleInstalling = true;
      notifyListeners();
    }
    try {
      await module.ensure(log, check: check);
    } finally {
      if (first) {
        _moduleInstalling = false;
        notifyListeners();
      }
    }
  }

  /// Ставит или обновляет модуль и выполняет им одно задание
  Future<SessionResult> _invoke(Map<String, Object?> spec, void Function(String) log,
      {void Function(Map)? onProgress, ModuleCallHandler? onCall, bool check = false}) {
    return _locked(() async {
      await _ensureModule(log, check: check);
      for (var attempt = 0;; attempt++) {
        try {
          return await DownloaderSession.run(
            exe: module.exe.path,
            job: {...spec, 'tools': tools.path, 'work': work.path},
            onLog: log,
            onProgress: onProgress,
            onInstalling: (on) {
              _toolsInstalling = on;
              notifyListeners();
            },
            onCall: onCall,
          );
        } on ModuleProtocolMismatch catch (e) {
          // Модуль старше плеера — берём свежую сборку и пробуем ещё раз
          if (attempt > 0 || e.module > e.player || module.override != null) rethrow;
          log('$e Обновляю…');
          await _ensureModule(log, check: true);
        } finally {
          _toolsInstalling = false;
        }
      }
    });
  }

  Future<void> refreshVersion() async {
    if (!module.installed) {
      toolsVersion = 'ставится при первом скачивании';
      notifyListeners();
      return;
    }
    try {
      final r = await _invoke({'kind': 'tools-version'}, (_) {});
      toolsVersion = r.ok && r.value != null ? '${r.value}' : '?';
    } catch (e) {
      toolsVersion = '?';
      AppLog.warn('Загрузчик: версия', e);
    }
    notifyListeners();
  }

  /// Свежий модуль скачки и свежий yt-dlp (по кнопке в разделе «Скачать»)
  Future<void> updateTools() async {
    if (busy) return;
    _updating = true;
    final job = DownloadJob('Обновление загрузчика', '', '')..state = JobState.running;
    jobs.insert(0, job);
    notifyListeners();
    void log(String l) {
      job.add(l);
      _notify();
    }

    try {
      final r = await _invoke({'kind': 'tools-update'}, log, check: true);
      if (r.error != null) log('Ошибка: ${r.error}');
      job.state = r.ok ? JobState.done : JobState.failed;
    } catch (e) {
      job
        ..state = JobState.failed
        ..add('Ошибка: $e');
    } finally {
      _updating = false;
      notifyListeners();
      await refreshVersion();
    }
  }

  /// Ставит Sockseek (Soulseek) через модуль скачки
  Future<void> installSockseek(void Function(String) log) async {
    final r = await _invoke({'kind': 'sockseek-install'}, log);
    if (!r.ok) throw Exception(r.error ?? 'Sockseek не установлен');
  }

  /// Путь к конфигу Soulseek; если файла нет, модуль создаёт шаблон
  Future<String> sockseekConfigPath() async {
    final r = await _invoke({'kind': 'sockseek-config'}, (_) {});
    if (!r.ok || r.value == null) throw Exception(r.error ?? 'модуль скачки не вернул путь к конфигу');
    return '${r.value}';
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

    final provider = lib.settings.downloadProvider;
    AppLog.info('Загрузчик: ${job.input}');
    try {
      final calls = _JobCalls(this, job, log);
      final r = await _invoke(
        {
          'kind': 'download',
          'input': job.input,
          'provider': provider,
          'folderName': job.folderName,
          'path': job.path,
          'makePlaylist': job.makePlaylist,
        },
        log,
        onProgress: (p) {
          job.title = '${p['title'] ?? job.title}';
          job.total = (p['total'] as num?)?.toInt() ?? job.total;
          job.done = (p['done'] as num?)?.toInt() ?? job.done;
          job.failed = (p['failed'] as num?)?.toInt() ?? job.failed;
          job.skipped = (p['skipped'] as num?)?.toInt() ?? job.skipped;
          _notify();
        },
        onCall: calls.handle,
      );
      job.state = r.ok ? JobState.done : JobState.failed;
      if (r.error != null) {
        log('Ошибка: ${r.error}');
        AppLog.warn('Загрузчик: ${job.input}', r.error);
      }
      if (job.done > 0 && !job.quiet) {
        lib.onEvent?.call({'k': 'upload', 'n': job.done, 'folder': job.folderName});
        lib.messages.add(provider == 'sockseek'
            ? 'Sockseek: добавлено треков — ${job.done} из ${job.total}'
            : 'Скачано и загружено на Диск: ${job.done} ${job.done == 1 ? 'трек' : 'треков'}');
      }
    } catch (e) {
      job.state = JobState.failed;
      log('Ошибка: $e');
      AppLog.warn('Загрузчик: ${job.input}', e);
    } finally {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}

/// Ответы на запросы модуля во время одного задания
class _JobCalls {
  final DownloadService service;
  final DownloadJob job;
  final void Function(String) log;
  _JobCalls(this.service, this.job, this.log);

  LibraryController get lib => service.lib;

  /// Подпапки альбомов: один запрос к Диску на имя, даже если треки качаются параллельно
  final Map<String, Future<String>> _folders = {};
  final Set<String> _folderIds = {};

  /// Треки, которые плеер сам назвал модулю: только их можно класть в плейлист
  final Set<String> _trackIds = {};

  Future<Object?> handle(String method, Map a) async {
    switch (method) {
      case 'existing':
        final have = lib.existing('${a['artist'] ?? ''}', '${a['title'] ?? ''}');
        if (have == null) return null;
        _trackIds.add(have.id);
        return {'id': have.id, 'artist': have.displayArtist, 'title': have.title};
      case 'folder':
        final folder = '${a['name'] ?? ''}'.trim();
        if (folder.isEmpty || folder.contains('/') || folder.contains(r'\')) throw ArgumentError('недопустимое имя папки: $folder');
        final folderId = await (_folders[folder] ??= lib.ensureSubfolder(job.sourceId, job.sourceId, folder));
        _folderIds.add(folderId);
        return folderId;
      case 'upload':
        final audio = _workFile(a['file']);
        final into = a['folderId'] == null ? job.target : '${a['folderId']}';
        if (into != job.target && !_folderIds.contains(into)) throw ArgumentError('неизвестная папка');
        final track = await lib.uploadOne(audio, sourceId: job.sourceId, folderId: into, path: '${a['path'] ?? job.path}');
        _trackIds.add(track.id);
        try {
          job.onTrack?.call(track);
        } catch (e) {
          AppLog.warn('Загрузчик: после загрузки', e);
        }
        return track.id;
      case 'playlist':
        final listName = '${a['name'] ?? ''}'.trim();
        if (listName.isEmpty) throw ArgumentError('пустое название плейлиста');
        final ids = [for (final x in (a['ids'] as List? ?? const [])) if (_trackIds.contains('$x')) '$x'];
        final made = addToNamedPlaylist(lib, listName, ids);
        job.playlistId = made.id;
        job.playlistName = listName;
        lib.messages.add(made.created ? 'Плейлист «$listName» создан' : 'Плейлист «$listName» дополнен');
        return {'id': made.id, 'created': made.created, 'added': made.added};
      case 'playlistCover':
        if (a['id'] != job.playlistId) throw ArgumentError('неизвестный плейлист');
        final image = _workFile(a['file']);
        final jpeg = await compressImage(await image.readAsBytes(), maxSide: 1000);
        lib.setPlaylistCover(job.playlistId!, await lib.uploadCover(jpeg, 'jpg'));
        return null;
      default:
        throw UnsupportedError('неизвестный запрос модуля: $method');
    }
  }

  /// Модуль может отдавать только свои временные файлы из рабочей папки
  File _workFile(Object? path) {
    final f = File('${path ?? ''}').absolute;
    final root = service.work.absolute.path;
    final p = f.path;
    final sep = Platform.pathSeparator;
    final inside = Platform.isWindows
        ? p.toLowerCase().startsWith('${root.toLowerCase()}$sep')
        : p.startsWith('$root$sep');
    if (!inside || p.split(RegExp(r'[\\/]')).contains('..')) throw ArgumentError('файл вне рабочей папки загрузчика');
    if (!f.existsSync()) throw ArgumentError('нет файла ${f.uri.pathSegments.last}');
    return f;
  }
}

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
