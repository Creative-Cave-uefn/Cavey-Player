// Локальный прокси для стриминга с Google Диска. libmpv берёт трек отсюда
// (http://127.0.0.1:<порт>/t/<id>), а не напрямую с Диска. Зачем:
//
// - Конец файла скачивается заранее, пока плеер читает начало. При открытии
//   плеер почти всегда заглядывает в конец (теги ID3v1, длительность), и
//   раньше это был отдельный медленный запрос к Диску перед стартом.
// - Соединения с Диском переиспользуются: перемотка не открывает каждый раз
//   новое защищённое соединение.
// - Токен берётся свежий на каждый запрос: после долгой паузы трек
//   продолжает играть без переоткрытия.
// - Для треков, которые вот-вот включат (навели мышь, следующий в очереди,
//   первые в открытом альбоме), начало и конец скачиваются заранее —
//   тогда старт почти мгновенный.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'log.dart';

class _Entry {
  final String id;
  final int size; // 0 — размер неизвестен, просто пересылаем запросы
  final Future<String> Function() token;
  Future<Uint8List?>? tail;
  int tailStart = 0;
  Future<Uint8List?>? head;
  bool timed = false; // время до первого байта уже записали в журнал
  _Entry(this.id, this.size, this.token);
}

class StreamProxy {
  final Uri Function(String id) urlFor;
  final http.Client _client;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _Entry> _entries = {};

  /// Сколько конца файла скачивать заранее
  static const tailSize = 128 * 1024;

  /// Сколько начала скачивать заранее для треков, которые вот-вот включат
  static const headSize = 384 * 1024;

  /// Сколько последних треков помнить (старые ссылки перестают работать)
  static const keep = 24;

  DateTime _warmedAt = DateTime(0);

  /// Сколько раз прокси сходил на Диск (для тестов и журнала)
  int upstreamRequests = 0;

  StreamProxy({required this.urlFor, http.Client? client})
      // Соединения с Диском держим подольше: следующий клик не тратит время на новое
      : _client = client ?? IOClient(HttpClient()..idleTimeout = const Duration(seconds: 90));

  Future<HttpServer> _ensure() => _starting ??= () async {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        s.listen((req) => unawaited(_handle(req)));
        _server = s;
        return s;
      }();

  _Entry _entry(String id, int size, Future<String> Function() token) {
    var e = _entries.remove(id);
    if (e == null || e.size != size) e = _Entry(id, size, token);
    _entries[id] = e; // в конец: недавно нужный
    while (_entries.length > keep) {
      _entries.remove(_entries.keys.first);
    }
    if (size > tailSize * 4 && e.tail == null) {
      e.tailStart = size - tailSize;
      e.tail = _fetch(e, e.tailStart, size - 1).catchError((Object err) {
        AppLog.warn('Не получилось заранее скачать конец файла', err);
        return null;
      });
    }
    return e;
  }

  /// Ссылка для плеера. Сразу начинает скачивать конец файла.
  Future<Uri> register(String id, {required int size, required Future<String> Function() token}) async {
    final s = await _ensure();
    _entry(id, size, token).timed = false;
    return Uri.parse('http://127.0.0.1:${s.port}/t/$id');
  }

  /// Трек скоро могут включить: заранее скачиваем начало и конец
  Future<void> prefetch(String id, {required int size, required Future<String> Function() token}) async {
    if (size <= 0) return;
    await _ensure();
    final e = _entry(id, size, token);
    e.head ??= _fetch(e, 0, (size < headSize ? size : headSize) - 1).catchError((Object err) {
      AppLog.warn('Не получилось заранее скачать начало файла', err);
      e.head = null; // попробуем в другой раз
      return null;
    });
  }

  /// Открываем соединение с Диском заранее, чтобы клик по треку не ждал рукопожатия
  void warmUp() {
    final now = DateTime.now();
    if (now.difference(_warmedAt) < const Duration(seconds: 45)) return;
    _warmedAt = now;
    unawaited(() async {
      try {
        final res = await _client.send(http.Request('HEAD', urlFor('warmup'))).timeout(const Duration(seconds: 10));
        await res.stream.drain<void>();
      } catch (_) {}
    }());
  }

  Future<Uint8List?> _fetch(_Entry e, int start, int end) async {
    final req = http.Request('GET', urlFor(e.id))
      ..headers['Authorization'] = 'Bearer ${await e.token()}'
      ..headers['Range'] = 'bytes=$start-$end';
    upstreamRequests++;
    final res = await _client.send(req).timeout(const Duration(seconds: 20));
    final bytes = await res.stream.toBytes();
    if (res.statusCode == 206) return bytes;
    if (res.statusCode == 200 && bytes.length > end) return Uint8List.sublistView(bytes, start, end + 1);
    throw HttpException('Диск ответил ${res.statusCode}');
  }

