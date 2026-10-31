import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cave_player/core/lyric_sources.dart';

void main() {
  test('UltraStar: слоги получают время по BPM и GAP', () {
    const txt = '#TITLE:Тест\n#BPM:120\n#GAP:1000\n: 0 4 5 При\n: 4 4 5 вет\n: 8 4 5  мир\n- 16\n: 16 4 5 Вто\n: 20 4 5 рая\nE\n';
    final ly = LyricFiles.fromUltraStar(txt)!;
    expect(ly.synced, true);
    expect(ly.lines.length, 2);
    expect(ly.lines[0].text, 'Привет мир');
    // 120 BPM → такт = 60000 / (120 × 4) = 125 мс; GAP 1000 мс
    expect(ly.lines[0].at, const Duration(milliseconds: 1000));
    final w = ly.lines[0].words!;
    expect(w.length, 3);
    expect(w[1].start, const Duration(milliseconds: 1500));
    expect(ly.lines[1].at, const Duration(milliseconds: 3000));
  });

  test('ASS: теги \\k задают слоги подряд', () {
    const ass = 'Dialogue: 0,0:00:10.00,0:00:14.00,Default,,0,0,0,,{\\k50}При{\\k30}вет {\\k40}мир\n';
    final ly = LyricFiles.fromAss(ass)!;
    expect(ly.lines.single.text, 'Привет мир');
    final w = ly.lines.single.words!;
    expect(w.first.start, const Duration(seconds: 10));
    expect(w[1].start, const Duration(milliseconds: 10500));
    expect(w[2].start, const Duration(milliseconds: 10800));
  });

  test('LRC рядом с треком: с отметками — синхронный, без — обычный', () {
    expect(LyricFiles.fromLrc('[00:01.00]раз\n[00:02.50]два')!.synced, true);
    expect(LyricFiles.fromLrc('раз\nдва')!.synced, false);
  });

  test('ID3 SYLT превращается в LRC', () {
    // кодировка 3 (UTF-8), язык, формат времени 2 (мс), тип 1, описание пустое
    final body = <int>[3, 0x72, 0x75, 0x73, 2, 1, 0];
    void add(String s, int ms) {
      body
        ..addAll(utf8.encode(s))
        ..add(0)
        ..addAll([(ms >> 24) & 255, (ms >> 16) & 255, (ms >> 8) & 255, ms & 255]);
    }

    add('раз', 1000);
    add('два', 62500);
    final frame = <int>[...utf8.encode('SYLT'), 0, 0, 0, body.length, 0, 0, ...body];
    final tagSize = frame.length;
    final file = Uint8List.fromList([
      0x49, 0x44, 0x33, 3, 0, 0, 0, 0, (tagSize >> 7) & 0x7f, tagSize & 0x7f, //
      ...frame,
    ]);
    final src = LyricFiles.fromId3(file)!;
    expect(src.kind, LyricKind.lrc);
    expect(src.text, contains('[00:01.00]раз'));
    expect(src.text, contains('[01:02.50]два'));
  });
}
