// Сжатие картинок: при загрузке на Диск и для уменьшенных копий в кэше.
// Работает в отдельном изоляте, чтобы окно не подвисало.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'dl/tools.dart';

/// GIF по первым байтам («GIF87a», «GIF89a»)
bool isGifBytes(List<int> b) => b.length > 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38;

/// Предел размера картинки, которую берём по ссылке, и анимированной GIF
const maxLinkedImageBytes = 64 * 1024 * 1024;
const maxGifBytes = 10 * 1024 * 1024;

/// Сколько ждать загрузки картинки на Диск: обычная обложка — 90 секунд, на каждый мегабайт сверх первого ещё 25 (GIF бывает до 10 МБ,
/// а по медленному каналу 45 секунд на такой файл не хватало)
Duration coverUploadTimeout(int bytes) => Duration(seconds: 90 + 25 * (bytes / 1048576).ceil());

/// Скачивает картинку по ссылке http(s). Бросает понятную ошибку (FormatException / HttpException / TimeoutException)
Future<Uint8List> downloadImageBytes(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('Нужна ссылка на картинку вида https://…');
  }
  final client = http.Client();
  try {
    final req = http.Request('GET', uri)
      ..headers['User-Agent'] = 'Mozilla/5.0 Cavey-Player'
      ..headers['Accept'] = 'image/*,*/*;q=0.8';
    final res = await client.send(req).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw HttpException('Сайт ответил ${res.statusCode}');
    final len = res.contentLength;
    if (len != null && len > maxLinkedImageBytes) throw const FormatException('Файл слишком большой (больше 64 МБ)');
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(const Duration(seconds: 20))) {
      out.add(chunk);
      if (out.length > maxLinkedImageBytes) throw const FormatException('Файл слишком большой (больше 64 МБ)');
    }
    final bytes = out.takeBytes();
    if (bytes.isEmpty) throw const FormatException('Пустой ответ');
    return bytes;
  } finally {
    client.close();
  }
}

class _Job {
  final Uint8List bytes;
  final int maxSide;
  final int quality;
  const _Job(this.bytes, this.maxSide, this.quality);
}

/// Уменьшает картинку так, чтобы длинная сторона была не больше [maxSide], и сохраняет как JPEG.
/// Если картинку не удалось прочитать, возвращает null.
Uint8List? compressImageSync(Uint8List bytes, int maxSide, int quality) {
  img.Image? src;
  try {
    src = img.decodeImage(bytes);
  } catch (_) {
    return null; // битый файл: декодер может упасть с RangeError
  }
  if (src == null) return null;
  var out = src;
  final longest = math.max(src.width, src.height);
  if (longest > maxSide) {
    out = src.width >= src.height
        ? img.copyResize(src, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(src, height: maxSide, interpolation: img.Interpolation.average);
  }
  // У JPEG нет прозрачности: подкладываем цвет фона приложения
  if (out.hasAlpha) {
    final flat = img.Image(width: out.width, height: out.height, numChannels: 3);
    img.fill(flat, color: img.ColorRgb8(0x0E, 0x10, 0x1F));
    img.compositeImage(flat, out);
    out = flat;
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: quality));
}

Uint8List? _run(_Job j) => compressImageSync(j.bytes, j.maxSide, j.quality);

/// JPEG до [maxSide] пикселей по длинной стороне; при ошибке возвращает исходные байты
Future<Uint8List> compressImage(Uint8List bytes, {required int maxSide, int quality = 85}) async {
  try {
    final out = await compute(_run, _Job(bytes, maxSide, quality));
    // Если вышло не меньше исходного (маленькая простая картинка) — оставляем как есть
    if (out != null && out.length < bytes.length) return out;
  } catch (_) {}
  return bytes;
}

/// Уменьшенная копия для кэша. Картинки, которые и так не больше [side], остаются как есть
Future<Uint8List> makeThumbnail(Uint8List bytes, int side) async {
  try {
    final out = await compute(_thumb, _Job(bytes, side, 88));
    if (out != null) return out;
  } catch (_) {}
  return bytes;
}

