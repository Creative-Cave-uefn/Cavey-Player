// Sockseek (AGPL-3.0): https://github.com/fiso64/sockseek
// Kept as a separate executable; Soulseek credentials stay in its local config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'text.dart';
import 'tools.dart';
import 'winproc.dart';

class Sockseek {
  static const version = '3.0.6';
  static const downloadUrl = 'https://github.com/fiso64/sockseek/releases/download/v3.0.6/sockseek_3.0.6_win-x64.zip';
  static const digest = 'aa965bdf3bc9b04757380889e1ce96ce1d57fdf89423fb3f7ebf378e469e66c4';
  static File executable(Tools tools) => File('${tools.dir.path}/sockseek-$version/sockseek.exe');
  static File config(Tools tools) => File('${tools.dir.path}/sockseek.conf');

  static Future<void> prepareConfig(Tools tools) async {
    final file = config(tools);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    await file.writeAsString('# Soulseek account, NOT Spotify. Saved locally in plain text.\n'
        '# Edit the two values, save this file, then return to Cave Player.\n'
        'username = YOUR_SOULSEEK_USERNAME\npassword = YOUR_SOULSEEK_PASSWORD\n');
  }

  static Future<void> install(Tools tools, void Function(String) log) async {
    if (!Platform.isWindows) throw Exception('Автоустановка Sockseek доступна на Windows x64.');
    final exe = executable(tools);
    if (await exe.exists()) {
      log('Sockseek $version уже установлен.');
      return;
    }
    await tools.dir.create(recursive: true);
    final zip = File('${tools.dir.path}/sockseek-$version.zip.part');
    final staging = Directory('${exe.parent.path}.staging');
    final client = http.Client();
    try {
      log('Скачиваю Sockseek $version с GitHub…');
      final response = await client.send(http.Request('GET', Uri.parse(downloadUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw Exception('GitHub: HTTP ${response.statusCode}');
      final sink = zip.openWrite();
      try {
        var received = 0, next = 10;
        await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          final total = response.contentLength ?? 0;
          if (total > 0 && received * 100 ~/ total >= next) {
            log('Sockseek: ${received * 100 ~/ total}%');
            next += 10;
          }
        }
      } finally {
        await sink.close();
      }
      if ((await sha256.bind(zip.openRead()).first).toString() != digest) {
        throw Exception('Контрольная сумма Sockseek не совпала.');
      }
      log('Контрольная сумма SHA-256 проверена. Распаковываю…');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final input = InputFileStream(zip.path);
      try {
        for (final entry in ZipDecoder().decodeBuffer(input).files) {
          final name = entry.name.replaceAll('\\', '/');
          if (name.startsWith('/') || name.contains(':') || name.split('/').contains('..') || entry.isSymbolicLink) {
            throw Exception('Недопустимый путь в архиве Sockseek.');
          }
          if (!entry.isFile) continue;
          final file = File('${staging.path}/$name');
          await file.parent.create(recursive: true);
          final out = OutputFileStream(file.path);
          try { entry.writeContent(out); } finally { await out.close(); }
        }
      } finally { await input.close(); }
      final stagedExe = File('${staging.path}/sockseek.exe');
      if (!await stagedExe.exists()) throw Exception('В архиве нет sockseek.exe.');
      final code = await WinProc.run(stagedExe.absolute.path, ['--help'], (_) {});
      if (code != 0) throw Exception('Sockseek не запускается, код $code.');
      if (await exe.parent.exists()) await exe.parent.delete(recursive: true);
      await staging.rename(exe.parent.path);
      await prepareConfig(tools);
      log('Sockseek $version установлен. Заполните локальный конфиг Soulseek.');
    } finally {
      client.close();
      if (await zip.exists()) await zip.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static String csv(List<TrackMeta> tracks) {
    String cell(String value) => '"${value.replaceAll('"', '""')}"';
    return 'artist,title,album,length\r\n${tracks.map((t) => [t.artist, t.title, t.album,
      t.duration != null && t.duration! > 0 ? '${t.duration!.round()}' : ''].map(cell).join(',')).join('\r\n')}\r\n';
  }

  static List<String> arguments(String input, String output, String configPath) => [
    input, '--input-type', 'csv', '--config', configPath, '--output-dir', output,
    '--strict-title', '--strict-artist', '--strict-conditions', '--length-tol', '3',
    '--concurrent-jobs', '1', '--concurrent-searches', '1', '--search-timeout', '12000',
    '--no-progress', '--no-write-index',
  ];

  static bool completedAudio(String path) =>
      RegExp(r'\.(flac|mp3|m4a|ogg|opus|wav|aac|alac)$', caseSensitive: false).hasMatch(path) &&
      !path.toLowerCase().contains('.incomplete');

  static Future<List<File>> download(Tools tools, List<TrackMeta> tracks, Directory temp,
      void Function(String) log) async {
    final exe = executable(tools);
    if (!await exe.exists()) throw Exception('Установите Sockseek в настройках загрузчика.');
    await prepareConfig(tools);
    final cfg = config(tools);
    final text = await cfg.readAsString();
    if (text.contains('YOUR_SOULSEEK_') ||
        !RegExp(r'^\s*username\s*=\s*\S+', multiLine: true).hasMatch(text) ||
        !RegExp(r'^\s*password\s*=\s*\S+', multiLine: true).hasMatch(text)) {
      throw Exception('Откройте конфиг Soulseek в настройках, укажите username и password, сохраните файл.');
    }
    final input = File('${temp.path}/tracks.csv');
    await input.writeAsString(csv(tracks));
    final output = Directory('${temp.path}/audio');
    await output.create();
    log('Sockseek: ${tracks.length} треков; строгое совпадение исполнителя/названия, длительность ±3 с, если известна.');
    // Never pass credentials on the command line or forward raw config diagnostics.
    final secrets = RegExp(r'^\s*(?:username|password)\s*=\s*(.+)$', multiLine: true)
        .allMatches(text).map((m) => m[1]!.trim()).where((s) => s.isNotEmpty).toList();
    void line(String value) {
      for (final secret in secrets) { value = value.replaceAll(secret, '[скрыто]'); }
      value = value.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
      if (value.trim().isNotEmpty) log(value);
    }
    final args = arguments(input.absolute.path, output.absolute.path, cfg.absolute.path);
    final code = Platform.isWindows
        ? await WinProc.run(exe.absolute.path, args, line)
        : await _run(exe.absolute.path, args, line);
    final files = <File>[];
    await for (final entry in output.list(recursive: true, followLinks: false)) {
      if (entry is File && completedAudio(entry.path) && await entry.length() > 0) files.add(entry);
    }
    log('Sockseek завершился с кодом $code; готовых файлов: ${files.length}/${tracks.length}.');
    if (files.isEmpty) throw Exception('Sockseek не нашёл доступных файлов с нужными метаданными. '
        'Проверьте журнал и аккаунт Soulseek. Повторная попытка может найти других пользователей.');
    return files;
  }

  static Future<int> _run(String exe, List<String> args, void Function(String) line) async {
    final process = await Process.start(exe, args);
    await process.stdin.close();
    await Future.wait([process.stdout, process.stderr].map((s) => s.transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()).forEach(line)));
    return process.exitCode;
  }
}
