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
    final process = await Process.start(executable, [
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
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(log),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(log),
    ]);
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(hours: 2));
      await readers.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      throw Exception('Zotify не завершился вовремя. Проверьте вход в аккаунт в терминале.');
    }
    final files = await output.list(recursive: true, followLinks: false)
        .where((f) => f is File && f.path.toLowerCase().endsWith('.mp3'))
        .cast<File>().toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    if (code != 0) log('Zotify завершился с кодом $code; готовых файлов: ${files.length}');
    if (files.isEmpty) throw Exception('Zotify не создал аудиофайлы. Проверьте журнал выше; при ошибке авторизации заново войдите через кнопку в настройках.');
    return files;
  }
}

