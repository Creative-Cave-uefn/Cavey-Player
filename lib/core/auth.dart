// Вход через Google для настольного приложения: открываем браузер, Google
// возвращает код на локальный адрес 127.0.0.1, меняем код на токены.
// Refresh-токен хранится локально, поэтому входить нужно один раз.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'store.dart';

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class Account {
  final String email;
  String name;
  String refreshToken;
  String? accessToken;
  DateTime? expiry;
  bool needsSignIn = false;

  Account({required this.email, required this.name, required this.refreshToken, this.accessToken, this.expiry});

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'refreshToken': refreshToken,
        'accessToken': accessToken,
        'expiry': expiry?.toIso8601String(),
      };

  static Account fromJson(Map j) => Account(
        email: j['email'] as String,
        name: (j['name'] as String?) ?? '',
        refreshToken: (j['refreshToken'] as String?) ?? '',
        accessToken: j['accessToken'] as String?,
        expiry: DateTime.tryParse((j['expiry'] as String?) ?? ''),
      );
}

class AccountManager extends ChangeNotifier {
  static const driveScope = 'https://www.googleapis.com/auth/drive';
  static const scopes = ['openid', 'email', 'profile', driveScope];

  static const noDriveAccess = 'Google не дал Cavey доступ к Диску. Войдите ещё раз и на странице разрешений '
      'отметьте галочку про Google Диск (или «Выбрать все»).';

  final AppStore store;
  final Settings settings;
  final List<Account> accounts = [];
  final Map<String, Future<String>> _refreshing = {};
  final http.Client _http = http.Client();

  /// Незавершённый вход: позволяет отменить ожидание браузера
  Completer<void>? _cancelSignIn;

  AccountManager(this.store, this.settings);

  String get clientId => settings.clientId;
  String get clientSecret => settings.clientSecret;
  bool get configured => clientId.isNotEmpty && clientSecret.isNotEmpty;
  bool get signingIn => _cancelSignIn != null;

  /// Ключи Google изменились — перерисовать экраны
  void configChanged() => notifyListeners();

  Account? byEmail(String email) {
    for (final a in accounts) {
      if (a.email == email) return a;
    }
    return null;
  }

  /// От чьего имени ставим лайки и создаём плейлисты
  Account? get primary {
    final p = settings.primaryEmail;
    return (p != null ? byEmail(p) : null) ?? (accounts.isNotEmpty ? accounts.first : null);
  }

  Future<void> load() async {
    final j = await store.readJson('accounts.json');
    if (j is List) {
      for (final a in j) {
        if (a is Map && a['email'] is String) accounts.add(Account.fromJson(a));
      }
    }
  }

  Future<void> _save() => store.writeJson('accounts.json', accounts.map((a) => a.toJson()).toList());

  void cancelSignIn() {
    final c = _cancelSignIn;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Открывает браузер, ждёт входа и добавляет (или обновляет) аккаунт.
  Future<Account> signIn({String? loginHint}) async {
    if (!configured) throw AuthException('Не заданы Client ID и Client secret');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _randomString(64);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _randomString(24);
    final cancel = Completer<void>();
    _cancelSignIn = cancel;
    notifyListeners();

    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent select_account',
      'state': state,
      if (loginHint != null) 'login_hint': loginHint,
    });

