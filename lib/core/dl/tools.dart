// FFmpeg helper for playback analysis and karaoke ONLY.
// Music extraction, yt-dlp, Deno and provider credentials reside in Cavey-Downloader.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

import 'winproc.dart';

const _ffmpegRelease =
    'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip';

class Tools {
  final Directory dir;
  Tools(this.dir);

  File get ffmpeg => File('${dir.path}${Platform.pathSeparator}ffmpeg.exe');
  File get ffprobe => File('${dir.path}${Platform.pathSeparator}ffprobe.exe');

  Future<void> ensure(void Function(String) log) async {
    if (await ffmpeg.exists() && await ffprobe.exists()) return;
    await dir.create(recursive: true);
    log('Устанавливаю FFmpeg для анализа аудио…');
    final zip = File('${dir.path}${Platform.pathSeparator}ffmpeg-analysis.zip.part');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(_ffmpegRelease))
        ..headers['User-Agent'] = 'Cavey-Player';
      final response = await client.send(request).timeout(const Duration(seconds: 40));
      if (response.statusCode != 200) {
        throw HttpException('FFmpeg: HTTP ${response.statusCode}');
      }
      final sink = zip.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final stream = InputFileStream(zip.path);
      try {
        final archive = ZipDecoder().decodeBuffer(stream);
        for (final item in archive.files) {
          if (!item.isFile) continue;
          final name = item.name.split('/').last.toLowerCase();
          if (name != 'ffmpeg.exe' && name != 'ffprobe.exe') continue;
          final dest = name == 'ffmpeg.exe' ? ffmpeg : ffprobe;
          final output = OutputFileStream(dest.path);
          item.writeContent(output);
          await output.close();
        }
      } finally {
        await stream.close();
      }
      if (!await ffmpeg.exists() || !await ffprobe.exists()) {
        throw StateError('Архив FFmpeg не содержит нужные программы.');
      }
    } finally {
      client.close();
      if (await zip.exists()) await zip.delete();
    }
  }

  static Future<List<String>> run(String exe, List<String> args,
      {void Function(String)? onLine}) async {
    final lines = <String>[];
    void handle(String raw) {
      final line = raw.trimRight();
      if (line.isEmpty) return;
      lines.add(line);
      onLine?.call(line);
    }
    if (Platform.isWindows) {
      await WinProc.run(exe, args, handle);
      return lines;
    }
    final p = await Process.start(exe, args);
    await Future.wait([
      p.stdout.transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()).forEach(handle),
      p.stderr.transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()).forEach(handle),
    ]);
    await p.exitCode;
    return lines;
  }
}
