import 'dart:typed_data';

import 'package:cave_player/core/app_icon.dart';
import 'package:cave_player/core/updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Перекраска трогает только цветную метку, тёмный фон остаётся', () {
    final src = img.Image(width: 2, height: 1, numChannels: 4);
    src.setPixelRgba(0, 0, 36, 36, 36, 255); // фон
    src.setPixelRgba(1, 0, 239, 214, 77, 255); // жёлтая метка
    final out = recolorIcon(src, 0xFF6FA8FF);
    final bg = out.getPixel(0, 0);
    expect([bg.r, bg.g, bg.b], [36, 36, 36]);
    final mark = out.getPixel(1, 0);
    expect(mark.b > mark.r, isTrue); // стала синей
  });

  test('ICO: заголовок, записи и смещения', () {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4, 5]);
    final ico = buildIco([(16, a), (256, b)]);
    expect(ico.sublist(0, 6), [0, 0, 1, 0, 2, 0]);
    expect(ico[6], 16); // ширина первой
    expect(ico[22], 0); // 256 пишется как 0
    final off1 = ico[18] | (ico[19] << 8);
    expect(off1, 6 + 32);
    expect(ico.sublist(off1, off1 + 3), [1, 2, 3]);
    expect(ico.length, 6 + 32 + 5);
  });

  test('Описание версии без служебных строк', () {
    const body = 'Слияние glass в main: стекло и караоке\n\nCo-Authored-By: X <x@y>\nClaude-Session: https://a';
    expect(Updater.cleanNotes(body), 'стекло и караоке');
    expect(Updater.cleanNotes('• Поиск\n• Плеер'), '• Поиск\n• Плеер');
  });
}