    final got = Completer<Map<String, String>>();
    final sub = server.listen((req) async {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ok = q.containsKey('code') && q['state'] == state;
      req.response.headers.contentType = ContentType.html;
      req.response.write(_resultPage(ok));
      await req.response.close();
      if (!got.isCompleted) got.complete(q);
    });

    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw AuthException('Не получилось открыть браузер для входа');
      }
      final result = await Future.any<Object?>([
        got.future,
        cancel.future.then((_) => null),
        Future<Object?>.delayed(const Duration(minutes: 5), () => 'timeout'),
      ]);
      if (result == null) throw AuthException('Вход отменён');
      if (result == 'timeout') throw AuthException('Вход не завершён за 5 минут. Попробуйте ещё раз.');
      final q = result as Map<String, String>;
      if (q['error'] != null) throw AuthException('Google отклонил вход: ${q['error']}');
      if (q['state'] != state) throw AuthException('Ответ от Google не прошёл проверку. Попробуйте ещё раз.');

      final tok = await _tokenRequest({
        'code': q['code']!,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      });
      final granted = ((tok['scope'] as String?) ?? '').split(' ');
      if (!granted.contains(driveScope)) {
        throw AuthException(noDriveAccess);
      }
      final access = tok['access_token'] as String;
      final refresh = tok['refresh_token'] as String?;
      final info = await _userInfo(access);
      final email = (info['email'] as String?) ?? '';
      if (email.isEmpty) throw AuthException('Google не вернул адрес почты');

      var acc = byEmail(email);
      if (acc == null) {
        acc = Account(email: email, name: (info['name'] as String?) ?? email, refreshToken: refresh ?? '');
        accounts.add(acc);
      }
      if (refresh != null) acc.refreshToken = refresh;
      acc.name = (info['name'] as String?) ?? acc.name;
      acc.accessToken = access;
      acc.expiry = DateTime.now().add(Duration(seconds: (tok['expires_in'] as num? ?? 3600).toInt()));
      acc.needsSignIn = false;
      settings.primaryEmail ??= email;
      await _save();
      return acc;
    } finally {
      await sub.cancel();
      await server.close(force: true);
      _cancelSignIn = null;
      notifyListeners();
    }
  }

  Future<void> remove(String email) async {
    accounts.removeWhere((a) => a.email == email);
    if (settings.primaryEmail == email) {
      settings.primaryEmail = accounts.isNotEmpty ? accounts.first.email : null;
    }
    settings.sourceAccess.removeWhere((_, v) => v == email);
    await _save();
    notifyListeners();
  }

  Future<void> setPrimary(String email) async {
    settings.primaryEmail = email;
    notifyListeners();
  }

  /// Действующий access-токен; при необходимости обновляет его.
  Future<String> token(String email, {bool force = false}) {
    final a = byEmail(email);
    if (a == null) return Future.error(AuthException('Аккаунт $email не подключён'));
    final exp = a.expiry;
    if (!force && a.accessToken != null && exp != null && exp.isAfter(DateTime.now().add(const Duration(minutes: 3)))) {
      return Future.value(a.accessToken!);
    }
    return _refreshing[email] ??= _refresh(a).whenComplete(() => _refreshing.remove(email));
  }

  Future<String> _refresh(Account a) async {
    if (a.refreshToken.isEmpty) {
      a.needsSignIn = true;
      notifyListeners();
      throw AuthException('Войдите в ${a.email} заново');
    }
    try {
      final tok = await _tokenRequest({
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': a.refreshToken,
        'grant_type': 'refresh_token',
      });
      a.accessToken = tok['access_token'] as String;
      a.expiry = DateTime.now().add(Duration(seconds: (tok['expires_in'] as num? ?? 3600).toInt()));
      a.needsSignIn = false;
      await _save();
      return a.accessToken!;
    } on AuthException catch (e) {
      if (e.message.contains('invalid_grant')) {
        a.needsSignIn = true;
        notifyListeners();
        throw AuthException('Вход в ${a.email} устарел. Войдите заново на вкладке «Аккаунты».');
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> form) async {
    final http.Response res;
    try {
      // Г1: без таймаута зависший ответ Google вешал вход и обновление токена навсегда
      res = await _http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: form).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw AuthException('Google не ответил вовремя. Проверьте интернет и повторите.');
    }
    final body = jsonDecode(res.body);
    if (res.statusCode != 200) {
      final err = body is Map ? '${body['error']}: ${body['error_description'] ?? ''}' : res.body;
      throw AuthException('Ошибка авторизации ($err)');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _userInfo(String access) async {
    final res = await _http.get(
      Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
      headers: {'Authorization': 'Bearer $access'},
    );
    if (res.statusCode != 200) throw AuthException('Не удалось узнать адрес почты аккаунта');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static String _randomString(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String _resultPage(bool ok) => '''<!doctype html><meta charset="utf-8">
<title>Cavey</title>
<body style="margin:0;height:100vh;display:grid;place-items:center;background:#12162A;color:#EDE9E1;font:18px system-ui,sans-serif">
<div style="text-align:center"><div style="font-size:40px;margin-bottom:12px">${ok ? '✓' : '✕'}</div>
${ok ? 'Вход выполнен. Вернитесь в Cavey, это окно можно закрыть.' : 'Вход не удался. Вернитесь в Cavey и попробуйте ещё раз.'}</div></body>''';
}
