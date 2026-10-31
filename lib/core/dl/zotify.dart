import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs an already installed and authenticated Zotify, without a shell.
class Zotify {
  static File get credentialsFile {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final base = Platform.isWindows ? '$home/AppData/Roaming/Zotify'
        : Platform.isMacOS ? '$home/Library/Application Support/Zotify' : '$home/.local/share/zotify';
    final configBase = Platform.isLinux ? '$home/.config/zotify' : base;
    try {
      final config = jsonDecode(File('$configBase/config.json').readAsStringSync());
      final value = config is Map ? config['CREDENTIALS_LOCATION'] : null;
      if (value is String && value.trim().isNotEmpty) return File(value).absolute;
    } catch (_) {}
    return File('$base/credentials.json').absolute;
  }

  static Future<File> requireCredentials({File? file}) async {
    final target = file ?? credentialsFile;
    try {
      final j = jsonDecode(await target.readAsString());
      if (j is Map && j['username'] is String && (j['username'] as String).isNotEmpty &&
          ((j['auth_data'] is String && (j['auth_data'] as String).isNotEmpty) ||
           (j['credentials'] is String && (j['credentials'] as String).isNotEmpty))) return target;
    } catch (_) {}
    throw Exception('Нет сохранённого входа Zotify. Откройте настройки → «Войти в Spotify через браузер», завершите вход и повторите скачивание.');
  }

  static Future<File> pythonFor(String executable, {String? toolsDirectory}) async {
    final sibling = File('${File(executable).parent.path}${Platform.pathSeparator}python.exe');
    if (await sibling.exists()) return sibling.absolute;
    if (toolsDirectory != null) {
      final managed = File('$toolsDirectory/zotify-env/Scripts/python.exe');
      if (await managed.exists()) return managed.absolute;
    }
    throw Exception('Не найден Python окружения Zotify. Повторите установку в настройках.');
  }

  /// Never fall back to username/password prompts in a background download.
  static const runnerScript = r'''
import sys
from zotify.zotify import Zotify
from zotify.config import Config
from librespot.core import Session

def saved_login(cls, args):
    path = str(Config.get_credentials_location())
    try:
        config = Session.Configuration.Builder().set_store_credentials(False).build()
        cls.SESSION = Session.Builder(config).stored_file(path).create()
    except Exception as error:
        print('CAVE_AUTH_REJECTED: Saved Spotify session was rejected (' + type(error).__name__ +
              '). Sign in again using the browser button in Cave Player.', file=sys.stderr, flush=True)
        raise SystemExit(3)

Zotify.login = classmethod(saved_login)
from zotify.__main__ import main
main()
''';

  static bool accepts(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null) return false;
    if (uri.scheme == 'spotify') return RegExp(r'^spotify:(track|album|playlist):[A-Za-z0-9]+$').hasMatch(input);
    return uri.scheme == 'https' && uri.host == 'open.spotify.com' &&
        RegExp(r'^/(?:intl-[^/]+/)?(?:track|album|playlist)/[A-Za-z0-9]+/?$').hasMatch(uri.path);
  }

  static Future<List<File>> download(String executable, String input, Directory output, void Function(String) log, {String? ffmpegDirectory}) async {
    if (!accepts(input)) throw ArgumentError('Нужна ссылка Spotify на трек, альбом или плейлист');
    final credentials = await requireCredentials();
    var authRejected = false;
    void handle(String line) {
      if (line.startsWith('CAVE_AUTH_REJECTED:')) {
        authRejected = true;
        log('Spotify отклонил сохранённую сессию. Повторите вход через браузер в настройках.');
      } else {
        log(line);
      }
    }
    final python = await pythonFor(executable, toolsDirectory: ffmpegDirectory);
    final process = await Process.start(python.path, ['-u', '-c', runnerScript,
      '--credentials-location', credentials.path,
      '--root-path', output.path,
      '--output', '{artist} - {song_name} [{id}].{ext}',
      '--download-format', 'mp3',
      '--download-lyrics=False',
      '--skip-existing=False',
      '--skip-previously-downloaded=False',
      '--print-download-progress=False',
      '--print-downloads=True',
      input,
    ], environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8',
      if (ffmpegDirectory != null) 'PATH': '$ffmpegDirectory${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
    });
    await process.stdin.close(); // Login must be completed in a terminal beforehand.
    final readers = Future.wait([
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(handle),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(handle),
    ]);
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(hours: 2));
      await readers.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      throw Exception('Zotify не завершился вовремя. Проверьте вход в аккаунт в терминале.');
    }
    if (authRejected) throw Exception('Сохранённая сессия Spotify отклонена. Нажмите «Войти в Spotify через браузер». Если ошибка повторится после успешного входа, доступ через эту версию Librespot пока не подтверждён.');
    final files = await output.list(recursive: true, followLinks: false)
        .where((f) => f is File && f.path.toLowerCase().endsWith('.mp3'))
        .cast<File>().toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    if (code != 0) log('Zotify завершился с кодом $code; готовых файлов: ${files.length}');
    if (files.isEmpty) throw Exception('Zotify не создал аудиофайлы. Проверьте журнал выше; при ошибке авторизации заново войдите через кнопку в настройках.');
    return files;
  }
}

