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
import 'winproc.dart';

const kDownloaderProtocol = 3;
enum JobState { queued, running, done, failed, cancelled }

class DownloadJob {
  final String input, sourceId, folderName;
  final String? folderId, replaceTrackId;
  final String path;
  final bool quiet, makePlaylist;
  final void Function(Track)? onTrack;
  String title;
  JobState state = JobState.queued;
  bool cancelRequested = false;
  int total = 0, done = 0, failed = 0, skipped = 0;
  final List<String> log = [];
  final List<String> failedNames = [];
  String? playlistId, playlistName;

  DownloadJob(this.input, this.sourceId, this.folderName,
      {this.folderId, this.path = '', this.quiet = false, this.makePlaylist = true,
       this.onTrack, this.replaceTrackId}) : title = input;

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
  Timer? _notifyTimer;
  _TransferSession? _activeTransfer;

  DownloadService(this.lib, this.work, {this.cache, this.covers, this.onAudioReplaced});

  Directory get _toolsDir => Directory('${work.parent.path}${Platform.pathSeparator}tools');
  bool get busy => _running || installing;

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
       void Function(Track)? onTrack, bool makePlaylist = true}) {
    final value = input.trim();
    if (value.isEmpty) return null;
    final source = lib.data.sources.where((s) => s.id == sourceId).firstOrNull;
    final job = DownloadJob(value, sourceId, source?.name ?? 'Cavey',
      folderId: folderId, path: path, quiet: quiet, onTrack: onTrack,
      makePlaylist: makePlaylist);
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
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              if (job.cancelRequested) throw StateError('Загрузка отменена');
              value = await _callModule(job.replaceTrackId == null ? 'download' : 'replace',
                  job: job, onLog: (s) { job.add(s); _notify(); });
              break;
            } catch (e, stack) {
              if (!job.cancelRequested) {
                AppLog.error('Связь с Cavey-Downloader при загрузке', e, stack);
              }
              if (job.cancelRequested || attempt > 0 || job.replaceTrackId != null ||
                  !retryableDisconnect(e)) rethrow;
              job.add('Локальное соединение с загрузчиком оборвалось. '
                  'Перезапускаю задание один раз; уже добавленные песни будут пропущены.');
              _notify();
              await Future<void>.delayed(const Duration(milliseconds: 700));
            }
          }
          job.state = job.cancelRequested ? JobState.cancelled :
              (value == true ? JobState.done : JobState.failed);
          if (job.state == JobState.done && job.done > 0 && !job.quiet && job.replaceTrackId == null) {
            lib.onEvent?.call({'k': 'upload', 'n': job.done, 'folder': job.folderName});
            lib.messages.add('Скачано и добавлено в библиотеку: ${job.done}');
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

  Future<void> _preserveCover(Track original, Uint8List? bytes, void Function(String) log) async {
    if (bytes == null || bytes.isEmpty) return;
    try {
      final png = bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50;
      final id = await lib.uploadCover(bytes, png ? 'png' : 'jpg');
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
        final t = await lib.uploadOne(f, sourceId: job.sourceId,
            folderId: target, path: '${call['path'] ?? job.path}');
        job.onTrack?.call(t);
        return t.id;
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
        final id = await lib.uploadCover(bytes, png ? 'png' : 'jpg');
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
      void Function(String)? onLog}) async {
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
        socketAlive = false;
        socket?.destroy();
      }

      while (await reader.moveNext()) {
        final msg = jsonDecode(reader.current);
        if (msg is! Map) continue;
        switch (msg['t']) {
          case 'log':
            onLog?.call('${msg['text'] ?? ''}');
          case 'progress':
            if (job != null) {
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
      socket?.destroy();
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
