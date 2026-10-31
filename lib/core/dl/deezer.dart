// Deezer as a single optional source via kmille/deezer-downloader 2.15.0.
// The auth cookie is stored only in a local tools config, never on Google Drive.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'tools.dart';
import 'winproc.dart';

class DeezerDownloadedTrack {
  final File file;
  final String artist;
  final String title;
  const DeezerDownloadedTrack(this.file, this.artist, this.title);
}

class DeezerDownloadResult {
  final int total;
  final int failed;
  final List<DeezerDownloadedTrack> tracks;
  const DeezerDownloadResult(this.total, this.failed, this.tracks);
}

class DeezerMusic {
  static const version = '2.15.0';
  static File python(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}deezer-python${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe');
  static File config(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}deezer_auth.ini');
  static File bridge(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}deezer_bridge.py');

  static bool accepts(String input) {
    final s = input.trim();
    if (s.isEmpty) return false;
    if (!s.contains('://')) {
      final parts = s.split(RegExp(r'\s+[-–—]\s+'));
      return parts.length == 2 && parts.every((part) => part.trim().isNotEmpty);
    }
    final uri = Uri.tryParse(s);
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty || uri.hasPort ||
        !['deezer.com', 'www.deezer.com'].contains(uri.host.toLowerCase())) return false;
    return RegExp(r'^/(?:[a-z]{2}(?:-[a-z]{2})?/)?(?:track|album|playlist)/\d+/?$', caseSensitive: false).hasMatch(uri.path);
  }

  static Future<void> prepareBridge(Tools tools) async {
    await tools.dir.create(recursive: true);
    final code = await rootBundle.loadString('assets/deezer_bridge.py');
    await bridge(tools).writeAsString(code, encoding: utf8);
  }

  static Future<void> prepareConfig(Tools tools) async {
    await tools.dir.create(recursive: true);
    final file = config(tools);
    if (await file.exists()) return;
    await file.writeAsString('[deezer]\r\n'
        '# Вставьте cookie arl из собственной сессии Deezer; не передавайте другим.\r\n'
        'arl = PASTE_ARL_COOKIE_HERE\r\n'
        '# mp3: 128 кбит/с для Free, до 320 кбит/с для Premium.\r\n'
        '# flac: доступно только при наличии lossless в подписке.\r\n'
        'quality = mp3\r\n', encoding: utf8);
  }

  static Future<int> _run(String exe, List<String> args, void Function(String) log) async {
    if (Platform.isWindows) return WinProc.run(exe, args, log);
    final p = await Process.start(exe, args, environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'});
    await Future.wait([
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(log),
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(log),
    ]);
    return p.exitCode;
  }

  static Future<void> install(Tools tools, void Function(String) log) async {
    if (!Platform.isWindows) throw UnsupportedError('Автоматическая установка Deezer доступна только для Windows.');
    await prepareBridge(tools);
    await prepareConfig(tools);
    final interpreter = python(tools);
    if (await interpreter.exists() &&
        await _run(interpreter.path, ['-c', 'import deezer_downloader; from importlib.metadata import version; assert version("deezer-downloader") == "$version"'], (_) {}) == 0) {
      log('deezer-downloader $version уже установлен.');
      return;
    }
    String? executable;
    List<String> prefix = const [];
    for (final candidate in <(String, List<String>)>[
      ('py.exe', ['-3.13']), ('py.exe', ['-3']), ('python.exe', []),
    ]) {
      try {
        if (await _run(candidate.$1, [...candidate.$2, '-c', 'import sys; assert (3, 10) <= sys.version_info[:2] < (4, 0)'], (_) {}) == 0) {
          executable = candidate.$1;
          prefix = candidate.$2;
          break;
        }
      } catch (_) {}
    }
    if (executable == null) throw Exception('Не найден Python 3.10+. Установите Python с python.org.');
    log('Создаю изолированное окружение Python…');
    final code = await _run(executable, [...prefix, '-m', 'venv', interpreter.parent.parent.path], log);
    if (code != 0 || !await interpreter.exists()) throw Exception('Не удалось создать Python venv (код $code).');
    log('Устанавливаю deezer-downloader $version…');
    final installed = await _run(interpreter.path,
        ['-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', 'deezer-downloader==$version'], log);
    if (installed != 0 || await _run(interpreter.path, ['-c', 'import deezer_downloader'], (_) {}) != 0) {
      throw Exception('Установка deezer-downloader не удалась (код $installed).');
    }
    log('Deezer готов. Откройте локальный конфиг и укажите cookie ARL.');
  }

  static Future<DeezerDownloadResult> download(Tools tools, String query, Directory output, void Function(String) log) async {
    if (!accepts(query)) throw FormatException('Deezer: используйте «Исполнитель - Название» или ссылку на трек, альбом или плейлист deezer.com.');
    if (!await python(tools).exists()) throw Exception('Deezer: сначала установите deezer-downloader в настройках.');
    if (!await config(tools).exists()) throw Exception('Deezer: сначала настройте cookie ARL в настройках.');
    await prepareBridge(tools);
    await output.create(recursive: true);
    final tracks = <DeezerDownloadedTrack>[];
    var total = 0, failed = 0;
    String? error;
    void receive(String line) {
      if (!line.startsWith('@cavedeezer:')) return;
      try {
        final entry = jsonDecode(line.substring('@cavedeezer:'.length));
        if (entry is! Map) return;
        switch (entry['type']) {
          case 'total':
            total = (entry['count'] as num?)?.toInt() ?? 0;
            log('Deezer: найдено $total треков.');
            break;
          case 'track':
            final file = File('${entry['file'] ?? ''}').absolute;
            final base = output.absolute.path.toLowerCase();
            if (!file.path.toLowerCase().startsWith('$base${Platform.pathSeparator}')) return;
            if (!['.mp3', '.flac'].any((extension) => file.path.toLowerCase().endsWith(extension))) return;
            tracks.add(DeezerDownloadedTrack(file, '${entry['artist'] ?? ''}', '${entry['title'] ?? ''}'));
            break;
          case 'failed':
            failed++;
            log('Deezer: недоступен трек «${entry['title'] ?? ''}».');
            break;
          case 'error':
            error = '${entry['message'] ?? 'Ошибка Deezer'}';
            break;
        }
      } catch (_) { /* Ignore malformed third-party output and never log credentials. */ }
    }
    final exitCode = await _run(python(tools).path, [bridge(tools).path,
      '--config', config(tools).absolute.path, '--output', output.absolute.path, '--input', query], receive);
    if (exitCode != 0 && tracks.isEmpty) throw Exception('Deezer: ${error ?? 'не удалось сохранить аудиофайл'} (код $exitCode).');
    if (tracks.isEmpty) throw Exception('Deezer: аудиофайлы не получены.');
    return DeezerDownloadResult(total > 0 ? total : tracks.length + failed, failed, tracks);
  }
}
