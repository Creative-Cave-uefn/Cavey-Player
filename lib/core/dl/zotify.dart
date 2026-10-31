import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs an already installed and authenticated Zotify, without a shell.
class Zotify {
  static bool accepts(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null) return false;
    if (uri.scheme == 'spotify') return RegExp(r'^spotify:(track|album|playlist):[A-Za-z0-9]+$').hasMatch(input);
    return uri.scheme == 'https' && uri.host == 'open.spotify.com' &&
        RegExp(r'^/(?:intl-[^/]+/)?(?:track|album|playlist)/[A-Za-z0-9]+/?$').hasMatch(uri.path);
  }

  static Future<List<File>> download(String executable, String input, Directory output, void Function(String) log, {String? ffmpegDirectory}) async {
    if (!accepts(input)) throw ArgumentError('Нужна ссылка Spotify на трек, альбом или плейлист');
    final process = await Process.start(executable, [
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
    if (files.isEmpty) throw Exception('Zotify не создал аудиофайлы. Установите Zotify и FFmpeg и выполните вход через Zotify в терминале.');
    return files;
  }
}

