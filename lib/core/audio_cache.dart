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
    enqueue(t.id, front: true);
  }

  void enqueue(String id, {bool front = false}) {
    if (_have.contains(id) || _active.contains(id) || _failed.contains(id)) return;
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
      _have.add(id);
      sizeBytes += await f.length();
      await _evict();
    } catch (e) {
      _failed.add(id); // не пытаемся снова до перезапуска
      AppLog.warn('Не удалось сохранить «${t.title}» в кэш', e);
    }
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
  Future<void> _evict() async {
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
    notifyListeners();
  }
}
