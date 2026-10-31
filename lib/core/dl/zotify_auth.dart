import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tools.dart';
import 'zotify.dart';

/// Uses the installed librespot OAuth flow. The password is entered only on Spotify.
class ZotifyAuth {
  static bool _busy = false;

  static const script = r'''
import os
import shutil
import sys
import tempfile
from pathlib import Path
from librespot.core import Session

def main():
    destination = Path(sys.argv[1])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cave-login-', dir=destination.parent) as work:
        temporary = Path(work) / 'credentials.json'
        config = (Session.Configuration.Builder()
                  .set_cache_enabled(False)
                  .set_stored_credential_file(str(temporary)).build())
        def open_auth(url):
            print('CAVE_AUTH_URL ' + url, flush=True)
        session = Session.Builder(config).oauth(open_auth).create()
        session.close()
        if not temporary.is_file():
            raise RuntimeError('Spotify session did not save credentials')
        # Validate that the saved session can actually be reopened by the downloader.
        check_config = (Session.Configuration.Builder().set_cache_enabled(False)
                        .set_store_credentials(False).build())
        restored = Session.Builder(check_config).stored_file(str(temporary)).create()
        restored.close()
        if destination.is_file():
            shutil.copy2(destination, str(destination) + '.bak')
        os.replace(temporary, destination)
    print('CAVE_AUTH_OK', flush=True)

if __name__ == '__main__':
    main()
''';

  static Future<void> login(Tools tools, String executable,
      Future<void> Function(Uri) openBrowser, void Function(String) log) async {
    if (_busy) throw Exception('Вход Zotify уже выполняется');
    _busy = true;
    Process? process;
    try {
      final python = await Zotify.pythonFor(executable, toolsDirectory: tools.dir.path);
      final destination = Zotify.credentialsFile;
      final child = await Process.start(python.absolute.path, ['-u', '-c', script, destination.path],
          environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'});
      process = child;
      await child.stdin.close();
      var success = false;
      Future<void> line(String text) async {
        if (text.startsWith('CAVE_AUTH_URL ')) {
          final uri = Uri.parse(text.substring(14));
          if (uri.scheme != 'https' || uri.host != 'accounts.spotify.com' || uri.path != '/authorize') {
            throw Exception('Библиотека вернула неожиданный адрес входа');
          }
          await openBrowser(uri);
          log('Завершите вход на странице Spotify в браузере. Ожидаю подтверждение…');
        } else if (text.trim() == 'CAVE_AUTH_OK') {
          success = true;
        } else if (text.trim().isNotEmpty) {
          log(text);
        }
      }
      final output = Future.wait([
        child.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).asyncMap(line).drain<void>(),
        child.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).asyncMap(line).drain<void>(),
      ], eagerError: true);
      // Observe stream failures immediately as well as process exit; no leaked login process.
      await Future.wait([output, child.exitCode], eagerError: true).timeout(const Duration(minutes: 5));
      final code = await child.exitCode;
      if (code != 0 || !success) throw Exception('Вход Spotify не завершён (код $code). Подробности в журнале.');
      await Zotify.requireCredentials(file: destination);
      log('Вход Spotify сохранён. Можно скачивать через Zotify.');
    } on TimeoutException {
      throw Exception('Время входа истекло. Нажмите кнопку входа и попробуйте снова.');
    } finally {
      process?.kill();
      _busy = false;
    }
  }
}
