// Статус в Discord: «Слушает … в Cave Player». Discord принимает его через
// именованный канал \\.\pipe\discord-ipc-N, работаем с ним функциями Windows.
// Нужен ID приложения из Discord Developer Portal (DISCORD_CLIENT_ID при сборке).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../config.dart';
import 'log.dart';
import 'models.dart';

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _RwC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _RwD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _PeekC = Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _PeekD = int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);

class DiscordPresence {
  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _openExisting = 3;

  _CreateFileD? _create;
  _RwD? _write;
  _RwD? _read;
  _PeekD? _peek;
  _CloseD? _close;
  int _handle = -1;
  DateTime? _nextTry;
  String _lastKey = '';

  bool get available => kDiscordClientId.isNotEmpty && Platform.isWindows;
  bool get connected => _handle != -1;

  void _bind() {
    if (_create != null) return;
    final k32 = DynamicLibrary.open('kernel32.dll');
    _create = k32.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
    _write = k32.lookupFunction<_RwC, _RwD>('WriteFile');
    _read = k32.lookupFunction<_RwC, _RwD>('ReadFile');
    _peek = k32.lookupFunction<_PeekC, _PeekD>('PeekNamedPipe');
    _close = k32.lookupFunction<_CloseC, _CloseD>('CloseHandle');
  }

  bool _connect() {
    if (connected) return true;
    final next = _nextTry;
    if (next != null && DateTime.now().isBefore(next)) return false;
    _bind();
    for (var i = 0; i < 10; i++) {
      final pipeName = '${r'\\.\pipe\discord-ipc-'}$i'.toNativeUtf16();
      final h = _create!(pipeName, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
      malloc.free(pipeName);
      if (h != -1 && h != 0) {
        _handle = h;
        if (_send(0, {'v': 1, 'client_id': kDiscordClientId})) {
          AppLog.info('Discord подключён');
          return true;
        }
      }
    }
    // Discord не запущен — пробуем снова через минуту
    _nextTry = DateTime.now().add(const Duration(minutes: 1));
    return false;
  }

  bool _send(int op, Map<String, dynamic> payload) {
    final body = utf8.encode(jsonEncode(payload));
    final frame = Uint8List(8 + body.length);
    final bd = ByteData.sublistView(frame);
    bd.setInt32(0, op, Endian.little);
    bd.setInt32(4, body.length, Endian.little);
    frame.setRange(8, frame.length, body);
    final buf = calloc<Uint8>(frame.length);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(frame.length).setAll(0, frame);
      final ok = _write!(_handle, buf, frame.length, written, nullptr);
      if (ok == 0) {
        _disconnect();
        return false;
      }
      _drain();
      return true;
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  /// Читаем ответы Discord, чтобы канал не забивался; не блокируемся
  void _drain() {
    final avail = calloc<Uint32>();
    try {
      for (var i = 0; i < 4; i++) {
        if (_peek!(_handle, nullptr, 0, nullptr, avail, nullptr) == 0) {
          _disconnect();
          return;
        }
        final n = avail.value;
        if (n == 0) return;
        final buf = calloc<Uint8>(n);
        final got = calloc<Uint32>();
        _read!(_handle, buf, n, got, nullptr);
        calloc.free(buf);
        calloc.free(got);
      }
    } finally {
      calloc.free(avail);
    }
  }

  void _disconnect() {
    if (_handle != -1) _close?.call(_handle);
    _handle = -1;
  }

  /// Показывает текущий трек или убирает статус (track == null)
  void update(Track? track, {required bool playing, required Duration position, required Duration duration, required bool enabled}) {
    if (!available) return;
    final show = enabled && track != null && playing;
    final key = show ? '${track.id}|${position.inSeconds ~/ 5}|$playing' : 'off';
    if (key == _lastKey) return;
    try {
      if (!_connect()) return;
      final nonce = '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 20)}';
      Map<String, dynamic> args = {'pid': pid};
      if (show) {
        final start = DateTime.now().subtract(position).millisecondsSinceEpoch;
        args['activity'] = {
          'type': 2, // «Слушает»
          'details': _cut(track.title),
          'state': _cut(track.displayArtist),
          'timestamps': {
            'start': start,
            if (duration > Duration.zero) 'end': start + duration.inMilliseconds,
          },
          'assets': {'large_text': _cut(track.displayAlbum)},
        };
      }
      if (_send(1, {'cmd': 'SET_ACTIVITY', 'args': args, 'nonce': nonce})) _lastKey = key;
    } catch (e) {
      AppLog.warn('Discord', e);
      _disconnect();
    }
  }

  static String _cut(String s) => s.length < 2 ? '$s  ' : (s.length > 120 ? s.substring(0, 120) : s);

  void dispose() => _disconnect();
}
