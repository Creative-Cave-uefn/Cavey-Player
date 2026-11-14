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

/// Ограничивает число одновременных загрузок обложек. То, на что человек смотрит прямо сейчас
/// (полный экран), обгоняет фоновые загрузки для списков и не ждёт свободного слота.
class LoadGate {
  LoadGate(this.limit);

  final int limit;
  int _active = 0;
  final List<({String key, Completer<void> done})> _waiting = [];
  final Set<String> _urgent = {};

  int get active => _active;

  Future<void> acquire(String key) async {
    if (_active < limit || _urgent.contains(key)) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiting.add((key: key, done: c));
    await c.future;
  }

  void release() {
    if (_active > limit || _waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeAt(0).done.complete();
    }
  }

  /// Загрузка [key] нужна сейчас: если она уже стоит в очереди — идёт первой, а новая не ждёт
  void prioritize(String key) {
    _urgent.add(key);
    final i = _waiting.indexWhere((w) => w.key == key);
    if (i > 0) _waiting.insert(0, _waiting.removeAt(i));
  }

  void settle(String key) => _urgent.remove(key);
}

/// Обложки: из cover.jpg рядом с треком или из тегов (догружаем только нужный
/// кусок файла). Кэшируются в памяти и на диске, чтобы не качать повторно.
///
/// Рядом с оригиналом на диске лежат уменьшенные копии (160 и 640 px): списки читают маленькую,
/// она открывается мгновенно и после перезапуска. Когда картинка догрузилась, сервис оповещает
/// виджеты, и они обновляются сами, без смены вкладки.
///
/// Вместо картинки меньше нужной виджет ничего не получает: если в кэше есть только копия поменьше,
/// он ждёт нужную. Копию побольше берём сразу.
class CoverService extends ChangeNotifier {
  final DriveApi drive;
  final LibraryController lib;
  final Directory dir;

  final Map<String, Uint8List?> _mem = {};
  int _memoryBytes = 0;
  static const int _memoryLimitBytes = 64 * 1024 * 1024;

  // Оригиналы, которые показывали на весь экран: хранятся отдельно от общего кэша, чтобы повторное
  // открытие того же трека не читало и не разбирало файл заново
  final Map<String, Uint8List> _pinned = {};
  static const int _pinnedLimit = 6;

  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, Future<Uint8List?>> _originalInflight = {};
  final Map<String, Future<DeezerArtwork?>> _albumLookupInflight = {};
  final Set<String> _savingDeezer = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  // Картинки, которые не читаются: кэш сбрасываем один раз за сессию
  final Set<String> _discarded = {};
  // Диск и сеть Google Drive: 4 загрузки сразу. Каталог Deezer (поиск обложки трекам без неё)
  // идёт в своей очереди и не занимает слоты Drive.
  final LoadGate _driveGate = LoadGate(4);
  final LoadGate _deezerGate = LoadGate(2);
  bool _notifyQueued = false;

  CoverService(this.drive, this.lib, this.dir);

  static String _key(Track t) => t.cover ?? 'p_${t.id}';

  /// Какой размер копии нужен для картинки в [px] физических пикселей: 160, 640 или 0 (оригинал)
  static int bucketFor(int px) => px <= 0 ? 0 : (px <= 160 ? 160 : (px <= 720 ? 640 : 0));

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

  /// Уже загруженная картинка — чтобы не мигать при перерисовке. Последняя использованная — в конце
  Uint8List? _touch(String key) {
    if (!_mem.containsKey(key)) return null;
    final bytes = _mem.remove(key);
    _mem[key] = bytes;
    return bytes;
  }

  /// Нужной величины или больше. Копию меньше нужной не отдаём: она растянется и будет мыльной.
  Uint8List? _peekKey(String key, int px) {
    final b = bucketFor(px);
    final exact = _touch(_mk(key, b));
    if (exact != null) return exact;
    final pinned = _pinned[key];
    if (pinned != null) return pinned;
    if (b == 160) return _touch(_mk(key, 640)) ?? _touch(key);
    if (b == 640) return _touch(key);
    return null;
  }

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

  void _pin(String key, Uint8List bytes) {
    _pinned.remove(key);
    _pinned[key] = bytes;
    while (_pinned.length > _pinnedLimit) {
      _pinned.remove(_pinned.keys.first);
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

  /// [fullscreen] — картинка на весь экран: грузится вне очереди, оригинал запоминается отдельно.
  Future<Uint8List?> forTrack(Track t, {int px = 0, bool fullscreen = false}) {
    final c = lib.customCoverOf(t);
    if (c != null) return forFile(c, px: px, fullscreen: fullscreen);
    final key = _key(t);
    if (!t.hasCover) {
      return canFindInDeezer(t)
          ? _get(key, px, () => _deezerCover(t), fullscreen: fullscreen, gate: _deezerGate)
          : Future.value(null);
    }
    return _get(key, px, () async {
      try {
        final email = await lib.accessFor(t.source);
        final pic = t.pic;
        final Uint8List? bytes = t.cover != null
            ? await drive.download(email, t.cover!)
            : pic != null
                ? await drive.readRange(email, t.id, pic.offset, pic.offset + pic.length - 1)
                : null;
        if (bytes != null && looksLikeImage(bytes)) return bytes;
        AppLog.info('Обложка: встроенное изображение ${t.id} не читается, пробую Deezer');
      } catch (e) {
        AppLog.warn('Обложка: ошибка чтения изображения ${t.id}; ищу резервную', e);
      }
      return canFindInDeezer(t) ? _deezerCover(t) : null;
    }, fullscreen: fullscreen);
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
  Future<Uint8List?> forFile(String fileId, {int px = 0, bool fullscreen = false}) =>
      _get('cv_$fileId', px, () => lib.downloadCover(fileId), fullscreen: fullscreen);

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'[^A-Za-z0-9_@-]'), '_')}.img');

