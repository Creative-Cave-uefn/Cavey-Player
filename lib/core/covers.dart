import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'drive.dart';
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
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  int _active = 0;
  final List<Completer<void>> _waiting = [];
  bool _notifyQueued = false;

  CoverService(this.drive, this.lib, this.dir);

  static String _key(Track t) => t.cover ?? 'p_${t.id}';

  /// Какой размер копии нужен для картинки в [px] физических пикселей: 160, 640 или 0 (оригинал)
  static int bucketFor(int px) => px <= 0 ? 0 : (px <= 200 ? 160 : (px <= 720 ? 640 : 0));

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

  Uint8List? _peekKey(String key, int px) {
    final b = bucketFor(px);
    final exact = _touch(_mk(key, b));
    if (exact != null) return exact;
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

  Uint8List? peek(Track t, {int px = 0}) {
    final c = lib.customCoverOf(t);
    if (c != null) return peekFile(c, px: px);
    return t.hasCover ? _peekKey(_key(t), px) : null;
  }

  Uint8List? peekFile(String fileId, {int px = 0}) => _peekKey('cv_$fileId', px);

  /// Картинку трека ещё предстоит загрузить (есть обложка, но в памяти её нет)
  bool wants(Track t) => lib.customCoverOf(t) != null || t.hasCover;

  Future<Uint8List?> forTrack(Track t, {int px = 0}) {
    final c = lib.customCoverOf(t);
    if (c != null) return forFile(c, px: px);
    if (!t.hasCover) return Future.value(null);
    final key = _key(t);
    return _get(key, px, () async {
      final email = await lib.accessFor(t.source);
      final pic = t.pic;
      if (t.cover != null) return drive.download(email, t.cover!);
      if (pic != null) return drive.readRange(email, t.id, pic.offset, pic.offset + pic.length - 1);
      return null;
    });
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
    if (_mem.containsKey(mk)) return Future.value(_touch(mk));
    final fallback = _peekKey(key, px);
    if (fallback != null) return Future.value(fallback);
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
          _store(mk, null); // у трека действительно нет картинки
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

  Future<Uint8List?> _original(String key, Future<Uint8List?> Function() fetch) async {
    final file = _file(key);
    if (await file.exists()) {
      try {
        final b = await file.readAsBytes();
        if (b.isNotEmpty) return b;
      } catch (_) {}
    }
    await _acquire();
    try {
      final b = await fetch();
      if (b != null && b.isNotEmpty) {
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
