import 'dart:async';

import 'package:http/http.dart' as http;

/// GitHub API requests with ETag revalidation. A repeated check that gets
/// "304 Not Modified" reuses the previous answer and does not count against
/// GitHub's limit of 60 unauthenticated requests per hour.
class GithubCache {
  GithubCache._();

  static final _entries = <String, ({String etag, List<int> body})>{};

  static Future<http.Response> get(
    Uri url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 20),
    http.Client? client,
  }) async {
    final key = url.toString();
    final cached = _entries[key];
    final request = {...headers, if (cached != null) 'If-None-Match': cached.etag};
    final res = await (client == null ? http.get(url, headers: request) : client.get(url, headers: request)).timeout(timeout);
    if (res.statusCode == 304 && cached != null) {
      return http.Response.bytes(cached.body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }
    final etag = res.headers['etag'];
    if (res.statusCode == 200 && etag != null && etag.isNotEmpty) {
      _entries[key] = (etag: etag, body: res.bodyBytes);
    }
    return res;
  }

  /// For tests.
  static void clear() => _entries.clear();
}
