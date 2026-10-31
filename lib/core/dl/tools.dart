// Внешние программы загрузчика: yt-dlp, ffmpeg/ffprobe и Deno (нужен yt-dlp для YouTube).
// Скачиваются один раз в папку приложения. Запускаются без окна консоли.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'winproc.dart';

const _ytdlpUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe';
const _ffmpegUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip';
const _denoUrl = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip';

class Tools {
  final Directory dir;
  Tools(this.dir);

  File _f(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  File get ytdlp => _f('yt-dlp.exe');
  File get ffmpeg => _f('ffmpeg.exe');
  File get ffprobe => _f('ffprobe.exe');
  File get deno => _f('deno.exe');

  bool get ready => [ytdlp, ffmpeg, ffprobe, deno].every((f) => f.existsSync());

  List<String> get jsArgs => deno.existsSync() ? ['--js-runtimes', 'deno:${deno.path}'] : const [];

  Future<void> ensure(void Function(String) log) async {
    await dir.create(recursive: true);
    if (!ytdlp.existsSync()) await _download(_ytdlpUrl, ytdlp, 'yt-dlp', log);
    if (!ffmpeg.existsSync() || !ffprobe.existsSync()) {
      final zip = _f('ffmpeg.zip');
      await _download(_ffmpegUrl, zip, 'ffmpeg (больше 100 МБ, только один раз)', log);
      log('Распаковываю ffmpeg…');
      await _extract(zip, {'ffmpeg.exe': ffmpeg, 'ffprobe.exe': ffprobe});
      await zip.delete();
    }
    if (!deno.existsSync()) {
      final zip = _f('deno.zip');
      await _download(_denoUrl, zip, 'Deno', log);
      await _extract(zip, {'deno.exe': deno});
      await zip.delete();
    }
    if (!ready) throw Exception('не все программы загрузчика удалось установить, проверьте интернет');
  }

  /// yt-dlp часто ломается из-за изменений на YouTube: раз в неделю обновляем сам
  Future<void> updateIfOld(void Function(String) log) async {
    if (!ytdlp.existsSync()) return;
    if (DateTime.now().difference(ytdlp.lastModifiedSync()) < const Duration(days: 7)) return;
    await updateYtdlp(log);
  }

  Future<void> updateYtdlp(void Function(String) log) async {
    if (!ytdlp.existsSync()) {
      await ensure(log);
      return;
    }
    log('Проверяю обновления yt-dlp…');
    final out = await run(ytdlp.path, ['-U'], onLine: log);
    final ok = out.any((l) => l.contains('Updated yt-dlp') || l.contains('is up to date') || l.contains('up-to-date'));
    if (!ok) {
      log('Встроенное обновление не удалось, скачиваю свежую версию заново…');
      await _download(_ytdlpUrl, ytdlp, 'yt-dlp', log);
    } else {
      // отметка «проверено», чтобы не проверять каждый запуск
      ytdlp.setLastModifiedSync(DateTime.now());
    }
  }

  Future<String> version() async {
    if (!ytdlp.existsSync()) return 'не установлен';
    final out = await run(ytdlp.path, ['--version']);
    return out.isEmpty ? '?' : out.first.trim();
  }

  Future<void> _download(String url, File dest, String label, void Function(String) log) async {
    log('Скачиваю $label…');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'Mozilla/5.0');
      if (res.statusCode != 200) throw Exception('$label: сервер ответил ${res.statusCode}');
      final part = File('${dest.path}.part');
      final sink = part.openWrite();
      final total = res.contentLength ?? 0;
      var got = 0, mark = 10;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && got * 100 ~/ total >= mark) {
          log('  $label: ${got * 100 ~/ total}%');
          mark = (got * 100 ~/ total) ~/ 10 * 10 + 10;
        }
      }
      await sink.close();
      // В2: сверяем с контрольной суммой из данных релиза на GitHub; если её там нет — предупреждаем
      final expected = await _releaseDigest(url);
      if (expected != null) {
        final actual = (await crypto.sha256.bind(part.openRead()).first).toString();
        if (actual != expected) {
          await part.delete();
          throw Exception('$label: контрольная сумма не совпала, файл не используем');
        }
      } else {
        log('  $label: контрольной суммы в релизе нет, проверка пропущена');
      }
      if (dest.existsSync()) await dest.delete();
      await part.rename(dest.path);
    } finally {
      client.close();
    }
  }

  /// sha256 файла из данных релиза GitHub (поле digest) для ссылок вида …/<владелец>/<репо>/releases/latest/download/<файл>
  Future<String?> _releaseDigest(String url) async {
    final m = RegExp(r'github\.com/([^/]+/[^/]+)/releases/latest/download/([^/?]+)').firstMatch(url);
    if (m == null) return null;
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/${m[1]}/releases/latest'),
              headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      for (final a in (jsonDecode(res.body)['assets'] as List? ?? const [])) {
        if (a is Map && a['name'] == m[2]) {
          final d = '${a['digest'] ?? ''}';
          return d.startsWith('sha256:') ? d.substring(7).toLowerCase() : null;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _extract(File zip, Map<String, File> wanted) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final base = f.name.split('/').last.toLowerCase();
        final target = wanted[base];
        if (target == null) continue;
        final out = OutputFileStream(target.path);
        f.writeContent(out);
        await out.close();
      }
    } finally {
      await input.close();
    }
  }

  /// Запускает программу без окна консоли и возвращает строки её вывода.
  /// На Windows — через CreateProcess с CREATE_NO_WINDOW (см. winproc.dart):
  /// обычный запуск из Dart открывал окно терминала и для yt-dlp, и для всего,
  /// что он запускает сам.
  static Future<List<String>> run(String exe, List<String> args, {void Function(String)? onLine}) async {
    final lines = <String>[];
    void handle(String l) {
      final line = l.trimRight();
      if (line.isEmpty) return;
      lines.add(line);
      onLine?.call(line);
    }

    if (Platform.isWindows) {
      await WinProc.run(exe, args, handle);
      return lines;
    }
    final p = await Process.start(exe, args, environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'});
    await Future.wait([
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(handle),
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(handle),
    ]);
    await p.exitCode;
    return lines;
  }
}
