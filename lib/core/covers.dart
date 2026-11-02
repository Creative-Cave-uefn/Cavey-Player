import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'deezer_art.dart';
import 'drive.dart';
import 'log.dart';
import 'image_tools.dart';
import 'library.dart';
import 'models.dart';

/// Обложки: из cover.jpg рядом с треком или из тегов (догружаем только нужный
/// кусок файла). Кэшируются в памяти и на диске, чтобы не качать повторно.
///
/// Рядом с оригиналом на диске лежат уменьшенные копии (160 и 640 px): списки читают маленькую,
/// она открывается мгновенно и после перезапуска. Когда картинка догрузилась, сервис оповещает
/// виджеты, и они обновляются сами, без смены вкладки.
class CoverService extends ChangeNotifier {
  final DriveApi drive;
  final LibraryController lib;
  final Directory dir;

  final Map<String, Uint8List?> _mem = {};
  int _memoryBytes = 0;
  static const int _memoryLimitBytes = 48 * 1024 * 1024;
  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, Future<Uint8List?>> _originalInflight = {};
  final Map<String, Future<DeezerArtwork?>> _albumLookupInflight = {};
  final Set<String> _savingDeezer = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  int _active = 0;
  final List<Completer<void>> _waiting = [];
  bool _notifyQueued = false;

  CoverService(this.drive, this.lib, this.dir);

  static String _key(Track t) => t.cover ?? 'p_${t.id}';

  /// Какой размер копии нужен для картинки в [px] физических пикселей: 160, 640 или 0 (оригинал)
  static int bucketFor(int px) => px <= 0 ? 0 : (px <= 200 ? 160 : (px <= 720 ? 640 : 0));

  /// A newly imported song may contain no APIC, cover.jpg or saved artwork.
  /// Public catalog lookup is an optional last resort, never required to play.
  static bool canFindInDeezer(Track t) =>
      t.artist.trim().isNotEmpty &&
      (t.album.trim().isNotEmpty || t.title.trim().isNotEmpty);

  /// Ключ картинки трека: загруженная обложка (альбома или трека) важнее обложки из файла
  String keyOf(Track t) {
    final c = lib.customCoverOf(t);
    return c != null ? 'cv_$c' : _key(t);
  }

  String _mk(String key, int bucket) => bucket == 0 ? key : '$key@$bucket';

  /// Уже загруженная картинка — чтобы не мигать при перерисовке. Подойдёт и копия побольше
  Uint8List? _touch(String key) {
    if (!_mem.containsKey(key)) return null;
    final bytes = _mem.remove(key);
    _mem[key] = bytes; // последняя использованная запись — в конце LRU
    return bytes;
  }

  /// Requested size first, then available larger/smaller previews.
  /// A fullscreen view can display the small cached image instantly, while
  /// forTrack/forFile independently upgrade it to full resolution.
  static List<int> previewBucketPriority(int px) => switch (bucketFor(px)) {
    160 => const [160, 640, 0],
    640 => const [640, 0, 160],
    _ => const [0, 640, 160],
  };

  Uint8List? _peekKey(String key, int px) {
    for (final bucket in previewBucketPriority(px)) {
      final cached = _touch(_mk(key, bucket));
      if (cached != null) return cached;
    }
    return null;
  }

  /// Distinguish a placeholder-quality thumbnail from the requested size,
  /// so a cinema/fullscreen view continues upgrading it to the original.
  bool hasExact(Track t, {int px = 0}) {
    final cover = lib.customCoverOf(t);
    final key = cover == null ? _key(t) : 'cv_$cover';
    return _mem[_mk(key, bucketFor(px))] != null;
  }

  bool hasExactFile(String fileId, {int px = 0}) =>
      _mem[_mk('cv_$fileId', bucketFor(px))] != null;

  void _remember(String key, Uint8List? bytes) {
    final previous = _mem.remove(key);
    _memoryBytes -= previous?.length ?? 0;
    _mem[key] = bytes;
    _memoryBytes += bytes?.length ?? 0;
    while ((_memoryBytes > _memoryLimitBytes || _mem.length > 700) && _mem.length > 1) {
      final oldest = _mem.keys.first;
      final removed = _mem.remove(oldest);
      _memoryBytes -= removed?.length ?? 0;
    }
  }

  Uint8List? peek(Track t, {int px = 0}) {
    final c = lib.customCoverOf(t);
    if (c != null) return peekFile(c, px: px);
    return (t.hasCover || canFindInDeezer(t)) ? _peekKey(_key(t), px) : null;
  }

  Uint8List? peekFile(String fileId, {int px = 0}) => _peekKey('cv_$fileId', px);

  /// Картинку трека ещё предстоит загрузить (есть обложка, но в памяти её нет)
  bool wants(Track t) => lib.customCoverOf(t) != null || t.hasCover || canFindInDeezer(t);

