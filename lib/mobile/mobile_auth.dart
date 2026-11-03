import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/auth.dart';
import '../core/log.dart';

/// OAuth Client ID of type "Web application" in the same Google Cloud project.
/// Android additionally requires a separate Android OAuth client with the right
/// applicationId and SHA-1. No client secret or refresh token is embedded in APK.
const mobileWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

/// OAuth Client ID типа «Android» (пакет app.cavey.cave_player + SHA-1). Если он задан, вход идёт через браузер
/// с PKCE и приложение получает refresh-токен: дальше токены обновляются тихо, без проверок аккаунта.
/// Client secret для такого клиента не нужен. Если не задан — прежний вход через Google Play Services.
const mobileAndroidClientId = String.fromEnvironment('GOOGLE_ANDROID_CLIENT_ID');

/// Схема возврата в приложение: обратная запись Client ID
String get _redirectUri {
  final base = mobileAndroidClientId.replaceAll('.apps.googleusercontent.com', '');
  return 'com.googleusercontent.apps.$base:/oauth2redirect';
}

/// Конец Web Client ID для диагностики (целиком его показывать не нужно)
String mobileClientHint() => mobileWebClientId.isEmpty
    ? 'не задан'
    : '${mobileWebClientId.split('-').first}-…${mobileWebClientId.endsWith('.apps.googleusercontent.com') ? '' : ' (формат неверный: нужен …apps.googleusercontent.com)'}';

/// Android uses Google Play Services instead of the desktop loopback server.
/// The existing DriveApi and LibraryController can use this AccountManager.
class MobileAccountManager extends AccountManager {
  MobileAccountManager(super.store, super.settings);

  final GoogleSignIn _google = GoogleSignIn.instance;
  GoogleSignInAccount? _active;
  bool _initialized = false;

  @override
  bool get configured => mobileWebClientId.isNotEmpty || mobileAndroidClientId.isNotEmpty;

  bool get _useBrowserFlow => mobileAndroidClientId.isNotEmpty;

  static const _authChannel = MethodChannel('cavey/auth');
  final http.Client _web = http.Client();
  final Map<String, Future<String>> _refreshingTokens = {};
  Completer<String>? _pendingRedirect;

  Future<void> _init() async {
    if (_initialized) return;
    if (!Platform.isAndroid) throw AuthException('Эта точка входа предназначена для Android');
    if (!configured) {
      throw AuthException('Не задан GOOGLE_WEB_CLIENT_ID при сборке APK');
    }
    await _google.initialize(serverClientId: mobileWebClientId);
    _initialized = true;
  }

  /// Вход запоминается на телефоне: при запуске Google не опрашиваем вообще, поэтому приложение
  /// открывается сразу. Токен для Диска берётся позже, когда он понадобится ([token]);
  /// если Google его не даст — показывается плашка «войдите снова», а не экран входа.
  @override
  Future<void> load() async {
    accounts.clear();
    final j = await store.readJson('accounts.json');
    if (j is List) {
      for (final a in j) {
        if (a is Map && a['email'] is String) {
          accounts.add(Account.fromJson(a));
        }
      }
    }
    notifyListeners();
  }

  Future<Account> _setUser(GoogleSignInAccount user) async {
    accounts.clear();
    final account = Account(
      email: user.email,
      name: user.displayName ?? user.email,
      refreshToken: '',
    );
    accounts.add(account);
    settings.primaryEmail = user.email;
    // Google Play Services owns its credentials. Persist only account metadata.
    await store.writeJson('accounts.json', [
      {'email': account.email, 'name': account.name},
    ]);
    await store.writeJson('settings.json', settings.toJson());
    notifyListeners();
    return account;
  }

  @override
  Future<Account> signIn({String? loginHint}) async {
    if (_useBrowserFlow) return _signInBrowser(loginHint);
    await _init();
    var step = 'выбор аккаунта';
    try {
      // Android Google Sign In currently supports one active user at a time.
      // Re-authenticate explicitly for account switching.
      final user = await _google.authenticate(
        scopeHint: const [AccountManager.driveScope],
      );
      step = 'доступ к Google Диску';
      final grant = await user.authorizationClient.authorizationForScopes(
            const [AccountManager.driveScope],
          ) ??
          await user.authorizationClient.authorizeScopes(
            const [AccountManager.driveScope],
          );
      if (grant.accessToken.isEmpty) {
        throw AuthException(AccountManager.noDriveAccess);
      }
      _active = user;
      return await _setUser(user);
    } on GoogleSignInException catch (e) {
      AppLog.error('Вход через Google, шаг «$step»', e);
      throw AuthException('Не удалось подключить Google (шаг: $step): $e\n'
          'Клиент: ${mobileClientHint()}');
    }
  }


