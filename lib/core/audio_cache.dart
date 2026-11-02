// Кэш аудио на диске. Каждый прослушанный трек докачивается целиком в фоне,
// и в следующий раз играет с диска — мгновенно и без интернета. «Любимое»
// и плейлисты, отмеченные для офлайна, скачиваются заранее и не вытесняются.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'store.dart';

class AudioCache extends ChangeNotifier {
  final Directory dir;
  final DriveApi drive;
  final LibraryController lib;
  final Settings settings;

  final Set<String> _have = {};
  final List<String> _queue = [];
  final Set<String> _active = {};
  final Set<String> _failed = {};
  final Map<String, int> _failureCount = {};
  final Map<String, DateTime> _retryAt = {};
  Timer? _retryTimer;
  Future<void> _evictFuture = Future<void>.value();
  final Set<String> _invalidateAfterDownload = {};
  int sizeBytes = 0;
  Timer? _pinTimer;

  AudioCache(this.dir, this.drive, this.lib, this.settings);

  File fileFor(String id) => File('${dir.path}${Platform.pathSeparator}$id.audio');
  bool has(String id) => _have.contains(id);
  bool isDownloading(String id) => _active.contains(id) || _queue.contains(id);
  int get pending => _queue.length + _active.length;

  Future<void> init() async {
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.audio')) {
          final name = e.uri.pathSegments.last;
          _have.add(name.substring(0, name.length - 6));
          sizeBytes += await e.length();
        } else if (e is File && e.path.endsWith('.part')) {
          await e.delete();
        }
      }
    } catch (e) {
      AppLog.warn('Не удалось прочитать кэш', e);
    }
    lib.addListener(_schedulePinSync);
    _schedulePinSync();
  }

  /// Трек начал играть: отмечаем использование и докачиваем, если его ещё нет
  void touch(Track t) {
    final f = fileFor(t.id);
    if (_have.contains(t.id)) {
      try {
        f.setLastModifiedSync(DateTime.now());
      } catch (_) {}
      return;
    }
    // A direct play request should retry now instead of waiting for backoff.
    _failed.remove(t.id);
    _retryAt.remove(t.id);
    _failureCount.remove(t.id);
    enqueue(t.id, front: true);
  }

  void enqueue(String id, {bool front = false}) {
    if (_have.contains(id) || _active.contains(id) || _failed.contains(id)) return;
    final retry = _retryAt[id];
    if (retry != null && DateTime.now().isBefore(retry)) return;
    _queue.remove(id);
    if (front) {
      _queue.insert(0, id);
    } else {
      _queue.add(id);
    }
    _pump();
    notifyListeners();
  }

  void _pump() {
    while (_active.length < 2 && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _active.add(id);
      unawaited(_download(id).whenComplete(() {
        _active.remove(id);
        notifyListeners();
        _pump();
      }));
    }
  }

  Future<void> _download(String id) async {
    final t = lib.data.tracks[id];
    if (t == null) return;
    try {
      final email = await lib.accessFor(t.source);
      final f = fileFor(id);
      await drive.downloadToFile(email, id, f);
      if (_invalidateAfterDownload.remove(id)) {
        // A replacement completed while the old bytes were being cached.
        if (await f.exists()) await f.delete();
        return;
      }
      _have.add(id);
      _failed.remove(id);
      _failureCount.remove(id);
      _retryAt.remove(id);
      sizeBytes += await f.length();
      await _evict();
    } catch (e) {
      _failed.add(id);
      final failures = (_failureCount[id] ?? 0) + 1;
      _failureCount[id] = failures;
      // После временного сбоя сети пробуем снова без перезапуска приложения.
      // После 6 попыток ждём явного воспроизведения или изменения библиотеки.
      if (failures < 6) {
        final seconds = (5 * (1 << (failures - 1))).clamp(5, 160).toInt();
        _retryAt[id] = DateTime.now().add(Duration(seconds: seconds));
        _scheduleRetry();
      }
      AppLog.warn('Не удалось сохранить «${t.title}» в кэш', e);
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_retryAt.isEmpty) return;
    final next = _retryAt.values.reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = next.difference(DateTime.now());
    _retryTimer = Timer(wait > Duration.zero ? wait : Duration.zero, () {
      final now = DateTime.now();
      final ready = [for (final item in _retryAt.entries) if (!item.value.isAfter(now)) item.key];
      for (final id in ready) {
        _retryAt.remove(id);
        _failed.remove(id);
        enqueue(id);
      }
      _scheduleRetry();
    });
  }

  /// Audio was replaced in Drive under the same ID: cached bytes are now stale.
  Future<void> invalidate(String id) async {
    _queue.remove(id);
    _failed.remove(id);
    _failureCount.remove(id);
    _retryAt.remove(id);
    _scheduleRetry();
    if (!_active.contains(id)) {
      final f = fileFor(id);
      try {
        if (await f.exists()) {
          final length = await f.length();
          await f.delete();
          sizeBytes -= length;
        }
      } catch (e) {
        // Windows may lock a currently playing file. Remote replacement already
        // succeeded; never turn that success into a failed IPC operation.
        AppLog.warn('Аудиокэш: старый файл занят, удалю позже', e);
      }
      _have.remove(id);
    } else {
      // Drop the in-flight old copy once it finishes.
      _invalidateAfterDownload.add(id);
      _have.remove(id);
    }
    notifyListeners();
  }

  // ---------- офлайн ----------

  Set<String> get pinnedIds {
    final ids = <String>{};
    if (settings.offlineLiked) ids.addAll(lib.liked.map((t) => t.id));
    for (final p in settings.offlinePlaylists) {
      ids.addAll(lib.playlistTracks(p).map((t) => t.id));
    }
    return ids;
  }

  bool isPlaylistOffline(String id) => settings.offlinePlaylists.contains(id);

  Future<void> setPlaylistOffline(String id, bool on) async {
    if (on) {
      settings.offlinePlaylists.add(id);
    } else {
      settings.offlinePlaylists.remove(id);
    }
    await lib.saveSettings();
    _schedulePinSync();
    notifyListeners();
  }

  Future<void> setLikedOffline(bool on) async {
    settings.offlineLiked = on;
    await lib.saveSettings();
    _schedulePinSync();
    notifyListeners();
  }

  /// Сколько треков набора уже на диске
  int countCached(Iterable<Track> tracks) => tracks.where((t) => _have.contains(t.id)).length;

  void _schedulePinSync() {
    _pinTimer?.cancel();
    _pinTimer = Timer(const Duration(seconds: 3), () {
      for (final id in pinnedIds) {
        if (!_have.contains(id)) enqueue(id);
      }
    });
  }

  // ---------- размер ----------

  int get limitBytes => settings.cacheLimitMb * 1024 * 1024;

  Future<void> setLimit(int mb) async {
    settings.cacheLimitMb = mb;
    await lib.saveSettings();
    await _evict();
    notifyListeners();
  }

  /// Удаляет давно не игравшие треки, пока кэш не влезет в лимит
  Future<void> _evict() {
    final next = _evictFuture.then((_) => _evictNow());
    _evictFuture = next.catchError((Object _) {});
    return next;
  }

  Future<void> _evictNow() async {
    if (sizeBytes <= limitBytes) return;
    final pinned = pinnedIds;
    final files = <(File, DateTime, int)>[];
    for (final id in _have) {
      if (pinned.contains(id)) continue;
      final f = fileFor(id);
      try {
        files.add((f, f.lastModifiedSync(), f.lengthSync()));
      } catch (_) {}
    }
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _, len) in files) {
      if (sizeBytes <= limitBytes) break;
      try {
        await f.delete();
        final name = f.uri.pathSegments.last;
        _have.remove(name.substring(0, name.length - 6));
        sizeBytes -= len;
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Очищает всё, кроме сохранённого для офлайна
  Future<void> clear() async {
    final pinned = pinnedIds;
    for (final id in List.of(_have)) {
      if (pinned.contains(id)) continue;
      final f = fileFor(id);
      try {
        final len = await f.length();
        await f.delete();
        _have.remove(id);
        sizeBytes -= len;
      } catch (_) {}
    }
    _failed.clear();
    _failureCount.clear();
    _retryAt.clear();
    _scheduleRetry();
    notifyListeners();
  }

  @override
  void dispose() {
    _pinTimer?.cancel();
    _retryTimer?.cancel();
    lib.removeListener(_schedulePinSync);
    super.dispose();
  }
}
