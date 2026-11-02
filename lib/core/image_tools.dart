// Сжатие картинок: при загрузке на Диск и для уменьшенных копий в кэше.
// Работает в отдельном изоляте, чтобы окно не подвисало.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

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
