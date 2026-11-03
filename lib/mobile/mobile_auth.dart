import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

import '../core/auth.dart';
import '../core/log.dart';

/// OAuth Client ID of type "Web application" in the same Google Cloud project.
/// Android additionally requires a separate Android OAuth client with the right
/// applicationId and SHA-1. No client secret or refresh token is embedded in APK.
const mobileWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

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
  bool get configured => mobileWebClientId.isNotEmpty;

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
          final email = a['email'] as String;
          accounts.add(Account(email: email, name: '${a['name'] ?? email}', refreshToken: ''));
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

  void _markNeedsSignIn(String email) {
    final acc = byEmail(email);
    if (acc != null && !acc.needsSignIn) {
      acc.needsSignIn = true;
      notifyListeners();
    }
  }

  /// Токен Диска живёт около часа: держим его в памяти и не дёргаем Google на каждый запрос
  final Map<String, ({String token, DateTime until})> _tokens = {};

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
    _tokens[email] = (token: grant.accessToken, until: DateTime.now().add(const Duration(minutes: 45)));
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
    if (_active?.email == email) {
      await _google.signOut();
      _active = null;
    }
  }
}
