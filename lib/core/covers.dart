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

  /// Уже загруженная обложка — чтобы не мигать при перерисовке
  Uint8List? peek(Track t) => t.hasCover ? _mem[_key(t)] : null;

  Future<Uint8List?> forTrack(Track t) {
    if (!t.hasCover) return Future.value(null);
    final key = _key(t);
    if (_mem.containsKey(key)) return Future.value(_mem[key]);
    return _inflight[key] ??= _load(key, t).whenComplete(() => _inflight.remove(key));
  }

  Future<Uint8List?> _load(String key, Track t) async {
    final file = File('${dir.path}${Platform.pathSeparator}${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.img');
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
