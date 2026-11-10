// Cavey Player owns the library, queue and Drive writes. All music extraction,
// service credentials and provider-specific logic live in Cavey-Downloader.exe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio_cache.dart';
import '../covers.dart';
import '../library.dart';
import '../log.dart';
import '../models.dart';
import '../upload_queue.dart';
import 'winproc.dart';

const kDownloaderProtocol = 3;
enum JobState { queued, running, done, failed, cancelled }

class DownloadJob {
  final String input, sourceId, folderName;
  final String? folderId, replaceTrackId;
  final String path;
  final bool quiet, makePlaylist;
  final void Function(Track)? onTrack;

  /// Докачка недостающих треков существующего альбома: всем скачанным трекам ставим его название и исполнителя альбома,
  /// чтобы они встали в него, а не создали второй альбом из-за мелких отличий в написании
  final String? intoAlbum, intoAlbumArtist;
  String title;
  JobState state = JobState.queued;
  bool cancelRequested = false;
  int total = 0, done = 0, failed = 0, skipped = 0;

  /// Скачано, но на Диск пока не загружено: файл лежит в очереди «Ожидают загрузки».
  /// Входит в [done] (скачивание удалось), в библиотеку попадёт позже
  int deferred = 0;
  final List<String> log = [];
  final List<String> failedNames = [];
  String? playlistId, playlistName;

  /// Когда в задании в последний раз что-то происходило (сообщение загрузчика, прогресс отправки на Диск).
  /// По нему сторож понимает, что задание зависло
  DateTime lastActivity = DateTime.now();

  /// Автоматические перезапуски по сторожу (не больше [DownloadService.maxAutoRestarts])
  int autoRestarts = 0;

  /// Идёт плановый перезапуск (сторож или кнопка «Перезапустить»); сдаваться после зависания
  bool restartRequested = false, giveUp = false;

  /// Сохранение обложки на Диск не отвечает: остальные треки этого задания сохраняем без своей обложки
  bool skipCovers = false;

  void touch() => lastActivity = DateTime.now();

  /// Нечего перезапускать у замены аудио и у служебных заданий
  bool get restartable => replaceTrackId == null && sourceId.isNotEmpty;

  DownloadJob(this.input, this.sourceId, this.folderName,
      {this.folderId, this.path = '', this.quiet = false, this.makePlaylist = true,
       this.onTrack, this.replaceTrackId, this.intoAlbum, this.intoAlbumArtist}) : title = input;

  String get target => folderId ?? sourceId;
  void add(String line) {
    log.add(line);
    if (log.length > 400) log.removeRange(0, log.length - 400);
  }
}

/// One active transfer owns its socket and the launched downloader process.
class _TransferSession {
  final DownloadJob job;
  Socket? socket;
  int? pid;
  bool killSent = false;
  final Completer<void> cancelled = Completer<void>();
  _TransferSession(this.job);
}

class DownloadService extends ChangeNotifier {
  final LibraryController lib;
  final Directory work;
  final AudioCache? cache;
  final CoverService? covers;
  final void Function(String id)? onAudioReplaced;
  final List<DownloadJob> jobs = [];
  bool _running = false;
  bool installing = false;
  String toolsVersion = '';
  bool spotifyBusy = false;
  bool spotifyConfigured = false;
  bool spotifyConnected = false;
  String spotifyAccount = '';
  String spotifyMessage = '';
  String spotifyError = '';
  Timer? _notifyTimer;
  _TransferSession? _activeTransfer;
  // Artwork belongs to a separate, bounded lane. A stalled Drive cover
  // upload must never hold the downloader's IPC metadata reply or audio queue.
  Future<void> _coverQueue = Future<void>.value();
  int _queuedCovers = 0;
  static const maxQueuedCovers = 16;

  DownloadService(this.lib, this.work, {this.cache, this.covers, this.onAudioReplaced});

  Directory get _toolsDir => Directory('${work.parent.path}${Platform.pathSeparator}tools');
  bool get busy => _running || installing || spotifyBusy;

