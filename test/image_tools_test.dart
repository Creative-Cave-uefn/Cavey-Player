import 'dart:typed_data';

import 'package:cave_player/core/image_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List sample(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 7) % 256, (y * 5) % 256, ((x + y) * 3) % 256);
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  test('Большая картинка уменьшается до заданной стороны и становится JPEG', () {
    final png = sample(1200, 600);
    final out = compressImageSync(png, 512, 85)!;
    final back = img.decodeJpg(out)!;
    expect(back.width, 512);
    expect(back.height, 256);
    expect(out.length, lessThan(png.length));
  });

  test('Маленькая картинка не увеличивается', () {
    final out = compressImageSync(sample(100, 80), 512, 85)!;
    final back = img.decodeJpg(out)!;
    expect(back.width, 100);
  });

  test('Не картинка — null, без падения', () {
    expect(compressImageSync(Uint8List.fromList([1, 2, 3]), 512, 85), isNull);
  });
}
