// Ожидаемые значения получены запуском тех же функций в исходном music_downloaderV2.py
import 'package:cave_player/core/dl/sources.dart';
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
    expect(YouTube.score(Candidate('b', 'Кино - Группа крови (live)', 'fan', 300), meta), -30);
    expect(YouTube.score(Candidate('c', 'Группа крови кавер', 'x', 285), meta), 5);
  });

  test('песня из YouTube Music выше клипа и концерта', () {
    final meta = TrackMeta(artist: 'Korn', title: 'Freak On a Leash', duration: 255);
    final song = YouTube.score(Candidate('s', 'Freak On a Leash', 'Korn', 255, song: true), meta);
    final clip = YouTube.score(Candidate('v', 'Korn - Freak On A Leash (Official HD Video)', 'KornVEVO', 268), meta);
    final live = YouTube.score(Candidate('l', 'Korn - Freak On A Leash (Live at Download 2016)', 'Korn', 262), meta);
    expect(song, greaterThan(clip));
    expect(song, greaterThan(live));
    expect(clip, lessThan(40));
  });

  test('Deezer: та же песня, без live и ремиксов', () {
    final results = <Map>[
      {'id': 1, 'title': 'Freak On a Leash (Live)', 'artist': {'name': 'Korn'}},
      {'id': 2, 'title': 'Freak On a Leash (Dillon Francis Remix)', 'artist': {'name': 'Korn'}},
      {'id': 3, 'title': 'Freak on a Leash', 'artist': {'name': 'Korn'}},
    ];
    expect(pickDeezer(results, 'Korn', 'Freak On a Leash', 'Korn - Freak On a Leash'), 3);
    expect(pickDeezer(results, 'Korn', 'Freak On a Leash', 'Korn - Freak On a Leash live'), 1);
    expect(pickDeezer(results, 'Kiss', 'Freak On a Leash', 'Kiss - Freak On a Leash'), isNull);
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
