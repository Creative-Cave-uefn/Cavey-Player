// Ожидаемые значения получены запуском тех же функций в исходном music_downloaderV2.py
import 'package:cave_player/core/dl/text.dart';
import 'package:cave_player/core/dl/winproc.dart';
import 'package:cave_player/core/dl/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('чистка названий', () {
    expect(cleanTitle('Звезда (Official Video) [Lyrics]'), 'Звезда');
    expect(cleanTitle('Song (official music video)'), 'Song');
    expect(stripLeadNum('01. Intro'), 'Intro');
    expect(clampName('AC/DC — Back:In*Black?'), 'ACDC - BackInBlack');
    expect(safeName('  My: Album.  '), 'My Album');
    expect(normTitle('Звезда по имени Солнце (Remastered 2019)!'), 'звезда по имени солнце');
  });

  test('исполнитель и название из ролика', () {
    expect(splitArtistTitle('Кино', 'Кино - Группа крови'), ('Кино', 'Группа крови'));
    expect(splitArtistTitle('Metallica', 'Metallica Nothing Else Matters'), ('Metallica', 'Nothing Else Matters'));
    expect(splitArtistTitle('NA', 'Just Title'), ('', 'Just Title'));
  });

  test('оценка вариантов с YouTube', () {
    final meta = TrackMeta(artist: 'Кино', title: 'Группа крови', duration: 285);
    expect(YouTube.score(Candidate('a', 'Кино - Группа крови', 'Кино - Topic', 286), meta), 110);
    expect(YouTube.score(Candidate('b', 'Кино - Группа крови (live)', 'fan', 300), meta), -10);
    expect(YouTube.score(Candidate('c', 'Группа крови кавер', 'x', 285), meta), 25);
  });

  test('кавычки в командной строке Windows', () {
    expect(quoteArg('plain'), 'plain');
    expect(quoteArg(''), '""');
    expect(quoteArg('a b'), '"a b"');
    expect(quoteArg('a"b'), r'"a\"b"');
    expect(quoteArg(r'C:\Program Files\x\'), r'"C:\Program Files\x\\"');
    expect(quoteArg('%(id)s.%(ext)s'), '%(id)s.%(ext)s');
    expect(quoteArg('after_move:%(filepath)s\t%(title)s'), '"after_move:%(filepath)s\t%(title)s"');
  });
}