  Future<Uint8List?> forTrack(Track t, {int px = 0}) {
    final c = lib.customCoverOf(t);
    if (c != null) return forFile(c, px: px);
    final key = _key(t);
    if (!t.hasCover) return canFindInDeezer(t)
        ? _get(key, px, () => _deezerCover(t))
        : Future.value(null);
    return _get(key, px, () async {
      try {
        final email = await lib.accessFor(t.source);
        final pic = t.pic;
        final Uint8List? bytes = t.cover != null
            ? await drive.download(email, t.cover!)
            : pic != null
                ? await drive.readRange(email, t.id, pic.offset, pic.offset + pic.length - 1)
                : null;
        if (bytes != null && await _validImage(bytes)) return bytes;
        AppLog.info('Обложка: встроенное изображение ${t.id} не читается, пробую Deezer');
      } catch (e) {
        AppLog.warn('Обложка: ошибка чтения изображения ${t.id}; ищу резервную', e);
      }
      return canFindInDeezer(t) ? _deezerCover(t) : null;
    });
  }

  /// Detect an image before caching it, not just a successful HTTP response.
  /// Drive can return an MP3 body when an unsupported Range is ignored.
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length < 16 || bytes.length > 24 * 1024 * 1024) return false;
    final b = bytes;
    return (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) ||
        (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
            b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) ||
        (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) ||
        (b[0] == 0x42 && b[1] == 0x4d);
  }

  Future<bool> _validImage(Uint8List bytes) async {
    if (!looksLikeImage(bytes)) return false;
    try {
      return await DeezerArt.dimensionsInBackground(bytes)
          .timeout(const Duration(seconds: 5)) != null;
    } catch (_) {
      return false;
    }
  }

  /// Resolve a high-resolution image when the source file itself contains
  /// only a small embedded cover. The existing picture is still shown while
  /// a verified Deezer match is retrieved.
  Future<Uint8List?> forFullscreen(Track t) async {
    final original = await forTrack(t, px: 0);
    if (!canFindInDeezer(t) || lib.customCoverOf(t) != null) return original;
    if (original != null && original.isNotEmpty) {
      try {
        final dims = await DeezerArt.dimensionsInBackground(original)
            .timeout(const Duration(seconds: 4));
        if (dims != null && dims.$1 >= 900 && dims.$2 >= 900) return original;
        final artwork = await _findDeezer(t);
        if (artwork == null || (dims != null &&
            !artwork.betterThan(dims.$1, dims.$2))) return original;
        _saveFoundCover(t, artwork.bytes);
        return artwork.bytes;
      } catch (e) {
        AppLog.info('Fullscreen artwork: не получилось улучшить разрешение: $e');
        return original;
      }
    }
    // Missing embedded artwork may have been fetched directly by forTrack.
    return original;
  }

  Future<DeezerArtwork?> _findDeezer(Track t) async {
    final artist = t.albumArtist.trim().isNotEmpty
        ? t.albumArtist : t.artist;
    final album = t.album.trim();
    if (album.isNotEmpty) {
      final key = '${DeezerArt.normalize(artist)}|${DeezerArt.normalize(album)}';
      var found = _albumLookupInflight[key];
      if (found == null) {
        found = DeezerArt.find(artist: artist, title: '', album: album);
        _albumLookupInflight[key] = found;
        found.whenComplete(() { _albumLookupInflight.remove(key); });
      }
      final albumArt = await found;
      if (albumArt != null) return albumArt;
    }
    if (t.title.trim().isEmpty) return null;
    return DeezerArt.find(artist: t.artist, title: t.title, album: album);
  }

  Future<Uint8List?> _deezerCover(Track t) async {
    try {
      final art = await _findDeezer(t);
      if (art == null) {
        AppLog.info('Обложка Deezer: нет совпадения для «${t.displayAlbum}»');
        return null;
      }
      _saveFoundCover(t, art.bytes);
      return art.bytes;
    } catch (e) {
      AppLog.warn('Обложка Deezer: ошибка поиска для ${t.id}', e);
      return null;
    }
  }

  /// First display the cover locally, then persist it for all library members.
  /// Never override a manually chosen or album-wide cover.
  void _saveFoundCover(Track t, Uint8List bytes) {
    if (!lib.hasHub || !_savingDeezer.add(t.id)) return;
    unawaited(() async {
      try {
        final current = lib.data.tracks[t.id];
        if (current == null || lib.customCoverOf(current) != null) return;
        final id = await lib.uploadCover(bytes, 'jpg');
        final latest = lib.data.tracks[t.id];
        if (latest == null || lib.customCoverOf(latest) != null) return;
        await seed(id, bytes);
        lib.setMeta({t.id: {'cv': id}});
        AppLog.info('Обложка Deezer: восстановлена для ${t.id} и сохранена на Drive');
      } catch (e) {
        AppLog.warn('Обложка Deezer: показана локально, но не сохранена на Drive', e);
      } finally {
        _savingDeezer.remove(t.id);
      }
    }());
  }

  /// Картинка из папки covers на Диске: обложка, которую выбрал кто-то из друзей
  Future<Uint8List?> forFile(String fileId, {int px = 0}) => _get('cv_$fileId', px, () => lib.downloadCover(fileId));

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'[^A-Za-z0-9_@-]'), '_')}.img');

  /// Только что загруженную картинку сразу кладём в кэш: скачивать её обратно не нужно
  Future<void> seed(String fileId, Uint8List bytes) async {
    final key = 'cv_$fileId';
    _remember(key, bytes);
    _signal();
    try {
      await _file(key).writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  Future<Uint8List?> _get(String key, int px, Future<Uint8List?> Function() fetch) {
    final bucket = bucketFor(px);
    final mk = _mk(key, bucket);
    // Null is a temporary miss, not proof the source will never gain art.
    if (_mem[mk] != null) return Future.value(_touch(mk));
    // A lower-resolution cached thumbnail is only a visual fallback: do not
    // return it as the final result and accidentally suppress the full-size load.
    final until = _retryAt[key];
    if (until != null && DateTime.now().isBefore(until)) return Future.value(null);
    return _inflight[mk] ??= _resolve(key, mk, bucket, fetch).whenComplete(() => _inflight.remove(mk));
  }

  Future<Uint8List?> _resolve(String key, String mk, int bucket, Future<Uint8List?> Function() fetch) async {
    try {
      Uint8List? bytes;
      final thumbFile = bucket == 0 ? null : _file(mk);
      if (thumbFile != null && await thumbFile.exists()) {
        bytes = await thumbFile.readAsBytes();
        if (bytes.isEmpty) bytes = null;
      }
      if (bytes == null) {
        final orig = await _original(key, fetch);
        if (orig == null || orig.isEmpty) {
          _store(mk, null);
          _retryAt[key] = DateTime.now().add(const Duration(minutes: 5));
          Timer(const Duration(minutes: 5), _signal);
          return null;
        }
        bytes = bucket == 0 ? orig : await makeThumbnail(orig, bucket);
        if (thumbFile != null) {
          try {
            await thumbFile.writeAsBytes(bytes, flush: true);
          } catch (_) {}
        }
      }
      _failures.remove(key);
      _retryAt.remove(key);
      _store(mk, bytes);
      return bytes;
    } catch (_) {
      // Нет сети или доступа: неудачу не запоминаем насовсем, пробуем снова через 5, 15, 60 секунд
      final n = (_failures[key] ?? 0) + 1;
      _failures[key] = n;
      final wait = Duration(seconds: n == 1 ? 5 : (n == 2 ? 15 : 60));
      _retryAt[key] = DateTime.now().add(wait);
      Timer(wait, _signal);
      return null;
    }
  }

  // Two thumbnails of the same cover can be requested simultaneously.
  // Share a single original Drive download across all thumbnail sizes.
  Future<Uint8List?> _original(String key, Future<Uint8List?> Function() fetch) =>
      _originalInflight[key] ??=
          _loadOriginal(key, fetch).whenComplete(() => _originalInflight.remove(key));

  Future<Uint8List?> _loadOriginal(String key, Future<Uint8List?> Function() fetch) async {
    final file = _file(key);
    if (await file.exists()) {
      try {
        final b = await file.readAsBytes();
        if (await _validImage(b)) return b;
        // Invalidate a stale/corrupted media cache; otherwise fullscreen can
        // keep showing an error or a low-quality leftover indefinitely.
        await file.delete();
        AppLog.info('Обложка: повреждённый файл кэша удалён, повторяю загрузку');
      } catch (_) {}
    }
    await _acquire();
    try {
      final b = await fetch();
      if (b != null && await _validImage(b)) {
        try {
          await file.writeAsBytes(b, flush: true);
        } catch (_) {}
      }
      return b;
    } finally {
      _release();
    }
  }

  void _store(String mk, Uint8List? bytes) {
    _remember(mk, bytes);
    _signal();
  }

  /// Сообщаем виджетам, что что-то догрузилось; частые сигналы склеиваем в один
  void _signal() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    Timer(const Duration(milliseconds: 60), () {
      _notifyQueued = false;
      notifyListeners();
    });
  }

  /// Подгружает с диска уменьшенные копии для первых треков, чтобы список открылся уже с картинками
  Future<void> warm(Iterable<Track> tracks, {int limit = 80}) async {
    var n = 0;
    for (final t in tracks) {
      if (n++ >= limit) break;
      if (!wants(t)) continue;
      final c = lib.customCoverOf(t);
      final key = c != null ? 'cv_$c' : _key(t);
      final mk = _mk(key, 160);
      if (_mem.containsKey(mk)) continue;
      final f = _file(mk);
      try {
        if (await f.exists()) {
          final b = await f.readAsBytes();
          if (b.isNotEmpty) _remember(mk, b);
        }
      } catch (_) {}
    }
    _signal();
  }

  Future<void> _acquire() async {
    if (_active < 4) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}