  static final _range = RegExp(r'^bytes=(\d*)-(\d*)$');

  Future<void> _handle(HttpRequest req) async {
    final out = req.response;
    try {
      final parts = req.uri.pathSegments;
      final e = parts.length == 2 && parts[0] == 't' ? _entries[parts[1]] : null;
      if (e == null) {
        out.statusCode = HttpStatus.notFound;
        await out.close();
        return;
      }
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (e.size <= 0) {
        await _pipe(e, out, rangeHeader, head: req.method == 'HEAD');
        return;
      }

      // Какой кусок просят
      var start = 0, end = e.size - 1;
      final m = rangeHeader == null ? null : _range.firstMatch(rangeHeader.trim());
      if (m != null) {
        final a = m.group(1)!, b = m.group(2)!;
        if (a.isEmpty && b.isNotEmpty) {
          start = e.size - int.parse(b); // «последние N байт»
        } else {
          start = int.tryParse(a) ?? 0;
          if (b.isNotEmpty) end = int.parse(b);
        }
      }
      if (start < 0) start = 0;
      if (end >= e.size) end = e.size - 1;
      if (start >= e.size || start > end) {
        out.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        out.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${e.size}');
        await out.close();
        return;
      }

      out.statusCode = m != null ? HttpStatus.partialContent : HttpStatus.ok;
      out.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
        ..contentLength = end - start + 1;
      if (m != null) out.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${e.size}');
      if (req.method == 'HEAD') {
        await out.close();
        return;
      }

      // Начало скачано заранее — отдаём из памяти, остальное догружаем с Диска
      final head = e.head;
      if (head != null && start < (e.size < headSize ? e.size : headSize)) {
        final bytes = await head;
        if (bytes != null && start < bytes.length) {
          final stop = end + 1 < bytes.length ? end + 1 : bytes.length;
          out.add(Uint8List.sublistView(bytes, start, stop));
          if (!e.timed) {
            e.timed = true;
            AppLog.info('Прокси: начало трека из заранее скачанного');
          }
          if (stop > end) {
            await out.close();
          } else {
            await _stream(e, out, stop, end);
          }
          return;
        }
      }

      // Конец файла уже скачан (или вот-вот) — отдаём из памяти
      final tail = e.tail;
      if (tail != null && start >= e.tailStart) {
        final bytes = await tail;
        if (bytes != null && bytes.length == e.size - e.tailStart) {
          out.add(Uint8List.sublistView(bytes, start - e.tailStart, end - e.tailStart + 1));
          await out.close();
          return;
        }
      }
      await _stream(e, out, start, end);
    } catch (err) {
      // Плеер оборвал соединение (перемотка, следующий трек) — это нормально
      if (err is! HttpException && err is! SocketException) AppLog.warn('Прокси стриминга', err);
      try {
        await out.close();
      } catch (_) {}
    }
  }

  /// Кусок [start]..[end] прямо с Диска, по мере поступления
  Future<void> _stream(_Entry e, HttpResponse out, int start, int end) async {
    final req = http.Request('GET', urlFor(e.id))
      ..headers['Authorization'] = 'Bearer ${await e.token()}'
      ..headers['Range'] = 'bytes=$start-$end';
    upstreamRequests++;
    final sent = DateTime.now();
    final res = await _client.send(req);
    if (!e.timed) {
      e.timed = true;
      AppLog.info('Прокси: Диск ответил через ${DateTime.now().difference(sent).inMilliseconds} мс');
    }
    if (res.statusCode != 206 && !(res.statusCode == 200 && start == 0)) {
      await res.stream.drain<void>();
      throw HttpException('Диск ответил ${res.statusCode}');
    }
    await out.addStream(res.stream);
    await out.close();
  }

  /// Размер неизвестен — пересылаем запрос как есть
  Future<void> _pipe(_Entry e, HttpResponse out, String? range, {required bool head}) async {
    final req = http.Request(head ? 'HEAD' : 'GET', urlFor(e.id))..headers['Authorization'] = 'Bearer ${await e.token()}';
    if (range != null) req.headers['Range'] = range;
    upstreamRequests++;
    final res = await _client.send(req);
    out.statusCode = res.statusCode;
    for (final h in const ['content-length', 'content-range', 'accept-ranges', 'content-type']) {
      final v = res.headers[h];
      if (v != null) out.headers.set(h, v);
    }
    await out.addStream(res.stream);
    await out.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _client.close();
  }
}
