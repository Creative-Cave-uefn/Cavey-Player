import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'drive.dart';
import 'library.dart';
import 'models.dart';

/// Обложки: из cover.jpg рядом с треком или из тегов (догружаем только нужный
/// кусок файла). Кэшируются в памяти и на диске, чтобы не качать повторно.
class CoverService {
  final DriveApi drive;
  final LibraryController lib;
  final Directory dir;

  final Map<String, Uint8List?> _mem = {};
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  CoverService(this.drive, this.lib, this.dir);

  static String _key(Track t) => t.cover ?? 'p_${t.id}';

  /// Ключ картинки трека: загруженная обложка (альбома или трека) важнее обложки из файла
  String keyOf(Track t) {
    final c = lib.customCoverOf(t);
    return c != null ? 'cv_$c' : _key(t);
  }

  /// Уже загруженная обложка — чтобы не мигать при перерисовке
  Uint8List? peek(Track t) {
    final c = lib.customCoverOf(t);
    if (c != null) return peekFile(c);
    return t.hasCover ? _mem[_key(t)] : null;
  }

  Uint8List? peekFile(String fileId) => _mem['cv_$fileId'];

  Future<Uint8List?> forTrack(Track t) {
    final c = lib.customCoverOf(t);
    if (c != null) return forFile(c);
    if (!t.hasCover) return Future.value(null);
    final key = _key(t);
    if (_mem.containsKey(key)) return Future.value(_mem[key]);
    return _inflight[key] ??= _load(key, t).whenComplete(() => _inflight.remove(key));
  }

  File _file(String key) => File('${dir.path}${Platform.pathSeparator}${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.img');

  /// Картинка из папки covers на Диске: обложка, которую выбрал кто-то из друзей
  Future<Uint8List?> forFile(String fileId) {
    final key = 'cv_$fileId';
    if (_mem.containsKey(key)) return Future.value(_mem[key]);
    return _inflight[key] ??= _loadCustom(key, fileId).whenComplete(() => _inflight.remove(key));
  }

  /// Только что загруженную картинку сразу кладём в кэш: скачивать её обратно не нужно
  Future<void> seed(String fileId, Uint8List bytes) async {
    final key = 'cv_$fileId';
    _mem[key] = bytes;
    try {
      await _file(key).writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  Future<Uint8List?> _loadCustom(String key, String fileId) async {
    final file = _file(key);
    try {
      Uint8List bytes;
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        await _acquire();
        try {
          bytes = await lib.downloadCover(fileId);
        } finally {
          _release();
        }
        if (bytes.isNotEmpty) await file.writeAsBytes(bytes, flush: true);
      }
      if (bytes.isEmpty) return null;
      _mem[key] = bytes;
      if (_mem.length > 400) _mem.remove(_mem.keys.first);
      return bytes;
    } catch (_) {
      return null; // нет сети или доступа — неудачу не запоминаем, попробуем в следующий раз
    }
  }

  Future<Uint8List?> _load(String key, Track t) async {
    final file = _file(key);
    Uint8List? bytes;
    try {
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        await _acquire();
        try {
          final email = await lib.accessFor(t.source);
          final pic = t.pic;
          if (t.cover != null) {
            bytes = await drive.download(email, t.cover!);
          } else if (pic != null) {
            bytes = await drive.readRange(email, t.id, pic.offset, pic.offset + pic.length - 1);
          }
        } finally {
          _release();
        }
        if (bytes != null && bytes.isNotEmpty) await file.writeAsBytes(bytes, flush: true);
      }
    } catch (_) {
      bytes = null;
    }
    _mem[key] = (bytes != null && bytes.isNotEmpty) ? bytes : null;
    if (_mem.length > 400) _mem.remove(_mem.keys.first);
    return _mem[key];
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
