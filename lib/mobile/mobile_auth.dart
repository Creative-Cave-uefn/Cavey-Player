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

  @override
  Future<void> load() async {
    // Do not trust access tokens persisted by a different implementation.
    await super.load();
    accounts.clear();
    if (!configured) return;
    try {
      await _init();
      final user = await _google.attemptLightweightAuthentication();
      if (user == null) return;
      _active = user;
      final grant = await user.authorizationClient.authorizationForScopes(
        const [AccountManager.driveScope],
      );
      if (grant != null) {
        await _setUser(user);
      }
    } catch (_) {
      // First launch and revoked Android consent must still allow interactive
      // sign-in from the button in the UI.
      _active = null;
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

  @override
  Future<String> token(String email, {bool force = false}) async {
    await _init();
    var user = _active;
    if (user == null || user.email != email) {
      user = await _google.attemptLightweightAuthentication();
      if (user == null || user.email != email) {
        throw AuthException('Нужно повторно войти в Google: $email');
      }
      _active = user;
    }
    // Never open consent from a background Drive request. If access is revoked,
    // the user must use the login button to authorize Drive again.
    final grant = await user.authorizationClient.authorizationForScopes(
      const [AccountManager.driveScope],
    );
    if (grant == null || grant.accessToken.isEmpty) {
      byEmail(email)?.needsSignIn = true;
      notifyListeners();
      throw AuthException(AccountManager.noDriveAccess);
    }
    return grant.accessToken;
  }

  @override
  Future<void> remove(String email) async {
    await super.remove(email);
    if (_active?.email == email) {
      await _google.signOut();
      _active = null;
    }
  }
}