Uint8List? _thumb(_Job j) {
  img.Image? src;
  try {
    src = img.decodeImage(j.bytes);
  } catch (_) {
    return null;
  }
  if (src == null) return null;
  if (math.max(src.width, src.height) <= j.maxSide) return j.bytes;
  return compressImageSync(j.bytes, j.maxSide, j.quality);
}

/// Both pictures show the same artwork, possibly at different sizes or compression.
/// Compares 16x16 miniatures; unreadable or differently cropped pictures count as different.
Future<bool> sameArtwork(Uint8List a, Uint8List b) async {
  try {
    return await compute(_sameArt, [a, b]);
  } catch (_) {
    return false;
  }
}

bool _sameArt(List<Uint8List> pair) {
  img.Image? small(Uint8List bytes) {
    try {
      final full = img.decodeImage(bytes);
      if (full == null) return null;
      return img.copyResize(full, width: 16, height: 16, interpolation: img.Interpolation.average);
    } catch (_) {
      return null;
    }
  }

  final a = small(pair[0]), b = small(pair[1]);
  if (a == null || b == null) return false;
  var sum = 0.0;
  for (var y = 0; y < 16; y++) {
    for (var x = 0; x < 16; x++) {
      final p = a.getPixel(x, y), q = b.getPixel(x, y);
      sum += (p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs();
    }
  }
  return sum / (16 * 16 * 3) < 24;
}

/// Картинка из буфера обмена Windows: скопированное изображение (из браузера, скриншот, редактор) или файл-картинка,
/// скопированный в Проводнике. null — в буфере картинки нет. Бросает исключение, если PowerShell недоступен
Future<({Uint8List bytes, String name})?> readClipboardImage() async {
  if (!Platform.isWindows) return null;
  final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}cave-clip-${DateTime.now().microsecondsSinceEpoch}.png');
  final path = tmp.path.replaceAll("'", "''");
  final script = '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
  \$f = [System.Windows.Forms.Clipboard]::GetFileDropList()
  if (\$f.Count -gt 0) { Write-Output ('FILE:' + \$f[0]); exit 0 }
}
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
  \$i = [System.Windows.Forms.Clipboard]::GetImage()
  if (\$i -ne \$null) { \$i.Save('$path', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'IMG'; exit 0 }
}
Write-Output 'NONE'
''';
  try {
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', script],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 15));
    final out = '${r.stdout}'.trim().split('\n').last.trim();
    if (out == 'IMG' && await tmp.exists()) return (bytes: await tmp.readAsBytes(), name: 'буфер.png');
    if (out.startsWith('FILE:')) {
      final f = File(out.substring(5));
      final ext = f.path.contains('.') ? f.path.split('.').last.toLowerCase() : '';
      if (const ['jpg', 'jpeg', 'jpe', 'jfif', 'png', 'webp', 'bmp', 'gif'].contains(ext) && await f.exists()) {
        if (await f.length() > maxLinkedImageBytes) throw const FormatException('файл слишком большой');
        return (bytes: await f.readAsBytes(), name: f.uri.pathSegments.last);
      }
    }
    return null;
  } finally {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}


class _GifJob {
  final Uint8List bytes;
  final int limit;
  const _GifJob(this.bytes, this.limit);
}

/// Сжимает анимированную GIF до [limit] байт. Сначала через FFmpeg (своя палитра на весь ролик, правильная склейка кадров;
/// если его ещё нет — скачивается, как для «Скачать на устройство»), а если не вышло — своими силами в отдельном изоляте.
/// Возвращает null, если уложиться не вышло
Future<Uint8List?> shrinkGif(Uint8List bytes, int limit, {Tools? tools}) async {
  if (tools != null) {
    try {
      final out = await _shrinkGifFfmpeg(tools, bytes, limit);
      if (out != null) return out;
    } catch (_) {}
  }
  try {
    return await compute(_shrinkGif, _GifJob(bytes, limit));
  } catch (_) {
    return null;
  }
}

/// Размер кадра из заголовка GIF
(int, int)? gifSize(Uint8List b) => b.length < 10 ? null : (b[6] | (b[7] << 8), b[8] | (b[9] << 8));

Future<Uint8List?> _shrinkGifFfmpeg(Tools tools, Uint8List bytes, int limit) async {
  if (!await tools.ffmpeg.exists()) await tools.ensure((_) {});
  final size = gifSize(bytes);
  if (size == null || size.$1 <= 0) return null;
  final tmp = Directory.systemTemp.path + Platform.pathSeparator;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final src = File('${tmp}cave-gif-$stamp-in.gif');
  final dst = File('${tmp}cave-gif-$stamp-out.gif');
  await src.writeAsBytes(bytes, flush: true);
  try {
    var scale = math.min(1.0, math.sqrt(limit * 0.8 / bytes.length));
    int? fps;
    Uint8List? best;
    for (var attempt = 0; attempt < 6; attempt++) {
      final w = math.max(32, (size.$1 * scale).round() & ~1);
      final filter = '${fps == null ? '' : 'fps=$fps,'}scale=$w:-2:flags=lanczos,split[a][b];'
          '[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle';
      try {
        if (await dst.exists()) await dst.delete();
      } catch (_) {}
      await Tools.run(tools.ffmpeg.path, ['-hide_banner', '-loglevel', 'error', '-y', '-i', src.path, '-filter_complex', filter, '-loop', '0', dst.path]);
      if (!await dst.exists()) return null;
      final out = await dst.readAsBytes();
      if (out.isEmpty || !isGifBytes(out)) return null;
      best = out;
      if (out.length <= limit) return out;
      // Не уложились: меньше кадр, а когда он уже мелкий — реже кадры
      scale *= math.max(0.5, math.min(0.9, math.sqrt(limit * 0.85 / out.length)));
      if (scale < 0.55 && fps == null) {
        fps = 15;
        scale = math.min(1.0, scale * 1.3);
      }
    }
    return best != null && best.length <= limit ? best : null;
  } finally {
    for (final f in [src, dst]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

Uint8List? _shrinkGif(_GifJob j) {
  img.Image? src;
  try {
    src = img.decodeGif(j.bytes);
  } catch (_) {
    return null;
  }
  if (src == null) return null;
  final w0 = src.width, h0 = src.height;
  // Кадры GIF часто хранят только изменившиеся точки, а остальное прозрачно (под прозрачным нередко лежит «ключевой»
  // зелёный цвет). Склеиваем каждый кадр поверх предыдущего и берём без прозрачности — иначе картинка становилась зелёной
  final frames = <img.Image>[];
  img.Image? canvas;
  for (final f in src.frames) {
    final rgba = f.convert(numChannels: 4);
    final next = canvas == null ? img.Image(width: w0, height: h0, numChannels: 4) : img.Image.from(canvas);
    img.compositeImage(next, rgba);
    next.frameDuration = f.frameDuration;
    canvas = next;
    frames.add(next.convert(numChannels: 3));
  }
  if (frames.isEmpty) return null;
  // Размер GIF растёт примерно с числом пикселей: первый заход берём с запасом
  var scale = math.min(1.0, math.sqrt(j.limit * 0.75 / j.bytes.length));
  var step = 1;
  Uint8List? best;
  for (var attempt = 0; attempt < 6; attempt++) {
    final w = math.max(16, (w0 * scale).round());
    final h = math.max(16, (h0 * scale).round());
    // Нейронная палитра: восьмеричное дерево из пакета image давало кашу из цветов
    final enc = img.GifEncoder(repeat: 0, samplingFactor: 20);
    for (var i = 0; i < frames.length; i += step) {
      var ms = 0;
      for (var k = i; k < math.min(i + step, frames.length); k++) {
        ms += frames[k].frameDuration;
      }
      final frame = frames[i];
      final small = (w == w0 && h == h0) ? frame : img.copyResize(frame, width: w, height: h, interpolation: img.Interpolation.average);
      enc.addFrame(small, duration: math.max(2, (ms / 10).round()));
    }
    final out = enc.finish();
    if (out == null) return null;
    best = out;
    if (out.length <= j.limit) return out;
    scale *= math.max(0.5, math.min(0.9, math.sqrt(j.limit * 0.85 / out.length)));
    if (scale < 0.45 && step < 3 && frames.length > 8) {
      step++;
      scale = math.min(1.0, scale * 1.6);
    }
  }
  return best != null && best.length <= j.limit ? best : null;
}
