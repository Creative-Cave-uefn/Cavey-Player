// Optional VK Music source: locally installed Python/VKpyMusic 4.0.2.
// VK login runs in a separate interactive terminal so passwords/2FA never
// enter Flutter settings, subprocess arguments or the shared Google Drive.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'tools.dart';
import 'winproc.dart';

class VkDownloadedTrack {
  final File file;
  final String artist;
  final String title;
  const VkDownloadedTrack(this.file, this.artist, this.title);
}

class VkDownloadResult {
  final int total;
  final int failed;
  final List<VkDownloadedTrack> tracks;
  const VkDownloadResult(this.total, this.failed, this.tracks);
}

class VkMusic {
  static const version = '4.0.2';
  static File python(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}vk-python${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe');
  static File config(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}vk_auth.ini');
  static File bridge(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}vk_bridge.py');
  static File loginLauncher(Tools tools) => File('${tools.dir.path}${Platform.pathSeparator}vk-login.cmd');

  static bool get windowsOnly => Platform.isWindows;
  static bool get acceptsSearch => true;

  static bool accepts(String input) {
    final value = input.trim();
    if (value.isEmpty) return false;
    if (!value.contains('://')) {
      final pieces = value.split(RegExp(r'\s+[-–—]\s+'));
      return pieces.length == 2 && pieces.every((s) => s.trim().isNotEmpty);
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty || uri.hasPort) return false;
    if (!['vk.com', 'm.vk.com', 'music.vk.com', 'vk.ru', 'm.vk.ru'].contains(uri.host.toLowerCase())) return false;
    return RegExp(r'(^|/)audio-?\d+_\d+($|/)|^/music/playlist/-?\d+_\d+(?:_[a-zA-Z0-9]+)?/?$').hasMatch(uri.path);
  }

  static Future<void> prepareBridge(Tools tools) async {
    await tools.dir.create(recursive: true);
    final code = await rootBundle.loadString('assets/vk_bridge.py');
    await bridge(tools).writeAsString(code, encoding: utf8);
  }

  static Future<int> _run(String exe, List<String> args, void Function(String) log) async {
    if (Platform.isWindows) return WinProc.run(exe, args, log);
    final p = await Process.start(exe, args, environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'});
    await Future.wait([
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(log),
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(log),
    ]);
    return p.exitCode;
  }

  /// Uses a private venv. Never installs Python packages into the system Python.
  static Future<void> install(Tools tools, void Function(String) log) async {
    if (!windowsOnly) throw UnsupportedError('Автоматическая установка VKpyMusic доступна только на Windows.');
    await prepareBridge(tools);
    final interpreter = python(tools);
    if (await interpreter.exists()) {
      if (await _run(interpreter.path, ['-c', 'import vkpymusic'], (_) {}) == 0) {
        log('VKpyMusic уже установлен.');
        return;
      }
    }
    String? executable;
    List<String> prefix = const [];
    final attempts = <String>[];
    for (final candidate in <(String, List<String>)>[
      ('py.exe', ['-3.13']), ('py.exe', ['-3']), ('python.exe', []),
    ]) {
      final name = [candidate.$1, ...candidate.$2].join(' ');
      try {
        final code = await _run(candidate.$1, [...candidate.$2, '-c', 'import sys; assert sys.version_info >= (3, 10)'], (_) {});
        if (code == 0) {
          executable = candidate.$1;
          prefix = candidate.$2;
          break;
        }
        attempts.add('$name: код $code');
      } catch (e) {
        attempts.add('$name: $e');
      }
    }
    if (executable == null) {
      final details = attempts.isEmpty ? '' : '\nПроверено: ${attempts.join('; ')}';
      throw Exception('Не найден Python 3.10+ (рекомендуется 3.13). Установите Python с python.org и повторите установку VKpyMusic.$details');
    }
    log('Создаю локальное окружение Python…');
    final code = await _run(executable, [...prefix, '-m', 'venv', interpreter.parent.parent.path], log);
    if (code != 0 || !await interpreter.exists()) throw Exception('Не удалось создать Python venv (код $code).');
    log('Устанавливаю VKpyMusic $version и зависимости…');
    final installed = await _run(interpreter.path,
        ['-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', 'vkpymusic==$version'], log);
    if (installed != 0 || await _run(interpreter.path, ['-c', 'import vkpymusic'], (_) {}) != 0) {
      throw Exception('Установка VKpyMusic не удалась (код $installed). Проверьте журнал.');
    }
    log('VKpyMusic готов. Теперь нажмите «Войти в VK».');
  }

  /// Opens an interactive console for login, captcha and 2FA (if requested by VK).
  static Future<void> openLogin(Tools tools) async {
    if (!windowsOnly) throw UnsupportedError('Вход в VK реализован для Windows.');
    if (!await python(tools).exists()) throw Exception('Сначала установите VKpyMusic.');
    await prepareBridge(tools);
    // Do not interpolate user input into cmd.exe. Paths are application-managed.
    final cmd = loginLauncher(tools);
    String quote(String s) => '"${s.replaceAll('%', '%%').replaceAll('"', '')}"';
    await cmd.writeAsString('@echo off\r\nchcp 65001 >nul\r\n'
        '${quote(python(tools).absolute.path)} ${quote(bridge(tools).absolute.path)} auth --config ${quote(config(tools).absolute.path)}\r\n'
        'echo.\r\necho You can close this window.\r\npause\r\n', encoding: utf8);
    await Process.start('cmd.exe', ['/k', cmd.absolute.path], mode: ProcessStartMode.detached);
  }

  /// Only accepts our JSON protocol. Never forwards raw library output or tokens.
  static Future<VkDownloadResult> download(Tools tools, String query, Directory output, void Function(String) log) async {
    if (!accepts(query)) throw FormatException('VK: используйте «Исполнитель - Название», ссылку audio<ID>_<ID> или ссылку music/playlist/.');
    if (!await python(tools).exists()) throw Exception('VK: сначала установите VKpyMusic в настройках.');
    if (!await config(tools).exists()) throw Exception('VK: сначала нажмите «Войти в VK» в настройках загрузчика.');
    await prepareBridge(tools);
    await output.create(recursive: true);
    final tracks = <VkDownloadedTrack>[];
    var total = 0, failed = 0;
    String? error;
    void receive(String line) {
      if (!line.startsWith('@cavevk:')) return;
      try {
        final entry = jsonDecode(line.substring('@cavevk:'.length));
        if (entry is! Map) return;
        switch (entry['type']) {
          case 'total':
            total = (entry['count'] as num?)?.toInt() ?? 0;
            log('VK: найдено $total треков.');
            break;
          case 'track':
            final path = '${entry['file'] ?? ''}';
            final file = File(path).absolute;
            final base = output.absolute.path;
            // Ignore paths outside the temporary job directory.
            if (!file.path.toLowerCase().startsWith('${base.toLowerCase()}${Platform.pathSeparator}')) return;
            if (!file.path.toLowerCase().endsWith('.mp3')) return;
            tracks.add(VkDownloadedTrack(file, '${entry['artist'] ?? ''}', '${entry['title'] ?? ''}'));
            break;
          case 'failed':
            failed++;
            log('VK: недоступен трек «${entry['title'] ?? ''}».');
            break;
          case 'error':
            error = '${entry['message'] ?? 'Ошибка VKpyMusic'}';
            break;
        }
      } catch (_) { /* Ignore malformed output; no sensitive diagnostics. */ }
    }
    final exitCode = await _run(python(tools).path, [bridge(tools).path, 'download',
      '--config', config(tools).absolute.path, '--output', output.absolute.path, '--input', query], receive);
    if (tracks.isEmpty) throw Exception('VK: ${error ?? 'нет доступных для сохранения аудиофайлов'} (код $exitCode).');
    // A partial playlist is still returned, so the caller can upload what worked.
    return VkDownloadResult(total > 0 ? total : tracks.length + failed, failed, tracks);
  }
}
