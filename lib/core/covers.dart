import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  // Full-resolution artwork found for fullscreen (e.g. via Deezer) when the
  // source file only embeds a small cover. Kept apart from _mem so that the
  // thumbnail/original cache can never overwrite it with the small original.
  final Map<String, Uint8List> _upgraded = {};
  final Map<String, DateTime> _fullChecked = {};
  final Map<String, Future<Uint8List?>> _fullInflight = {};
  // Cached files that failed to decode are dropped once per session.
  final Set<String> _discarded = {};
  int _active = 0;
  final List<({String key, Completer<void> done})> _waiting = [];
  // Covers the person is looking at right now: they jump the queue of background loads
  final Set<String> _urgent = {};
  bool _notifyQueued = false;

  CoverService(this.drive, this.lib, this.dir);

  static String _key(Track t) => t.cover ?? 'p_${t.id}';

  /// Какой размер копии нужен для картинки в [px] физических пикселей: 160, 640 или 0 (оригинал)
  /// 160 берём только когда хватает без растяжения: от 161 px уже нужна копия 640
  static int bucketFor(int px) => px <= 0 ? 0 : (px <= 160 ? 160 : (px <= 720 ? 640 : 0));

  /// Cheap integrity check for cached thumbnails: a JPEG must end with EOI and
  /// a PNG with IEND. A write cut short by a crash would otherwise be read
  /// from disk on every start and never display.
  @visibleForTesting
  static bool looksComplete(Uint8List b) {
    if (b.length < 16) return false;
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var end = b.length;
      while (end > 2 && b[end - 1] == 0) {
        end--;
      }
      return b[end - 2] == 0xFF && b[end - 1] == 0xD9;
    }
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      final n = b.length;
      return b[n - 8] == 0x49 && b[n - 7] == 0x45 && b[n - 6] == 0x4E && b[n - 5] == 0x44;
    }
    return true;
  }

  /// Write through a temporary file so a crash never leaves half an image behind.
  Future<void> _writeAtomic(File f, Uint8List bytes) async {
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

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
  ///
  /// With [upgrade] (fullscreen) a small original in memory is not final: the
  /// check for larger artwork must have finished too, otherwise reopening the
  /// fullscreen view would keep showing the small embedded cover forever.
  bool hasExact(Track t, {int px = 0, bool upgrade = false}) {
    final cover = lib.customCoverOf(t);
    final key = cover == null ? _key(t) : 'cv_$cover';
    final bucket = bucketFor(px);
    if (bucket == 0) {
      final fk = _fullKey(t);
      if (_upgraded.containsKey(fk)) return true;
      if (upgrade && canFindInDeezer(t) && !_fullDone(fk)) return false;
    }
    return _mem[_mk(key, bucket)] != null;
  }

  /// The fullscreen upgrade belongs to the cover *and* to what the track is called: once the
  /// tags are corrected (e.g. filled in from Deezer), an earlier "nothing better found"
  /// or a match for the old names no longer applies.
  String _fullKey(Track t) => '${keyOf(t)}|${t.artist}|${t.albumArtist}|${t.album}|${t.title}';

  String _hqName(String fk) => 'hq-${sha1.convert(utf8.encode(fk)).toString().substring(0, 24)}';

  bool _fullDone(String fk) {
    final at = _fullChecked[fk];
    return at != null && DateTime.now().difference(at) < const Duration(minutes: 10);
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
    if (bucketFor(px) == 0) {
      final better = _upgraded[_fullKey(t)];
      if (better != null) return better;
    }
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

  /// Resolve a high-resolution image when the cover we have (embedded in the file or the
  /// one saved next to it on Drive, e.g. by the downloader) is small. The existing picture
  /// is still shown while a verified Deezer match is retrieved.
  /// The cover for the fullscreen view as it is (no search for a larger one): shown at once,
  /// before the slower [forFullscreen] has looked for a better picture. Jumps the load queue.
  Future<Uint8List?> fullscreenOriginal(Track t) {
    _prioritize(keyOf(t));
    return forTrack(t, px: 0);
  }

  Future<Uint8List?> forFullscreen(Track t) {
    _prioritize(keyOf(t));
    final fk = _fullKey(t);
    final ready = _upgraded[fk];
    if (ready != null) return Future.value(ready);
    return _fullInflight[fk] ??= _upgrade(t, fk).whenComplete(() => _fullInflight.remove(fk));
  }

  void _setUpgraded(String fk, Uint8List bytes) {
    _upgraded.remove(fk);
    _upgraded[fk] = bytes;
    while (_upgraded.length > 12) {
      _upgraded.remove(_upgraded.keys.first);
    }
    _fullChecked[fk] = DateTime.now();
    _signal();
  }

  Future<Uint8List?> _upgrade(Track t, String fk) async {
    final custom = lib.customCoverOf(t) != null;
    final original = await forTrack(t, px: 0);
    if (!canFindInDeezer(t)) {
      _fullChecked[fk] = DateTime.now();
      return original;
    }
    // Found in an earlier session: show it at once, no network.
    final saved = _file(_hqName(fk));
    try {
      if (await saved.exists()) {
        final b = await saved.readAsBytes();
        if (looksComplete(b)) {
          _setUpgraded(fk, b);
          return b;
        }
        await saved.delete();
      }
    } catch (_) {}
    if (original == null || original.isEmpty) return original;
    // No cover of our own at all: forTrack already fetched it from Deezer.
    if (!custom && !t.hasCover) {
      _fullChecked[fk] = DateTime.now();
      return original;
    }
    try {
      final dims = await DeezerArt.dimensionsInBackground(original)
          .timeout(const Duration(seconds: 4));
      if (dims != null && dims.$1 >= 900 && dims.$2 >= 900) {
        _fullChecked[fk] = DateTime.now();
        AppLog.info('Полный экран: «${t.title}» ${custom ? 'своя' : 'встроенная'} обложка '
            '${dims.$1}×${dims.$2} достаточна, поиск лучшей не нужен');
        return original;
      }
      final artwork = await _findDeezer(t);
      _fullChecked[fk] = DateTime.now();
      AppLog.info('Полный экран: «${t.title}» ${custom ? 'своя' : 'встроенная'} обложка '
          '${dims == null ? '?' : '${dims.$1}×${dims.$2}'}, Deezer: '
          '${artwork == null ? 'совпадения нет' : '${artwork.width}×${artwork.height}'}');
      if (artwork == null || (dims != null && !artwork.betterThan(dims.$1, dims.$2))) {
        return original;
      }
      // A cover someone picked by hand can differ from the catalog one: swap in the larger
      // picture only when it shows the same artwork
      if (custom && !await sameArtwork(original, artwork.bytes)) {
        AppLog.info('Fullscreen artwork: своя обложка отличается от каталожной, оставляю её');
        return original;
      }
      _setUpgraded(fk, artwork.bytes);
      unawaited(_writeAtomic(saved, artwork.bytes));
      if (!custom) _saveFoundCover(t, artwork.bytes);
      return artwork.bytes;
    } catch (e) {
      AppLog.info('Fullscreen artwork: не получилось улучшить разрешение: $e');
      return original;
    }
  }

  final Set<String> _traced = {};

  /// Diagnostics for the log: which picture the fullscreen view really shows
  /// (source, bytes and pixel size). One line per track, source and size.
  void trace(Track t, Uint8List bytes, String from) {
    final id = '${keyOf(t)}|$from|${bytes.length}';
    if (!_traced.add(id)) return;
    if (_traced.length > 300) _traced.clear();
    unawaited(() async {
      (int, int)? dims;
      try {
        dims = await DeezerArt.dimensionsInBackground(bytes).timeout(const Duration(seconds: 5));
      } catch (_) {}
      AppLog.info('Полный экран: «${t.title}» (${t.artist} — ${t.album}), ${keyOf(t)}, '
          'показано: $from, ${bytes.length} Б, ${dims == null ? 'размер не определён' : '${dims.$1}×${dims.$2}'}');
    }());
  }

  /// A cached picture failed to decode: drop the cached copies (thumbnails and the
  /// downloaded original) so the next load fetches them again. Once per picture and
  /// session, so a source file that is itself broken cannot cause a reload loop.
  void discard(String? key) {
    if (key == null || !_discarded.add(key)) return;
    for (final mk in [_mk(key, 160), _mk(key, 640), key]) {
      final old = _mem.remove(mk);
      _memoryBytes -= old?.length ?? 0;
      try {
        _file(mk).deleteSync();
      } catch (_) {}
    }
    _retryAt.remove(key);
    _failures.remove(key);
    AppLog.info('Обложка $key не читается: сбросил кэш, загружу заново');
    _signal();
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
    await _writeAtomic(_file(key), bytes);
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
        if (!looksComplete(bytes)) {
          // Оборванная запись: удаляем и делаем копию заново из оригинала
          bytes = null;
          try {
            await thumbFile.delete();
          } catch (_) {}
        }
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
        if (thumbFile != null) await _writeAtomic(thumbFile, bytes);
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
      _originalInflight[key] ??= _loadOriginal(key, fetch).whenComplete(() {
        _originalInflight.remove(key);
        _urgent.remove(key);
      });

  Future<Uint8List?> _loadOriginal(String key, Future<Uint8List?> Function() fetch) async {
    final file = _file(key);
    if (await file.exists()) {
      try {
        final b = await file.readAsBytes();
        if (await _validImage(b)) return b;
        AppLog.info('Обложка $key: файл в кэше (${b.length} Б) не прошёл проверку изображения');
        // Invalidate a stale/corrupted media cache; otherwise fullscreen can
        // keep showing an error or a low-quality leftover indefinitely.
        await file.delete();
        AppLog.info('Обложка: повреждённый файл кэша удалён, повторяю загрузку');
      } catch (_) {}
    }
    await _acquire(key);
    try {
      final b = await fetch();
      if (b == null) return null;
      if (!await _validImage(b)) {
        AppLog.info('Обложка $key: загруженный файл (${b.length} Б) не прошёл проверку изображения');
        return null;
      }
      await _writeAtomic(file, b);
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
          if (looksComplete(b)) _remember(mk, b);
        }
      } catch (_) {}
    }
    _signal();
  }

  Future<void> _acquire(String key) async {
    // An urgent load never waits behind the background ones, even when all slots are busy
    if (_active < 4 || _urgent.contains(key)) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiting.add((key: key, done: c));
    await c.future;
  }

  /// Marks a picture as wanted right now: a load already waiting for a slot moves to the front
  void _prioritize(String key) {
    _urgent.add(key);
    final i = _waiting.indexWhere((w) => w.key == key);
    if (i > 0) _waiting.insert(0, _waiting.removeAt(i));
  }

  void _release() {
    if (_active > 4 || _waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeAt(0).done.complete();
    }
  }
}