  // ---------- Вход через браузер (PKCE) и тихое обновление токена по refresh-токену ----------

  static String _rand(int n) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<Map<String, dynamic>> _post(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await _web
          .post(Uri.parse('https://oauth2.googleapis.com/token'), body: form)
          .timeout(const Duration(seconds: 30));
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

  Future<Account> _signInBrowser(String? loginHint) async {
    final verifier = _rand(64);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _rand(24);
    // Новый вход отменяет прежний, если тот ещё ждёт браузер
    final old = _pendingRedirect;
    if (old != null && !old.isCompleted) old.completeError(AuthException('Вход отменён'));
    final waiting = _pendingRedirect = Completer<String>();
    _authChannel.setMethodCallHandler((call) async {
      if (call.method == 'redirect' && !waiting.isCompleted) waiting.complete(call.arguments as String);
    });
    try {
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': mobileAndroidClientId,
        'redirect_uri': _redirectUri,
        'response_type': 'code',
        'scope': AccountManager.scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent select_account',
        'state': state,
        if (loginHint != null) 'login_hint': loginHint,
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw AuthException('Не получилось открыть браузер для входа');
      }
      final back = Uri.parse(await waiting.future.timeout(const Duration(minutes: 5),
          onTimeout: () => throw AuthException('Вход не завершён за 5 минут. Попробуйте ещё раз.')));
      final q = back.queryParameters;
      if (q['error'] != null) throw AuthException('Google отклонил вход: ${q['error']}');
      if (q['state'] != state || q['code'] == null) {
        throw AuthException('Ответ от Google не прошёл проверку. Попробуйте ещё раз.');
      }
      final tok = await _post({
        'code': q['code']!,
        'client_id': mobileAndroidClientId,
        'redirect_uri': _redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      });
      if (!((tok['scope'] as String?) ?? '').split(' ').contains(AccountManager.driveScope)) {
        throw AuthException(AccountManager.noDriveAccess);
      }
      final access = tok['access_token'] as String;
      final refresh = tok['refresh_token'] as String?;
      final info = await _web.get(Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
          headers: {'Authorization': 'Bearer $access'});
      if (info.statusCode != 200) throw AuthException('Не удалось узнать адрес почты аккаунта');
      final j = jsonDecode(info.body) as Map;
      final email = (j['email'] as String?) ?? '';
      if (email.isEmpty) throw AuthException('Google не вернул адрес почты');
      var acc = byEmail(email);
      if (acc == null) {
        acc = Account(email: email, name: (j['name'] as String?) ?? email, refreshToken: refresh ?? '');
        accounts.add(acc);
      }
      if (refresh != null) acc.refreshToken = refresh;
      acc.name = (j['name'] as String?) ?? acc.name;
      acc.accessToken = access;
      acc.expiry = DateTime.now().add(Duration(seconds: (tok['expires_in'] as num? ?? 3600).toInt()));
      acc.needsSignIn = false;
      settings.primaryEmail ??= email;
      await _persist();
      await store.writeJson('settings.json', settings.toJson());
      notifyListeners();
      return acc;
    } finally {
      _authChannel.setMethodCallHandler(null);
      if (identical(_pendingRedirect, waiting)) _pendingRedirect = null;
    }
  }

  Future<void> _persist() => store.writeJson('accounts.json', accounts.map((a) => a.toJson()).toList());

  Future<String> _tokenByRefresh(Account a, bool force) {
    final exp = a.expiry;
    if (!force && a.accessToken != null && exp != null && exp.isAfter(DateTime.now().add(const Duration(minutes: 3)))) {
      return Future.value(a.accessToken!);
    }
    return _refreshingTokens[a.email] ??= _doRefresh(a).whenComplete(() => _refreshingTokens.remove(a.email));
  }

