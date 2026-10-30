import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/stream_proxy.dart';

/// Поддельный Диск: отдаёт куски файла по Range и проверяет токен
Future<HttpServer> fakeDrive(Uint8List file, List<String> ranges) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    final out = req.response;
    if (req.headers.value('authorization') != 'Bearer t') {
      out.statusCode = 401;
      await out.close();
      return;
    }
    final r = req.headers.value('range') ?? '';
    ranges.add(r);
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(r);
    final start = m == null ? 0 : int.parse(m.group(1)!);
    final end = m == null || m.group(2)!.isEmpty ? file.length - 1 : int.parse(m.group(2)!);
    out.statusCode = m == null ? 200 : 206;
    out.headers.contentLength = end - start + 1;
    out.add(Uint8List.sublistView(file, start, end + 1));
    await out.close();
  });
  return s;
}

Future<(int, Uint8List, Map<String, String>)> get(Uri u, [String? range]) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(u);
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final b = BytesBuilder();
    await for (final chunk in res) {
      b.add(chunk);
    }
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (res.statusCode, b.takeBytes(), h);
  } finally {
    c.close(force: true);
  }
}

void main() {
  final file = Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 31 + 7) % 256));

  test('отдаёт куски файла и конец из заранее скачанного', () async {
    final ranges = <String>[];
    final drive = await fakeDrive(file, ranges);
    final proxy = StreamProxy(urlFor: (id) => Uri.parse('http://127.0.0.1:${drive.port}/$id'));
    final url = await proxy.register('abc', size: file.length, token: () async => 't');

    // Начало — с Диска
    final (code, body, headers) = await get(url, 'bytes=0-');
    expect(code, 206);
    expect(body, file);
    expect(headers['content-range'], 'bytes 0-${file.length - 1}/${file.length}');

    // Конец — уже в памяти: новых запросов к Диску нет
    final (code2, tail, _) = await get(url, 'bytes=${file.length - 128}-');
    expect(code2, 206);
    expect(tail, Uint8List.sublistView(file, file.length - 128));
    final (_, last, _) = await get(url, 'bytes=-10');
    expect(last, Uint8List.sublistView(file, file.length - 10));
    final tailRange = 'bytes=${file.length - StreamProxy.tailSize}-${file.length - 1}';
    expect(ranges.where((r) => r == tailRange).length, 1);
    expect(ranges.where((r) => r.startsWith('bytes=${file.length - 128}') || r.startsWith('bytes=-')), isEmpty);

    // Середина — с Диска, ровно запрошенный кусок
    final (_, mid, _) = await get(url, 'bytes=1000-1999');
    expect(mid, Uint8List.sublistView(file, 1000, 2000));

    // Без Range — весь файл, 200
    final (code3, all, _) = await get(url);
    expect(code3, 200);
    expect(all.length, file.length);

    // За пределами файла и неизвестный трек
    final (code4, _, _) = await get(url, 'bytes=${file.length + 5}-');
    expect(code4, 416);
    final (code5, _, _) = await get(url.replace(path: '/t/zzz'));
    expect(code5, 404);

    await proxy.close();
    await drive.close(force: true);
  });

  test('размер неизвестен — просто пересылает', () async {
    final ranges = <String>[];
    final drive = await fakeDrive(file, ranges);
    final proxy = StreamProxy(urlFor: (id) => Uri.parse('http://127.0.0.1:${drive.port}/$id'));
    final url = await proxy.register('x', size: 0, token: () async => 't');
    final (code, body, _) = await get(url, 'bytes=10-19');
    expect(code, 206);
    expect(body, Uint8List.sublistView(file, 10, 20));
    await proxy.close();
    await drive.close(force: true);
  });

  test('заранее скачанное начало отдаёт из памяти и догружает остальное', () async {
    final ranges = <String>[];
    final drive = await fakeDrive(file, ranges);
    final proxy = StreamProxy(urlFor: (id) => Uri.parse('http://127.0.0.1:${drive.port}/$id'));
    await proxy.prefetch('p', size: file.length, token: () async => 't');
    final url = await proxy.register('p', size: file.length, token: () async => 't');

    final (code, body, _) = await get(url, 'bytes=0-');
    expect(code, 206);
    expect(body, file);
    expect(ranges, contains('bytes=0-${StreamProxy.headSize - 1}'));
    expect(ranges, contains('bytes=${StreamProxy.headSize}-${file.length - 1}'));

    // Кусок целиком внутри начала — Диск больше не нужен
    final before = ranges.length;
    final (_, small, _) = await get(url, 'bytes=100-199');
    expect(small, Uint8List.sublistView(file, 100, 200));
    expect(ranges.length, before);

    await proxy.close();
    await drive.close(force: true);
  });
}
