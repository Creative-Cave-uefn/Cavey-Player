// ffmpeg/ffprobe для караоке и умного перехода (automix). Скачиваются один раз
// в папку приложения и запускаются без окна консоли.
//
// Программы для скачки музыки (yt-dlp, Deno, Sockseek) ставит отдельный модуль
// cave-downloader (см. downloader/module.dart). Он кладёт их в ту же папку, поэтому
// ffmpeg, поставленный одним, подхватывает и другой.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'winproc.dart';

const _ffmpegUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip';

class Tools {
  final Directory dir;
  Tools(this.dir);

  File _f(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  File get ffmpeg => _f('ffmpeg.exe');
  File get ffprobe => _f('ffprobe.exe');

  bool get ready => ffmpeg.existsSync() && ffprobe.existsSync();

  /// Ставит ffmpeg и ffprobe, если их ещё нет
  Future<void> ensure(void Function(String) log) async {
    if (ready) return;
    await dir.create(recursive: true);
    final zip = _f('ffmpeg.zip');
    await download(_ffmpegUrl, zip, 'ffmpeg (больше 100 МБ, только один раз)', log, sha256: await _releaseDigest(_ffmpegUrl));
    log('Распаковываю ffmpeg…');
    await _extract(zip, {'ffmpeg.exe': ffmpeg, 'ffprobe.exe': ffprobe});
    await zip.delete();
    if (!ready) throw Exception('ffmpeg не удалось установить, проверьте интернет');
  }

  /// Скачивает файл через .part и сверяет SHA-256. Без [sha256] — предупреждает, что проверки не было
  static Future<void> download(String url, File dest, String label, void Function(String) log, {String? sha256}) async {
    log('Скачиваю $label…');
    final client = http.Client();
    final part = File('${dest.path}.part');
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'Mozilla/5.0');
      if (res.statusCode != 200) throw Exception('$label: сервер ответил ${res.statusCode}');
      final sink = part.openWrite();
      try {
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
      } finally {
        await sink.close();
      }
      if (sha256 != null) {
        final actual = (await crypto.sha256.bind(part.openRead()).first).toString();
        if (actual != sha256.toLowerCase()) throw Exception('$label: контрольная сумма не совпала, файл не используем');
      } else {
        log('  $label: контрольной суммы в релизе нет, проверка пропущена');
      }
      if (dest.existsSync()) await dest.delete();
      await part.rename(dest.path);
    } finally {
      client.close();
      if (part.existsSync()) {
        try {
          await part.delete();
        } catch (_) {}
      }
    }
  }

  /// sha256 файла из данных релиза GitHub (поле digest) для ссылок вида …/<владелец>/<репо>/releases/latest/download/<файл>
  static Future<String?> _releaseDigest(String url) async {
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
  /// обычный запуск из Dart открывал окно терминала.
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