  void _notify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 200), notifyListeners);
  }

  /// The release build ships this executable beside Cavey.exe. Developers may
  /// explicitly provide an independent module through CAVE_DOWNLOADER_EXE.
  File _module() {
    final override = Platform.environment['CAVE_DOWNLOADER_EXE'];
    if (override != null && override.trim().isNotEmpty) {
      final f = File(override).absolute;
      if (f.existsSync()) return f;
      throw StateError('CAVE_DOWNLOADER_EXE указывает на несуществующий файл: ${f.path}');
    }
    final dir = File(Platform.resolvedExecutable).parent;
    final file = File('${dir.path}${Platform.pathSeparator}cave-downloader-windows-x64.exe');
    if (file.existsSync()) return file;
    throw StateError('Cavey-Downloader.exe не найден рядом с плеером. '
        'Переустановите полную сборку Cavey или задайте CAVE_DOWNLOADER_EXE.');
  }

  DownloadJob? enqueue(String input, String sourceId,
      {String? folderId, String path = '', bool quiet = false,
       void Function(Track)? onTrack, bool makePlaylist = true, String? intoAlbum, String? intoAlbumArtist}) {
    final value = input.trim();
    if (value.isEmpty) return null;
    final source = lib.data.sources.where((s) => s.id == sourceId).firstOrNull;
    final job = DownloadJob(value, sourceId, source?.name ?? 'Cavey',
      folderId: folderId, path: path, quiet: quiet, onTrack: onTrack,
      makePlaylist: makePlaylist, intoAlbum: intoAlbum, intoAlbumArtist: intoAlbumArtist);
    jobs.insert(0, job);
    notifyListeners();
    unawaited(_pump());
    return job;
  }

  DownloadJob? enqueueReplacement(Track track) {
    if (track.artist.trim().isEmpty || track.title.trim().isEmpty) return null;
    if (jobs.any((j) => j.replaceTrackId == track.id &&
        (j.state == JobState.queued || j.state == JobState.running))) return null;
    final source = lib.data.sources.where((s) => s.id == track.source).firstOrNull;
    final job = DownloadJob('${track.artist} - ${track.title}', track.source,
        source?.name ?? 'Cavey', replaceTrackId: track.id, path: track.path);
    jobs.insert(0, job);
    notifyListeners();
    unawaited(_pump());
    return job;
  }

  final Set<String> _replacingFromFile = {};

  /// Идёт ли замена аудио трека файлом с компьютера
  bool isReplacingFromFile(String trackId) => _replacingFromFile.contains(trackId);

  /// Тип файла для Google Диска по расширению; пусто, если формат не из известных
  static String audioMime(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' || 'aac' || 'mp4' => 'audio/mp4',
      'ogg' || 'oga' || 'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      'wma' => 'audio/x-ms-wma',
      _ => '',
    };
  }

  /// «Перекачать из своего файла»: заменяет аудио трека файлом с компьютера в том же файле Google Диска.
  /// ID, ссылки, лайки, плейлисты и ручные метаданные сохраняются, как и при замене через загрузчик
  Future<bool> replaceFromFile(Track track, File file) async {
    if (!_replacingFromFile.add(track.id)) {
      lib.messages.add('«${track.title}» уже заменяется');
      return false;
    }
    try {
      if (!await file.exists() || await file.length() == 0) {
        lib.messages.add('Файл пустой или недоступен');
        return false;
      }
      lib.messages.add('Заменяю аудио «${track.title}»: загружаю файл на Google Диск…');
      Uint8List? oldArtwork;
      if (track.pic != null && track.cover == null && lib.customCoverOf(track) == null) {
        try {
          if (covers != null) oldArtwork = await covers!.forTrack(track, px: 0).timeout(const Duration(seconds: 20));
        } catch (_) {}
        if (oldArtwork != null && oldArtwork.length > 8 * 1024 * 1024) oldArtwork = null;
      }
      final email = await lib.accessFor(track.source);
      final meta = await lib.drive.getFile(email, track.id, fields: 'mimeType');
      final own = audioMime(file.path);
      await lib.replaceTrackAudio(track, file,
          mime: own.isNotEmpty ? own : ((meta['mimeType'] as String?) ?? 'application/octet-stream'));
      await cache?.invalidate(track.id);
      onAudioReplaced?.call(track.id);
      // Если в новом файле есть своя встроенная обложка, остаётся она; иначе сохраняем прежнюю
      if (lib.data.tracks[track.id]?.pic == null) await _preserveCover(track, oldArtwork, (m) => AppLog.warn(m));
      lib.messages.add('«${track.title}» заменён вашим файлом');
      return true;
    } catch (e, st) {
      AppLog.error('Замена аудио своим файлом', e, st);
      lib.messages.add('Не получилось заменить «${track.title}»: $e');
      return false;
    } finally {
      _replacingFromFile.remove(track.id);
    }
  }

  /// Stop a queued or active job without deleting already uploaded tracks.
  /// Cancellation applies to this job only, not the global download queue.
  void cancel(DownloadJob job) {
    if (job.state != JobState.queued && job.state != JobState.running) return;
    if (job.cancelRequested) return;
    job.cancelRequested = true;
    job.add('Отмена запрошена. Уже загруженные треки останутся в библиотеке.');
    if (job.state == JobState.queued) {
      job.state = JobState.cancelled;
    } else {
      final session = _activeTransfer;
      if (session != null && identical(session.job, job)) {
        if (!session.cancelled.isCompleted) session.cancelled.complete();
        session.socket?.destroy();
        unawaited(_killTransfer(session));
      }
    }
    notifyListeners();
  }

  /// Сколько задание может молчать, прежде чем сторож его перезапустит
  static const stallLimit = Duration(minutes: 3);
  static const maxAutoRestarts = 2;
  // Independent transport retries: brief localhost disconnects must not
  // discard a long playlist after a single successful resume.
  static const maxTransportRetries = 3;

  static bool isStalled(DateTime last, DateTime now, {Duration limit = stallLimit}) =>
      now.difference(last) >= limit;

  /// Рвёт связь с загрузчиком у активного задания (процесс и дочерние процессы убиваются);
  /// цикл в [_pump] увидит [DownloadJob.restartRequested] и запустит задание заново
  void _interrupt(DownloadJob job) {
    final s = _activeTransfer;
    if (s == null || !identical(s.job, job)) return;
    if (!s.cancelled.isCompleted) s.cancelled.complete();
    s.socket?.destroy();
    unawaited(_killTransfer(s));
  }

  void _checkStall(DownloadJob job) {
    if (job.state != JobState.running || job.cancelRequested || !job.restartable) return;
    if (!isStalled(job.lastActivity, DateTime.now())) return;
    job.touch();
    if (job.autoRestarts >= maxAutoRestarts) {
      job.giveUp = true;
      job.add('Нет прогресса ${stallLimit.inMinutes} мин, автоматические перезапуски закончились. '
          'Нажмите «Перезапустить», чтобы докачать недостающее.');
    } else {
      job.autoRestarts++;
      job.restartRequested = true;
      job.add('Нет прогресса ${stallLimit.inMinutes} мин — перезапускаю…');
    }
    _interrupt(job);
    notifyListeners();
  }

  /// «Перезапустить»: заново ставит в очередь только то, что ещё не скачано.
  /// Уже загруженные треки загрузчик находит в библиотеке и пропускает
  void restart(DownloadJob job) {
    if (!job.restartable) return;
    switch (job.state) {
      case JobState.queued:
        return;
      case JobState.running:
        if (job.cancelRequested) return;
        job.restartRequested = true;
        job.add('Перезапуск по кнопке: докачиваю только недоделанные треки.');
        _interrupt(job);
      case JobState.done:
      case JobState.failed:
      case JobState.cancelled:
        job
          ..state = JobState.queued
          ..cancelRequested = false
          ..restartRequested = false
          ..giveUp = false
          ..autoRestarts = 0
          ..skipCovers = false
          ..done = 0
          ..failed = 0
          ..deferred = 0
          ..skipped = 0
          ..failedNames.clear()
          ..touch();
        job.add('Перезапуск: скачиваю только то, чего ещё нет в библиотеке.');
        unawaited(_pump());
    }
    notifyListeners();
  }

  /// Ждёт [work], но не дольше, чем молчит прогресс: [last] возвращает время последнего движения
  Future<T> _idleLimit<T>(Future<T> work, DateTime Function() last, String what) {
    final c = Completer<T>();
    final timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!c.isCompleted && isStalled(last(), DateTime.now())) {
        c.completeError(TimeoutException('$what: нет прогресса ${stallLimit.inMinutes} мин'));
      }
    });
    work.then((v) {
      if (!c.isCompleted) c.complete(v);
    }, onError: (Object e, StackTrace st) {
      if (!c.isCompleted) c.completeError(e, st);
    });
    return c.future.whenComplete(timer.cancel);
  }

  Future<void> _killTransfer(_TransferSession session) async {
    final pid = session.pid;
    if (pid == null || session.killSent) return;
    session.killSent = true;
    try {
      // /T stops child processes launched by the module as well. A bare
      // socket close would leave Python and Soulseek running in the background.
      final result = await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      if (result.exitCode != 0) {
        AppLog.warn('Не удалось завершить дерево процессов загрузчика (PID $pid)',
            result.stderr.toString().trim());
      }
    } catch (e) {
      AppLog.warn('Не удалось остановить загрузчик (PID $pid)', e);
    }
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.state == JobState.done ||
        j.state == JobState.failed || j.state == JobState.cancelled);
    notifyListeners();
  }

  /// A reset localhost socket is a transport failure, not a missing song.
  /// Replaying a download job is safe because the downloader checks the library
  /// for existing tracks before each upload.
  static bool retryableDisconnect(Object error) =>
      error is SocketException ||
      (error is StateError &&
          error.toString().contains('Модуль отключился до завершения задания'));

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final job = jobs.reversed.where((j) => j.state == JobState.queued).firstOrNull;
        if (job == null) break;
        job.state = JobState.running;
        notifyListeners();
        try {
          Object? value;
          var restarts = 0;
          while (true) {
            Timer? watchdog;
            try {
              if (job.cancelRequested) throw StateError('Загрузка отменена');
              job.restartRequested = false;
              job.touch();
              watchdog = Timer.periodic(const Duration(seconds: 15), (_) => _checkStall(job));
              value = await _callModule(job.replaceTrackId == null ? 'download' : 'replace',
                  job: job, onLog: (s) { job.add(s); _notify(); });
              break;
            } catch (e, stack) {
              final planned = job.restartRequested && !job.giveUp;
              if (!job.cancelRequested && !planned) {
                AppLog.error('Связь с Cavey-Downloader при загрузке', e, stack);
              }
              if (job.cancelRequested || job.replaceTrackId != null || job.giveUp) rethrow;
              if (planned) {
                job.add('Запускаю задание заново: уже загруженные песни будут пропущены.');
              } else {
                if (restarts >= maxTransportRetries || !retryableDisconnect(e)) rethrow;
                restarts++;
                job.add('Локальное соединение с загрузчиком оборвалось '
                    '(попытка $restarts из $maxTransportRetries). '
                    'Продолжаю скачивание; уже добавленные песни пропускаю.');
              }
              _notify();
              // Give disconnected child processes time to release their
              // resources before starting the same large playlist again.
              await Future<void>.delayed(Duration(milliseconds: 600 * restarts.clamp(1, 5).toInt()));
            } finally {
              watchdog?.cancel();
            }
          }
          job.state = job.cancelRequested ? JobState.cancelled :
              (value == true ? JobState.done : JobState.failed);
          if (job.state == JobState.done && job.done > 0 && !job.quiet && job.replaceTrackId == null) {
            final added = job.done - job.deferred;
            if (added > 0) lib.onEvent?.call({'k': 'upload', 'n': added, 'folder': job.folderName});
            lib.messages.add(job.deferred == 0
                ? 'Скачано и добавлено в библиотеку: ${job.done}'
                : 'Скачано: ${job.done}. Загружено в библиотеку: $added, ждут загрузки: ${job.deferred}');
          }
        } catch (e) {
          job.state = job.cancelRequested ? JobState.cancelled : JobState.failed;
          if (!job.cancelRequested) job.add('Ошибка: $e');
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> refreshVersion() async {
    try { toolsVersion = '${await _callModule('tools-version')}'; }
    catch (_) { toolsVersion = 'модуль не установлен'; }
    notifyListeners();
  }

  Future<void> updateTools() async {
    if (busy) return;
    installing = true;
    final job = DownloadJob('Обновление инструментов', '', '')..state = JobState.running;
    jobs.insert(0, job);
    notifyListeners();
    try {
      await _callModule('tools-update', onLog: (s) { job.add(s); _notify(); });
      job.state = JobState.done;
    } catch (e) {
      job.state = JobState.failed;
      job.add('Ошибка: $e');
    } finally {
      installing = false;
      await refreshVersion();
    }
  }

  Future<void> refreshSpotify() async {
    if (spotifyBusy) return;
    try {
      final value = await _callModule('spotify-status');
      if (value is Map) {
        spotifyConfigured = value['configured'] == true;
        spotifyConnected = value['connected'] == true;
        spotifyAccount = '${value['account'] ?? ''}';
      }
      spotifyError = '';
    } catch (e) {
      spotifyError = 'Не удалось проверить Spotify: $e';
    }
    notifyListeners();
  }

  Future<void> loginSpotify(String clientId) async {
    if (busy) return;
    spotifyBusy = true;
    spotifyMessage = 'Открываю страницу входа Spotify…';
    spotifyError = '';
    notifyListeners();
    try {
      final result = await _callModule('spotify-login',
          extra: {'clientId': clientId.trim()}, onLog: (line) {
        spotifyMessage = line;
        notifyListeners();
      });
      spotifyAccount = '$result';
      spotifyConnected = true;
      spotifyConfigured = true;
      spotifyMessage = 'Spotify подключён: $spotifyAccount';
    } catch (e) {
      spotifyError = 'Spotify: $e';
      spotifyMessage = '';
    } finally {
      spotifyBusy = false;
      notifyListeners();
    }
  }

  Future<void> logoutSpotify() async {
    if (busy) return;
    spotifyBusy = true;
    spotifyError = '';
    notifyListeners();
    try {
      await _callModule('spotify-logout');
      spotifyConnected = false;
      spotifyAccount = '';
      spotifyMessage = 'Spotify отключён.';
    } catch (e) {
      spotifyError = 'Не удалось отключить Spotify: $e';
    } finally {
      spotifyBusy = false;
      notifyListeners();
    }
  }

  Future<void> installProvider(String provider, void Function(String) log) async {
    if (provider != 'deezer' && provider != 'sockseek') throw ArgumentError.value(provider);
    installing = true;
    notifyListeners();
    try {
      await _callModule('$provider-install', onLog: log);
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  Future<String> providerConfig(String provider) async {
    if (provider != 'deezer' && provider != 'sockseek') throw ArgumentError.value(provider);
    final path = await _callModule('$provider-config');
    if (path is! String || path.isEmpty) throw StateError('Модуль не вернул путь к конфигу.');
    return path;
  }

  /// Only accept files produced in this job's temporary directory.
  Future<File> _jobFile(Object? path, {bool image = false}) async {
    if (path is! String || path.trim().isEmpty) throw const FormatException('Не указан файл');
    final f = File(path);
    if (!await f.exists()) throw StateError('Модуль передал несуществующий файл.');
    final real = await f.resolveSymbolicLinks();
    final root = await work.resolveSymbolicLinks();
    final a = Platform.isWindows ? real.toLowerCase() : real;
    final base = Platform.isWindows ? root.toLowerCase() : root;
    if (!a.startsWith('$base${Platform.pathSeparator}')) {
      throw StateError('Модуль передал файл за пределами рабочей папки.');
    }
    if (!RegExp(
      image ? r'\.(png|jpg|jpeg|webp|img)$' : r'\.(mp3|flac|wav|m4a|aac|ogg|opus|webm)$',
      caseSensitive: false,
    ).hasMatch(real)) {
      throw const FormatException('Модуль передал неподдерживаемый формат файла.');
    }
    return File(real);
  }

  void _enqueueArtwork(DownloadJob job, String trackId, Uint8List bytes,
      String ext, void Function(String) log) {
    if (job.skipCovers) return;
    if (_queuedCovers >= maxQueuedCovers) {
      job.skipCovers = true;
      log('Deezer обложки: очередь Google Drive переполнена, '
          'для остальных треков задания сохраняю только метаданные и аудио.');
      return;
    }
    _queuedCovers++;
    _coverQueue = _coverQueue.then((_) async {
      if (job.skipCovers) return;
      try {
        final coverId = await lib.uploadCover(bytes, ext)
            .timeout(const Duration(seconds: 60));
        // The file may have been removed during a long upload.
        if (lib.data.tracks.containsKey(trackId)) {
          lib.setMeta({trackId: {'cv': coverId}});
          await covers?.seed(coverId, bytes);
        }
        log('Deezer обложка: сохранена на Google Drive и привязана к треку.');
      } on TimeoutException {
        job.skipCovers = true;
        log('Deezer обложка: Google Drive не ответил за 60 секунд. '
            'Очередь обложек остановлена, скачивание аудио продолжается.');
      } catch (e) {
        // Optional artwork must never interrupt a music download.
        log('Deezer обложка: не удалось сохранить ($e). '
            'Аудио и метаданные остались в библиотеке.');
      }
    }).catchError((Object e, StackTrace st) {
      AppLog.error('Необработанная ошибка очереди обложек', e, st);
    }).whenComplete(() {
      _queuedCovers--;
    });
  }

  Future<void> _preserveCover(Track original, Uint8List? bytes, void Function(String) log) async {
    if (bytes == null || bytes.isEmpty) return;
    try {
      final png = bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50;
      final id = await lib.uploadCover(bytes, png ? 'png' : 'jpg').timeout(const Duration(seconds: 60));
      lib.setMeta({original.id: {'cv': id}});
      await covers?.seed(id, bytes);
    } catch (e) { log('Аудио обновлено, но старую обложку сохранить не удалось: $e'); }
  }

  Future<Object?> _hostCall(DownloadJob? job, Map call, void Function(String) log) async {
    final method = '${call['m'] ?? ''}';
    if (job == null) throw const FormatException('Для этого запроса нужно задание');
    switch (method) {
      case 'existing':
        final t = lib.existing('${call['artist'] ?? ''}', '${call['title'] ?? ''}',
            album: '${call['album'] ?? ''}',
            duration: (call['duration'] as num?)?.toDouble());
        return t == null ? null : {'id': t.id, 'artist': t.artist, 'title': t.title};
      case 'folder':
        return lib.ensureSubfolder(job.sourceId, job.target, '${call['name'] ?? ''}');
      case 'upload':
        final f = await _jobFile(call['file']);
        final target = (call['folderId'] as String?) ?? job.target;
        var lastMove = DateTime.now();
        job.touch();
        try {
          final t = await _idleLimit(
              lib.uploadOne(f, sourceId: job.sourceId, folderId: target, path: '${call['path'] ?? job.path}',
                  uploadSource: lib.uploadSourceNow, onProgress: (_) {
                lastMove = DateTime.now();
                job.touch();
              }),
              () => lastMove,
              'Загрузка на Google Drive');
          job.onTrack?.call(t);
          return t.id;
        } on UploadDeferred catch (e) {
          // Файл скачан и сохранён в очереди; загрузчику сообщаем об успехе, а загрузка на Диск случится позже
          job.deferred++;
          job.add('Скачано, но не загружено на Диск: ${e.reason}');
          _notify();
          return '${UploadQueue.idPrefix}${e.pendingId}';
        }
      case 'enrich':
        final id = '${call['trackId'] ?? ''}';
        final track = lib.data.tracks[id];
        final waiting = id.startsWith(UploadQueue.idPrefix) ? lib.uploadQueue.byId(id) : null;
        if (waiting == null && (track == null || track.source != job.sourceId)) {
          throw const FormatException('Метаданные разрешены только для нового трека этого задания.');
        }
        final m = call['meta'];
        if (m is! Map) throw const FormatException('Некорректные метаданные.');
        String field(String name) {
          final value = '${m[name] ?? ''}'.trim();
          return value.length <= 300 ? value : value.substring(0, 300);
        }
        String? validNumber(String key) {
          final part = field(key).split('/').first.trim();
          final parsed = int.tryParse(part);
          return parsed != null && parsed > 0 && parsed < 1000 ? '$parsed' : null;
        }
        final edit = <String, String>{
          if (field('title').isNotEmpty) 't': field('title'),
          if (field('artist').isNotEmpty) 'a': field('artist'),
          if (field('album').isNotEmpty) 'al': field('album'),
          if (field('albumArtist').isNotEmpty) 'aa': field('albumArtist'),
          if (field('year').isNotEmpty) 'y': field('year'),
          if (validNumber('track') case final n?) 'n': n,
          if (validNumber('disc') case final d?) 'dn': d,
          if (m['duration'] is num && (m['duration'] as num) > 0)
            'd': '${((m['duration'] as num) * 1000).round()}',
        };
        if ((job.intoAlbum ?? '').isNotEmpty) {
          edit['al'] = job.intoAlbum!;
          if ((job.intoAlbumArtist ?? '').isNotEmpty) edit['aa'] = job.intoAlbumArtist!;
        }
        if (waiting != null) {
          // Трека на Диске ещё нет: метаданные применятся, когда файл выйдет из очереди «Ожидают загрузки»
          waiting.edit = edit;
          await lib.uploadQueue.update();
          log('Метаданные сохранены и применятся после загрузки трека на Диск.');
          return true;
        }
        // Persist metadata even if the image cannot be retrieved or uploaded.
        if (edit.isNotEmpty) lib.setMeta({id: edit});
        final imagePath = call['coverFile'];
        if (imagePath is String && imagePath.isNotEmpty) {
          if (job.skipCovers) {
            // A cover previously failed or the queue is full; never block
            // playback/download metadata on further Drive cover attempts.
            log('Deezer обложка: Google Drive медленный, '
                'сохраняю аудио и метаданные без отдельной обложки.');
          } else {
            try {
              final image = await _jobFile(imagePath, image: true);
              final bytes = await image.readAsBytes();
              final png = bytes.length >= 8 && bytes[0] == 0x89 &&
                  bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
              final jpeg = bytes.length >= 3 && bytes[0] == 0xFF &&
                  bytes[1] == 0xD8 && bytes[2] == 0xFF;
              if ((png || jpeg) && bytes.length <= 5 * 1024 * 1024) {
                _enqueueArtwork(job, id, bytes, png ? 'png' : 'jpg', log);
                // Return immediately: audio and tag IPC operations never await
                // an external Google Drive artwork upload.
              } else {
                log('Deezer: получена неподдерживаемая обложка, оставляю исходную.');
              }
            } catch (e) {
              log('Deezer обложка: файл недоступен ($e); аудио сохранено.');
            }
          }
        } else {
          log('Deezer обложка: загрузчик не передал изображение. '
              'Google Drive нечего сохранять.');
        }
        return true;
      case 'replace':
        final id = '${call['trackId'] ?? ''}';
        if (id.isEmpty || id != job.replaceTrackId) {
          throw const FormatException('Нельзя заменить другой трек.');
        }
        final track = lib.data.tracks[id];
        if (track == null) throw StateError('Трек для замены не найден.');
        final f = await _jobFile(call['file']);
        Uint8List? oldArtwork;
        if (track.pic != null && track.cover == null && lib.customCoverOf(track) == null) {
          log('Обложка: проверяю возможность сохранения исходной обложки');
          try {
            // Artwork is optional; a remote cover lookup must not block audio replacement.
            if (covers != null) {
              oldArtwork = await covers!.forTrack(track, px: 0)
                  .timeout(const Duration(seconds: 20));
            }
          } catch (_) {
            log('Обложка: исходное изображение недоступно, продолжаю замену');
          }
          if (oldArtwork != null && oldArtwork.length > 8 * 1024 * 1024) oldArtwork = null;
        }
        log('Google Drive: проверяю доступ к исходному файлу');
        final email = await lib.accessFor(track.source);
        final data = await lib.drive.getFile(email, id, fields: 'mimeType');
        var lastPercent = -5;
        await lib.replaceTrackAudio(track, f,
            mime: (data['mimeType'] as String?) ?? 'application/octet-stream',
            onProgress: (progress) {
              final percent = (progress * 100).floor().clamp(0, 100).toInt();
              if (percent < lastPercent + 5 && percent != 100) return;
              if (percent == lastPercent) return;
              lastPercent = percent;
              job.title = 'Google Drive: загрузка $percent%';
              log(job.title);
              _notify();
            },
            onStatus: (status) {
              job.title = status;
              log(status);
              _notify();
            });
        job.title = 'Google Drive: обновляю аудиокеш';
        log(job.title);
        _notify();
        await cache?.invalidate(track.id);
        onAudioReplaced?.call(track.id);
        if (oldArtwork != null && oldArtwork.isNotEmpty) {
          job.title = 'Google Drive: сохраняю исходную обложку';
          log(job.title);
          _notify();
        }
        await _preserveCover(track, oldArtwork, log);
        job.title = 'Замена аудио завершена';
        log(job.title);
        _notify();
        lib.messages.add('«${track.title}» перекачан без создания дубля');
        return id;
      case 'playlist':
        final ids = (call['ids'] as List? ?? const []).map((x) => '$x').toList();
        final result = addToNamedPlaylist(lib, '${call['name'] ?? ''}', ids);
        job.playlistId = result.id;
        job.playlistName = '${call['name'] ?? ''}';
        return {'id': result.id, 'created': result.created, 'added': result.added};
      case 'playlistCover':
        final path = call['file'];
        final f = await _jobFile(path, image: true);
        final bytes = await f.readAsBytes();
        final png = bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50;
        final id = await lib.uploadCover(bytes, png ? 'png' : 'jpg').timeout(const Duration(seconds: 60));
        final playlistId = '${call['id'] ?? ''}';
        if (playlistId.isEmpty) throw const FormatException('Не указан плейлист.');
        lib.setPlaylistCover(playlistId, id);
        await covers?.seed(id, bytes);
        return true;
      default:
        throw FormatException('Неподдерживаемая команда модуля: $method');
    }
  }

  Future<Object?> _callModule(String kind, {DownloadJob? job,
      void Function(String)? onLog, Map<String, Object?>? extra}) async {
    final exe = _module();
    await work.create(recursive: true);
    await _toolsDir.create(recursive: true);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final token = base64UrlEncode(bytes);
    final address = '127.0.0.1:${server.port}';
    final args = ['serve', '--connect', address, '--token', token];
    Socket? socket;
    Future<int>? moduleExit;
    // Keep consuming IPC messages even while Google Drive is uploading a file.
    // Replies stay ordered, but socket reads never wait for an upload.
    Future<void> replyQueue = Future<void>.value();
    // Two independent lanes keep the IPC reader free while files upload.
    final uploadLanes = <Future<void>>[Future<void>.value(), Future<void>.value()];
    var nextUploadLane = 0;
    var socketAlive = true;
    var receivedEnd = false;
    final session = job == null ? null : _TransferSession(job);
    if (session != null) _activeTransfer = session;
    try {
      if (job?.cancelRequested == true) throw StateError('Загрузка отменена');
      if (Platform.isWindows) {
        moduleExit = WinProc.run(exe.path, args, (line) {
          // Surface only the downloader's explicit IPC/operation diagnostics.
          // These errors used to disappear because all process output was ignored.
          final message = line.trim();
          if (message.startsWith('Cavey-Downloader:')) onLog?.call(message);
        },
          onStarted: (pid) {
            if (session == null) return;
            session.pid = pid;
            if (session.job.cancelRequested) unawaited(_killTransfer(session));
          },
        ).then((code) {
          if (code != 0 && job?.cancelRequested != true) {
            onLog?.call('Cavey-Downloader завершился с кодом $code.');
          }
          return code;
        }).catchError((Object e) {
          if (job?.cancelRequested != true) {
            onLog?.call('Ошибка запуска Cavey-Downloader: ${e.runtimeType}');
          }
          return -1;
        });
      } else {
        final p = await Process.start(exe.path, args);
        unawaited(p.stdout.drain<void>());
        unawaited(p.stderr.drain<void>());
        unawaited(p.exitCode);
      }
      // Cancellation must unblock even if the helper process has not yet
      // connected. Otherwise ServerSocket.first could wait for 40 seconds.
      socket = session == null
          ? await server.first.timeout(const Duration(seconds: 40))
          : await Future.any<Socket?>([
              server.first.timeout(const Duration(seconds: 40)),
              session.cancelled.future.then<Socket?>((_) => null),
            ]);
      if (socket == null) throw StateError('Загрузка отменена');
      if (session != null) {
        session.socket = socket;
        if (session.job.cancelRequested) socket.destroy();
      }
      final reader = StreamIterator<String>(
        socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      if (!await reader.moveNext().timeout(const Duration(seconds: 20))) {
        throw StateError('Модуль не подтвердил подключение.');
      }
      final hello = jsonDecode(reader.current);
      if (hello is! Map || hello['t'] != 'hello' ||
          hello['token'] != token || hello['protocol'] != kDownloaderProtocol) {
        socket.write('${jsonEncode({'t': 'error', 'error': 'Несовместимая версия модуля'})}\n');
        throw StateError('Требуется Cavey-Downloader с протоколом $kDownloaderProtocol.');
      }
      final request = <String, Object?>{
        't': 'job', 'kind': kind, 'endAck': true,
        ...?extra,
        'tools': _toolsDir.absolute.path,
        'work': work.absolute.path,
        if (job != null) ...{
          'input': job.input, 'provider': lib.settings.downloadProvider,
          'folderName': job.folderName, 'path': job.path,
          'makePlaylist': job.makePlaylist,
        },
      };
      if (job?.replaceTrackId != null) {
        final t = lib.data.tracks[job!.replaceTrackId];
        if (t == null) throw StateError('Трек удалён из библиотеки.');
        final email = await lib.accessFor(t.source);
        final detail = await lib.drive.getFile(email, t.id, fields: 'name');
        final name = '${detail['name'] ?? ''}';
        final dot = name.lastIndexOf('.');
        request.addAll({
          'replaceTrackId': t.id,
          'originalExt': dot < 0 ? '' : name.substring(dot),
          'artist': t.artist, 'requestedTitle': t.title,
          'album': t.album, 'albumArtist': t.albumArtist,
          'year': t.year, 'trackNumber': t.no?.toString() ?? '',
          'duration': t.durationMs == null ? null : t.durationMs! / 1000,
        });
      }
      socket.write('${jsonEncode(request)}\n');
      Future<void> replyToCall(Map call) async {
        if (!socketAlive || job?.cancelRequested == true) return;
        Map<String, Object?> reply;
        try {
          final value = await _hostCall(job, call, onLog ?? (_) {});
          reply = {'t': 'reply', 'id': call['id'], 'ok': true, 'value': value};
        } catch (e) {
          reply = {'t': 'reply', 'id': call['id'], 'ok': false, 'error': '$e'};
        }
        job?.touch();
        if (!socketAlive || job?.cancelRequested == true) return;
        try {
          socket!.write('${jsonEncode(reply)}\n');
          await socket!.flush();
        } on SocketException catch (e) {
          onLog?.call('IPC: ответ на ${call['m']} не доставлен: $e');
          socketAlive = false;
          socket?.destroy();
        }
      }

      void transportFailed(Object e, StackTrace stack) {
        AppLog.error('Ошибка очереди IPC-ответов', e, stack);
        if (!socketAlive) return;
        onLog?.call('IPC: ошибка обработки запроса: ${e.runtimeType}. '
            'Соединение закрыто для безопасного восстановления задания.');
        socketAlive = false;
        socket?.destroy();
      }

      while (await reader.moveNext()) {
        final msg = jsonDecode(reader.current);
        if (msg is! Map) continue;
        switch (msg['t']) {
          case 'log':
            job?.touch();
            onLog?.call('${msg['text'] ?? ''}');
          case 'progress':
            if (job != null) {
              job.touch();
              // Liveness messages are not track progress. Skip UI rebuilds.
              if (msg['heartbeat'] == true) break;
              // The downloader's old status must not overwrite Drive progress.
              if (job.replaceTrackId == null || !job.title.startsWith('Google Drive:')) {
                job.title = '${msg['title'] ?? job.title}';
              }
              job.total = (msg['total'] as num?)?.toInt() ?? job.total;
              job.done = (msg['done'] as num?)?.toInt() ?? job.done;
              job.failed = (msg['failed'] as num?)?.toInt() ?? job.failed;
              job.skipped = (msg['skipped'] as num?)?.toInt() ?? job.skipped;
              _notify();
            }
          case 'heartbeat':
            // Heartbeats mark a healthy connection, not a completed track.
            job?.touch();
          case 'installing':
            installing = msg['on'] == true;
            _notify();
          case 'call':
            final call = msg;
            if (call['m'] == 'upload') {
              // Caller matches out-of-order responses by id.
              final slot = nextUploadLane++ % uploadLanes.length;
              uploadLanes[slot] = uploadLanes[slot]
                  .then((_) => replyToCall(call))
                  .catchError((Object e, StackTrace stack) => transportFailed(e, stack));
            } else {
              replyQueue = replyQueue
                  .then((_) => replyToCall(call))
                  .catchError((Object e, StackTrace stack) => transportFailed(e, stack));
            }
          case 'end':
            receivedEnd = true;
            // The module may call exit() immediately after returning from
            // serve(). Confirm receiving the final message before it exits.
            await Future.wait([replyQueue, ...uploadLanes]);
            try {
              socket!.write('${jsonEncode({'t': 'end-ack'})}\n');
              await socket!.flush();
            } on SocketException catch (e) {
              // Old downloaders do not wait for an acknowledgement. Receiving
              // their end event still means that the job completed.
              AppLog.warn('IPC: подтверждение итога не доставлено', e);
            }
            if (msg['ok'] != true) throw StateError('${msg['error'] ?? 'Не удалось выполнить задание'}');
            return msg['value'] ?? true;
        }
      }
      if (!receivedEnd && job?.cancelRequested != true) {
        onLog?.call('IPC: сокет закрыт до получения финального ответа загрузчика.');
      }
      throw StateError('Модуль отключился до завершения задания.');
    } catch (e) {
      var processUnfinished = false;
      if (job?.cancelRequested != true && moduleExit != null) {
        // Distinguish a helper crash from a peer socket reset. WinProc can
        // outlive the socket while its child processes still hold stdout.
        try {
          final code = await moduleExit!.timeout(const Duration(seconds: 2));
          onLog?.call('Диагностика: Cavey-Downloader exit code $code, IPC: ${e.runtimeType}');
        } on TimeoutException {
          processUnfinished = true;
          onLog?.call('Диагностика: соединение оборвано, но процесс '
              'Cavey-Downloader ещё выполняется (или ждёт дочерний процесс).');
        }
      }
      // On a transport failure, stop orphaned Python/Soulseek children before
      // the job is restarted; otherwise two old and new pipelines compete.
      // Normal end/error messages are not process transport failures.
      if (!receivedEnd && processUnfinished && session != null &&
          job?.cancelRequested != true) {
        onLog?.call('IPC: завершаю оставшиеся подпроцессы перед повторной попыткой.');
        await _killTransfer(session);
      }
      rethrow;
    } finally {
      socketAlive = false;
      if (session != null && identical(_activeTransfer, session)) {
        _activeTransfer = null;
      }
      if (socket != null) {
        if (receivedEnd) {
          // Allow the peer to receive end-ack. Immediate destroy() can send
          // an RST and make a completed download appear to have crashed.
          try {
            await socket.close().timeout(const Duration(seconds: 5));
          } catch (_) {
            socket.destroy();
          }
        } else {
          socket.destroy();
        }
      }
      await server.close();
      installing = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}

class NamedPlaylistResult {
  final String id;
  final bool created;
  final int added;
  const NamedPlaylistResult(this.id, this.created, this.added);
}

NamedPlaylistResult addToNamedPlaylist(
    LibraryController lib, String name, List<String> trackIds) {
  final me = lib.me ?? '';
  final key = name.trim().toLowerCase();
  final same = lib.data.playlists.where((p) =>
      (p.by.isEmpty || p.by == me) && p.name.trim().toLowerCase() == key).firstOrNull;
  if (same == null) {
    return NamedPlaylistResult(lib.createPlaylist(name.trim(), trackIds),
        true, trackIds.length);
  }
  final have = same.items.toSet();
  final fresh = [for (final t in trackIds) if (!have.contains(t)) t];
  if (fresh.isNotEmpty) lib.addToPlaylist(same.id, fresh);
  return NamedPlaylistResult(same.id, false, fresh.length);
}