  /// Только что загруженную картинку сразу кладём в кэш: скачивать её обратно не нужно
  Future<void> seed(String fileId, Uint8List bytes) async {
    final key = 'cv_$fileId';
    // Сначала файл, потом сигнал: иначе виджет успевал спросить картинку раньше, не находил её,
    // шёл на Диск и получал отказ, который помнится 5 минут
    await _writeAtomic(_file(key), bytes);
    _retryAt.remove(key);
    _failures.remove(key);
    _remember(key, bytes);
    _signal();
  }

  Future<Uint8List?> _get(String key, int px, Future<Uint8List?> Function() fetch,
      {bool fullscreen = false, LoadGate? gate}) {
    final bucket = bucketFor(px);
    final mk = _mk(key, bucket);
    if (fullscreen) {
      // Эту картинку смотрят прямо сейчас: она не должна стоять в очереди за списками
      _driveGate.prioritize(key);
      _deezerGate.prioritize(key);
    }
    if (bucket == 0) {
      final pinned = _pinned[key];
      if (pinned != null) return Future.value(pinned);
    }
    // Null — временная неудача, а не вечное «картинки нет»
    final hit = _touch(mk);
    if (hit != null) {
      if (fullscreen && bucket == 0) _pin(key, hit);
      return Future.value(hit);
    }
    // Копия не меньше нужной уже есть — отдаём её, перезагружать незачем
    final larger = _peekKey(key, px);
    if (larger != null) return Future.value(larger);
    final until = _retryAt[key];
    if (until != null && DateTime.now().isBefore(until)) return Future.value(null);
    final load = _inflight[mk] ??=
        _resolve(key, mk, bucket, fetch, gate ?? _driveGate).whenComplete(() {
          _inflight.remove(mk);
        });
    if (fullscreen && bucket == 0) {
      return load.then((b) {
        if (b != null) _pin(key, b);
        return b;
      });
    }
    return load;
  }

  Future<Uint8List?> _resolve(String key, String mk, int bucket,
      Future<Uint8List?> Function() fetch, LoadGate gate) async {
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
        final orig = await _original(key, fetch, gate);
        if (orig == null || orig.isEmpty) {
          _store(mk, null);
          _retryAt[key] = DateTime.now().add(const Duration(minutes: 5));
          Timer(const Duration(minutes: 5), _signal);
          return null;
        }
        // GIF отдаём целиком: уменьшенная копия была бы одним кадром, а аватарка и баннер должны двигаться
        final keep = bucket == 0 || isGifBytes(orig);
        bytes = keep ? orig : await makeThumbnail(orig, bucket);
        if (thumbFile != null && !keep) await _writeAtomic(thumbFile, bytes);
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

  // Две копии одной обложки могут запросить одновременно: оригинал грузим один раз
  Future<Uint8List?> _original(String key, Future<Uint8List?> Function() fetch, LoadGate gate) =>
      _originalInflight[key] ??= _loadOriginal(key, fetch, gate).whenComplete(() {
        _originalInflight.remove(key);
        _driveGate.settle(key);
        _deezerGate.settle(key);
      });

  Future<Uint8List?> _loadOriginal(String key, Future<Uint8List?> Function() fetch, LoadGate gate) async {
    final file = _file(key);
    if (await file.exists()) {
      try {
        final b = await file.readAsBytes();
        // С диска проверяем только заголовок: без разбора картинки, это быстро
        if (looksLikeImage(b)) return b;
        AppLog.info('Обложка $key: файл в кэше (${b.length} Б) не картинка, удаляю и качаю заново');
        await file.delete();
      } catch (_) {}
    }
    Uint8List? b;
    await gate.acquire(key);
    try {
      b = await fetch();
    } finally {
      gate.release();
    }
    if (b == null || b.isEmpty) return b;
    // Разбор картинки — только для свежескачанного, и вне очереди загрузок.
    // Каталог Deezer уже проверил размер сам.
    if (!identical(gate, _deezerGate) && !await _acceptDownload(b)) {
      AppLog.info('Обложка $key: скачанный файл (${b.length} Б) не прошёл проверку изображения');
      return null;
    }
    await _writeAtomic(file, b);
    return b;
  }

  /// Новая картинка с Диска: заголовок картинки и разбор. Если разбор не уложился в срок,
  /// не отбрасываем: файл большой, а не битый.
  Future<bool> _acceptDownload(Uint8List bytes) async {
    if (!looksLikeImage(bytes)) return false;
    try {
      return await DeezerArt.dimensionsInBackground(bytes).timeout(const Duration(seconds: 5)) != null;
    } on TimeoutException {
      return true;
    } catch (_) {
      return false;
    }
  }

  void _store(String mk, Uint8List? bytes) {
    _remember(mk, bytes);
    _signal();
  }

  /// A cached picture failed to decode: drop the cached copies (thumbnails and the
  /// downloaded original) so the next load fetches them again. Once per picture and
  /// session, so a source file that is itself broken cannot cause a reload loop.
  void discard(String? key) {
    if (key == null || !_discarded.add(key)) return;
    _pinned.remove(key);
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
}
