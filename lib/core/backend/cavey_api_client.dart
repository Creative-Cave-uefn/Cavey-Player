// The first client for Cavey's own API. Not connected to production yet:
// existing Google Drive libraries and local accounts remain untouched.
//
// The backend MUST validate Google ID tokens on the server (signature,
// issuer, audience and expiry), use the stable "sub" claim as the identity
// key and issue its own session tokens. Never upload Google refresh tokens.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef CaveySessionTokenProvider = Future<String> Function();

class CaveyApiException implements Exception {
  final int? statusCode;
  final String message;

  const CaveyApiException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'Cavey API: $message'
      : 'Cavey API ($statusCode): $message';
}

/// Tokens returned by Cavey's server. They must be placed in platform-secure
/// storage (Keychain / Android Keystore / Windows credential storage), never
/// in existing accounts.json or in logs.
class CaveySession {
  final String userId;
  final String accessToken;
  final String refreshToken;

  const CaveySession({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
  });

  factory CaveySession.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final accessToken = json['access_token'];
    final refreshToken = json['refresh_token'];
    if (userId is! String || userId.isEmpty ||
        accessToken is! String || accessToken.isEmpty ||
        refreshToken is! String || refreshToken.isEmpty) {
      throw const FormatException('Cavey API: неполный ответ авторизации');
    }
    return CaveySession(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }
}

/// Retains the V1 library.json structure so existing track IDs, likes,
/// playlist references, edits and redirects survive the migration unchanged.
class CaveyLibrarySnapshot {
  final String revision;
  final Map<String, dynamic> library;

  const CaveyLibrarySnapshot({
    required this.revision,
    required this.library,
  });

  factory CaveyLibrarySnapshot.fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    final library = json['library'];
    if (revision is! String || revision.isEmpty || library is! Map) {
      throw const FormatException('Cavey API: неверный снимок библиотеки');
    }
    return CaveyLibrarySnapshot(
      revision: revision,
      library: Map<String, dynamic>.from(library),
    );
  }
}

class CaveyApiClient {
  final Uri baseUrl;
  final http.Client _client;
  final CaveySessionTokenProvider? tokenProvider;
  final bool _ownsClient;

  CaveyApiClient({
    required Uri baseUrl,
    this.tokenProvider,
    http.Client? client,
  })  : baseUrl = _validateBaseUrl(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  static Uri _validateBaseUrl(Uri url) {
    if (url.scheme.toLowerCase() != 'https' || url.host.isEmpty ||
        url.userInfo.isNotEmpty || url.hasQuery || url.hasFragment) {
      throw ArgumentError.value(url, 'baseUrl',
          'Cavey API требует HTTPS URL без credentials, query или fragment');
    }
    return url;
  }

  Uri _endpoint(List<String> segments) {
    // pathSegments escapes opaque IDs; never interpolate them into URL text.
    return baseUrl.replace(
      pathSegments: [
        ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
        'v1',
        ...segments,
      ],
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    List<String> segments, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    final request = http.Request(method, _endpoint(segments))
      ..headers['Accept'] = 'application/json';
    if (authenticated) {
      final provider = tokenProvider;
      if (provider == null) {
        throw const CaveyApiException('Для запроса нужна активная сессия Cavey');
      }
      final token = await provider();
      if (token.isEmpty) {
        throw const CaveyApiException('Сессия Cavey отсутствует');
      }
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const CaveyApiException('Сервер не ответил вовремя');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Intentionally do not echo server response bodies: they can contain
      // user data, internal error details or sensitive fields.
      throw CaveyApiException(
        response.statusCode == 409
            ? 'Библиотека была изменена другим устройством; перезагрузите снимок'
            : 'Запрос отклонён сервером',
        statusCode: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const FormatException('Cavey API: сервер вернул не JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('Cavey API: неверный формат ответа');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// Called only after platform-specific Google Sign-In produces an ID token.
  /// The backend verifies it and maps its "sub" to a permanent Cavey user ID.
  Future<CaveySession> exchangeGoogleIdToken(String idToken) async {
    if (idToken.trim().isEmpty) {
      throw ArgumentError.value('', 'idToken', 'Google ID token отсутствует');
    }
    final result = await _request(
      'POST',
      ['auth', 'google'],
      body: {'id_token': idToken},
      authenticated: false,
    );
    return CaveySession.fromJson(result);
  }

  Future<Map<String, dynamic>> getProfile() =>
      _request('GET', ['me']);

  Future<CaveyLibrarySnapshot> fetchLibrary(String libraryId) async {
    if (libraryId.isEmpty) throw ArgumentError.value(libraryId, 'libraryId');
    final result = await _request('GET', ['libraries', libraryId, 'snapshot']);
    return CaveyLibrarySnapshot.fromJson(result);
  }

  /// Optimistic concurrency + idempotent operations. Never drop or overwrite
  /// offline edits silently when a different device has changed the library.
  Future<CaveyLibrarySnapshot> commitOperations(
    String libraryId, {
    required String baseRevision,
    required String mutationId,
    required List<Map<String, dynamic>> operations,
  }) async {
    if (libraryId.isEmpty || baseRevision.isEmpty ||
        mutationId.isEmpty || operations.isEmpty) {
      throw const FormatException('Нужны библиотека, ревизия, ID операции и изменения');
    }
    final result = await _request(
      'POST',
      ['libraries', libraryId, 'operations'],
      body: {
        'base_revision': baseRevision,
        'mutation_id': mutationId,
        'operations': operations,
      },
    );
    return CaveyLibrarySnapshot.fromJson(result);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
