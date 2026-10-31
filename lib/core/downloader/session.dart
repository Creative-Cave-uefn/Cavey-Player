// Одно задание модулю скачки: плеер слушает 127.0.0.1 на случайном порту,
// запускает модуль без окна консоли, тот подключается и представляется токеном.
// Дальше обмен строками JSON — описание протокола в lib/src/ipc.dart репозитория
// cave-downloader. Здесь нет ничего от Flutter, чтобы протокол проверялся тестами.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../config.dart';
import '../winproc.dart';

/// Запрос модуля к плееру: существует ли трек, подпапка, загрузка на Диск, плейлист
typedef ModuleCallHandler = Future<Object?> Function(String method, Map args);

/// Запуск программы: возвращает код выхода, вывод отдаёт построчно
typedef Launcher = Future<int> Function(String exe, List<String> args, void Function(String line) onLine);

class SessionResult {
  final bool ok;
  final Object? value;

  /// Задание прервано ошибкой (текст для журнала); null — ошибки не было
  final String? error;
  const SessionResult(this.ok, {this.value, this.error});
}

/// Модуль говорит на другой версии протокола
class ModuleProtocolMismatch implements Exception {
  final int module;
  final int player;
  final String version;
  const ModuleProtocolMismatch(this.module, this.player, this.version);

  @override
  String toString() => module > player
      ? 'Модуль скачки $version новее этой версии Cavey (протокол $module, нужен $player). Обновите Cavey.'
      : 'Модуль скачки $version устарел (протокол $module, нужен $player).';
}

class _Conn {
  final Socket socket;
  final StreamIterator<String> lines;
  final String version;
  _Conn(this.socket, this.lines, this.version);
}

class DownloaderSession {
  /// Выполняет одно задание [job] модулем [exe]
  static Future<SessionResult> run({
    required String exe,
    required Map<String, Object?> job,
    required void Function(String line) onLog,
    void Function(Map progress)? onProgress,
    void Function(bool on)? onInstalling,
    ModuleCallHandler? onCall,
    int protocol = kDownloaderProtocol,
    Launcher? launch,
    Duration connectTimeout = const Duration(seconds: 40),
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = _token();
    final output = <String>[];
    final accepted = Completer<_Conn>();

    final sub = server.listen((s) async {
      if (accepted.isCompleted) {
        s.destroy();
        return;
      }
      try {
        final c = await _handshake(s, token, protocol).timeout(const Duration(seconds: 15));
        if (accepted.isCompleted) {
          s.destroy();
        } else {
          accepted.complete(c);
        }
      } on ModuleProtocolMismatch catch (e) {
        s.destroy();
        if (!accepted.isCompleted) accepted.completeError(e);
      } catch (_) {
        s.destroy(); // чужое подключение или неверный токен — ждём своё
      }
    });

    final args = ['serve', '--connect', '127.0.0.1:${server.port}', '--token', token];
    final exited = (launch ?? _launch)(exe, args, (l) {
      if (l.trim().isEmpty) return;
      output.add(l);
      if (output.length > 50) output.removeAt(0);
    });
    exited.then((code) {
      if (!accepted.isCompleted) {
        accepted.completeError(Exception('модуль скачки завершился с кодом $code, не подключившись к плееру'
            '${output.isEmpty ? '' : ': ${output.take(5).join(' ')}'}'));
      }
    }, onError: (Object e) {
      if (!accepted.isCompleted) accepted.completeError(Exception('модуль скачки не запустился: $e'));
    });

    final handler = onCall;
    _Conn? conn;
    try {
      final c = conn = await accepted.future.timeout(connectTimeout,
          onTimeout: () => throw Exception('модуль скачки не подключился к плееру за ${connectTimeout.inSeconds} с'));
      final socket = c.socket;
      var open = true;
      void send(Map<String, Object?> m) {
        if (!open) return;
        try {
          socket.write('${jsonEncode(m)}\n');
        } catch (_) {
          open = false;
        }
      }

      send({'t': 'job', ...job});
      SessionResult? result;
      while (await c.lines.moveNext()) {
        final m = _decodeMap(c.lines.current);
        if (m == null) continue;
        switch (m['t']) {
          case 'log':
            onLog('${m['text'] ?? ''}');
          case 'progress':
            onProgress?.call(m);
          case 'installing':
            onInstalling?.call(m['on'] == true);
          case 'call':
            final id = m['id'];
            final method = '${m['m'] ?? ''}';
            unawaited(() async {
              try {
                if (handler == null) throw UnsupportedError('плеер не принимает запросы');
                final value = await handler(method, m);
                send({'t': 'reply', 'id': id, 'ok': true, 'value': value});
              } catch (e) {
                send({'t': 'reply', 'id': id, 'ok': false, 'error': '$e'});
              }
            }());
          case 'end':
            result = SessionResult(m['ok'] == true, value: m['value'], error: m['error']?.toString());
        }
        if (result != null) break;
      }
      open = false;
      if (result != null) return result;
      final code = await exited.timeout(const Duration(seconds: 10), onTimeout: () => -1);
      return SessionResult(false,
          error: 'модуль скачки оборвал связь (код $code)${output.isEmpty ? '' : ': ${output.take(5).join(' ')}'}');
    } finally {
      await sub.cancel();
      await server.close();
      conn?.socket.destroy();
    }
  }

  static Map? _decodeMap(String line) {
    try {
      final v = jsonDecode(line);
      return v is Map ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<_Conn> _handshake(Socket s, String token, int protocol) async {
    s.setOption(SocketOption.tcpNoDelay, true);
    final lines = StreamIterator(s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
    if (!await lines.moveNext()) throw const SocketException('нет приветствия');
    final hello = jsonDecode(lines.current);
    if (hello is! Map || hello['t'] != 'hello' || hello['token'] != token) throw const SocketException('чужое подключение');
    final version = '${hello['version'] ?? '?'}';
    final theirs = (hello['protocol'] as num?)?.toInt() ?? 0;
    if (theirs != protocol) {
      final e = ModuleProtocolMismatch(theirs, protocol, version);
      try {
        s.write('${jsonEncode({'t': 'bye', 'error': '$e'})}\n');
        await s.flush();
      } catch (_) {}
      throw e;
    }
    return _Conn(s, lines, version);
  }

  static String _token() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  /// На Windows без окна консоли (иначе на каждое скачивание мелькало бы окно терминала)
  static Future<int> _launch(String exe, List<String> args, void Function(String) onLine) async {
    if (Platform.isWindows) return WinProc.run(exe, args, onLine);
    final p = await Process.start(exe, args);
    await p.stdin.close();
    await Future.wait([p.stdout, p.stderr].map(
        (s) => s.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(onLine)));
    return p.exitCode;
  }
}