  Future<String> _doRefresh(Account a) async {
    AuthException? last;
    for (var i = 0; i < 3; i++) {
      try {
        final tok = await _post({
          'client_id': mobileAndroidClientId,
          'refresh_token': a.refreshToken,
          'grant_type': 'refresh_token',
        });
        a.accessToken = tok['access_token'] as String;
        a.expiry = DateTime.now().add(Duration(seconds: (tok['expires_in'] as num? ?? 3600).toInt()));
        if (a.needsSignIn) {
          a.needsSignIn = false;
          notifyListeners();
        }
        await _persist();
        return a.accessToken!;
      } on AuthException catch (e) {
        // Токен отозван или устарел — только тогда просим войти заново
        if (e.message.contains('invalid_grant')) {
          _markNeedsSignIn(a.email);
          throw AuthException('Вход в ${a.email} устарел. Войдите заново.');
        }
        last = e;
      } catch (e) {
        AppLog.warn('Google: обновление токена, попытка ${i + 1}', e);
        last = AuthException('Нет связи с Google. Проверьте интернет.');
      }
      if (i < 2) await Future<void>.delayed(Duration(milliseconds: 600 * (i + 1)));
    }
    throw last ?? AuthException('Не удалось обновить токен Google');
  }

  void _markNeedsSignIn(String email) {
    final acc = byEmail(email);
    if (acc != null && !acc.needsSignIn) {
      acc.needsSignIn = true;
      notifyListeners();
    }
  }

  /// Токен Диска живёт около часа: держим его в памяти и не дёргаем Google на каждый запрос
  final Map<String, ({String token, DateTime until})> _tokens = {};
  bool _tokensLoaded = false;

  /// Токен переживает перезапуск приложения (файл в закрытом хранилище приложения): пока он действует,
  /// при входе в приложение к Google не обращаемся вообще, и никаких проверок аккаунта нет
  Future<void> _loadTokens() async {
    if (_tokensLoaded) return;
    _tokensLoaded = true;
    try {
      final j = await store.readJson('mobile_tokens.json');
      if (j is Map) {
        j.forEach((email, v) {
          if (v is Map && v['t'] is String && v['u'] is int) {
            _tokens[email as String] = (
              token: v['t'] as String,
              until: DateTime.fromMillisecondsSinceEpoch(v['u'] as int),
            );
          }
        });
      }
    } catch (e) {
      AppLog.warn('Не удалось прочитать сохранённый токен', e);
    }
  }

  Future<void> _saveTokens() async {
    try {
      await store.writeJson('mobile_tokens.json', {
        for (final e in _tokens.entries) e.key: {'t': e.value.token, 'u': e.value.until.millisecondsSinceEpoch},
      });
    } catch (e) {
      AppLog.warn('Не удалось сохранить токен', e);
    }
  }

  /// Обращение к Google с повтором: сбой сети или занятый Play Services не повод просить войти заново
  Future<T?> _retry<T>(Future<T?> Function() job) async {
    for (var i = 0; i < 3; i++) {
      try {
        final r = await job();
        if (r != null) return r;
      } catch (e) {
        AppLog.warn('Google: попытка ${i + 1} не удалась', e);
      }
      if (i < 2) await Future<void>.delayed(Duration(milliseconds: 600 * (i + 1)));
    }
    return null;
  }

  @override
  Future<String> token(String email, {bool force = false}) async {
    final own = byEmail(email);
    if (_useBrowserFlow && own != null && own.refreshToken.isNotEmpty) return _tokenByRefresh(own, force);
    await _loadTokens();
    final cached = _tokens[email];
    if (!force && cached != null && cached.until.isAfter(DateTime.now())) return cached.token;
    await _init();
    var user = _active;
    if (user == null || user.email != email) {
      user = await _retry<GoogleSignInAccount>(() async => await _google.attemptLightweightAuthentication());
      if (user == null || user.email != email) {
        // Плашку «войдите снова» показываем только когда Google точно не вспомнил аккаунт
        _markNeedsSignIn(email);
        throw AuthException('Нужно повторно войти в Google: $email');
      }
      _active = user;
    }
    // Never open consent from a background Drive request. If access is revoked,
    // the user must use the login button to authorize Drive again.
    final u = user;
    final grant = await _retry(() => u.authorizationClient.authorizationForScopes(const [AccountManager.driveScope]));
    if (grant == null || grant.accessToken.isEmpty) {
      _markNeedsSignIn(email);
      throw AuthException(AccountManager.noDriveAccess);
    }
    _tokens[email] = (token: grant.accessToken, until: DateTime.now().add(const Duration(minutes: 50)));
    await _saveTokens();
    final acc = byEmail(email);
    if (acc != null && acc.needsSignIn) {
      acc.needsSignIn = false;
      notifyListeners();
    }
    return grant.accessToken;
  }

  @override
  Future<void> remove(String email) async {
    await super.remove(email);
    _tokens.remove(email);
    await _saveTokens();
    if (_active?.email == email) {
      await _google.signOut();
      _active = null;
    }
  }
}
