import 'dart:async';

import 'package:cave_player/config.dart';
import 'package:cave_player/core/lastfm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(String body, [int code = 200]) =>
    http.Response(body, code, headers: {'content-type': 'application/json; charset=utf-8'});

const _tagsOk = '{"toptags":{"tag":[{"name":"Chill","count":100},{"name":"rare","count":2}]}}';
const _similarOk = '{"similarartists":{"artist":[{"name":"Moby","match":"0.8"}]}}';

LastFm _lfm(MockClientHandler h, {Duration timeout = const Duration(milliseconds: 200)}) =>
    LastFm(null, client: MockClient(h), spacing: Duration.zero, timeout: timeout);

void main() {
  test('временная ошибка Last.fm (16) не запоминается как «тегов нет»', () async {
    var calls = 0;
    final l = _lfm((r) async {
      calls++;
      return calls == 1 ? _json('{"error":16,"message":"temporary"}') : _json(_tagsOk);
    });
    expect(await l.artistTags('Air'), isNull); // сбой — null, а не пустой список
    final again = await l.artistTags('Air');
    expect(calls, 2); // второй раз спросили снова
    expect(again!.map((e) => e.artist), ['chill']); // тег с весом меньше 5 отброшен, имя в нижнем регистре
  });

  test('«не найдено» (6) — настоящий ответ: запоминается, повторно не спрашиваем', () async {
    var calls = 0;
    final l = _lfm((r) async {
      calls++;
      return _json('{"error":6,"message":"not found"}');
    });
    expect(await l.artistTags('Nobody'), isEmpty);
    expect(await l.artistTags('Nobody'), isEmpty);
    expect(calls, 1);
  });

  test('не-JSON (заглушка провайдера) — сбой, а после трёх подряд Last.fm уходит на паузу', () async {
    var calls = 0;
    final l = _lfm((r) async {
      calls++;
      return http.Response('<html>blocked</html>', 200);
    });
    for (final a in ['A', 'B', 'C']) {
      expect(await l.artistTags(a), isNull);
    }
    expect(l.paused, isTrue);
    expect(l.status, contains('Last.fm недоступен'));
    final before = calls;
    // На паузе отвечаем сразу и в сеть не ходим
    expect(await l.artistTags('D'), isNull);
    expect(await l.similarArtists('D'), isEmpty);
    expect(calls, before);
  });

  test('зависший запрос обрывается по таймауту и не вешает очередь', () async {
    var calls = 0;
    final l = _lfm((r) {
      calls++;
      if (calls == 1) return Completer<http.Response>().future; // первый не ответит никогда
      return Future.value(_json(_similarOk));
    }, timeout: const Duration(milliseconds: 50));
    expect(await l.artistTags('Hang'), isNull);
    final sim = await l.similarArtists('Air');
    expect(sim.map((e) => e.artist), ['Moby']);
    expect(l.paused, isFalse); // один сбой — ещё не повод для паузы
  });

  test('ключ отвергнут (26) — больше не спрашиваем', () async {
    var calls = 0;
    final l = _lfm((r) async {
      calls++;
      return _json('{"error":26,"message":"suspended"}');
    });
    expect(await l.similarArtists('Air'), isEmpty);
    expect(l.available, isFalse);
    expect(l.status, contains('ключ'));
    await l.similarArtists('Air');
    expect(calls, 1);
  });

  test('лимит запросов (29) — короткая пауза, ответ не запоминается', () async {
    var calls = 0;
    final l = _lfm((r) async {
      calls++;
      return _json('{"error":29,"message":"rate limit"}');
    });
    expect(await l.artistTags('Air'), isNull);
    expect(l.paused, isTrue);
    expect(l.pauseLeft, greaterThan(const Duration(seconds: 20)));
  });

  test('ключ API не попадает в отчёт, даже если исключение печатает адрес запроса', () async {
    final l = _lfm((r) async => throw http.ClientException('обрыв', r.url));
    expect(await l.artistTags('Air'), isNull);
    final rep = l.report();
    expect(rep, isNot(contains(kLastFmKey)));
    expect(rep, contains('net')); // тип сбоя
    expect(rep, contains('ClientException')); // и исключение, чтобы было видно, что именно случилось
    expect(rep, contains('artist.gettoptags «Air»')); // и о чём спрашивали
  });

  test('сбой с заглушкой провайдера: в отчёте код, заголовки и начало тела', () async {
    final l = _lfm((r) async => http.Response('<html>Доступ ограничен</html>', 403, headers: {'server': 'blocker', 'content-type': 'text/html; charset=utf-8'}));
    expect(await l.similarArtists('Air'), isEmpty);
    final rep = l.report();
    expect(rep, contains('nonjson'));
    expect(rep, contains('HTTP 403'));
    expect(rep, contains('server=blocker'));
    expect(rep, contains('Доступ ограничен'));
  });

  test('срочные запросы обгоняют фоновые (теги)', () async {
    final order = <String>[];
    final l = _lfm((r) async {
      order.add('${r.url.queryParameters['method']}:${r.url.queryParameters['artist']}');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _json(r.url.queryParameters['method'] == 'artist.getsimilar' ? _similarOk : _tagsOk);
    });
    await Future.wait([
      l.artistTags('A'),
      l.artistTags('B'),
      l.artistTags('C'),
      l.similarArtists('X'),
    ]);
    // A уже ушёл в сеть, когда остальные встали в очередь; дальше срочный X идёт раньше фоновых B и C
    expect(order, ['artist.gettoptags:A', 'artist.getsimilar:X', 'artist.gettoptags:B', 'artist.gettoptags:C']);
  });
}
