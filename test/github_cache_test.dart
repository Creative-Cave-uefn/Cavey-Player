import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cave_player/core/github_cache.dart';

void main() {
  setUp(GithubCache.clear);

  test('a 304 answer reuses the previous body, Unicode included', () async {
    final seen = <String?>[];
    final client = MockClient((request) async {
      seen.add(request.headers['If-None-Match']);
      if (request.headers['If-None-Match'] == '"v1"') return http.Response('', 304);
      return http.Response.bytes(utf8.encode('[{"body":"Что нового"}]'), 200,
          headers: {'etag': '"v1"', 'content-type': 'application/json; charset=utf-8'});
    });
    final url = Uri.parse('https://api.github.com/repos/x/y/releases');
    final first = await GithubCache.get(url, const {}, client: client);
    final second = await GithubCache.get(url, const {}, client: client);
    expect(seen, [null, '"v1"']);
    expect(second.statusCode, 200);
    expect(second.body, first.body);
    expect(jsonDecode(second.body)[0]['body'], 'Что нового');
  });

  test('errors are not cached', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.headers.containsKey('If-None-Match'), false);
      return http.Response('rate limited', 403, headers: {'etag': '"x"'});
    });
    final url = Uri.parse('https://api.github.com/repos/x/y/releases/latest');
    expect((await GithubCache.get(url, const {}, client: client)).statusCode, 403);
    expect((await GithubCache.get(url, const {}, client: client)).statusCode, 403);
    expect(calls, 2);
  });
}
