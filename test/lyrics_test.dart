import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/lyrics.dart';
import 'package:cave_player/core/models.dart';

Track track(String title, String artist, [String album = '']) => Track(
      id: 'id',
      source: 's',
      title: title,
      artist: artist,
      album: album,
      albumArtist: '',
      no: null,
      year: '',
      pic: null,
      cover: null,
      modified: '',
      size: 0,
      by: '',
      path: '',
    );

void main() {
  group('разбор LRC', () {
    test('строки сортируются, индекс по позиции', () {
      final ly = Lyrics.fromLrclib({
        'syncedLyrics': '[ar:Кто-то]\n[00:10.00]Вторая\n[00:05.50]Первая\n[01:02.3]Третья',
      })!;
      expect(ly.synced, isTrue);
      expect(ly.lines.map((l) => l.text), ['Первая', 'Вторая', 'Третья']);
      expect(ly.indexAt(const Duration(seconds: 1)), -1);
      expect(ly.indexAt(const Duration(seconds: 6)), 0);
      expect(ly.indexAt(const Duration(seconds: 10)), 1);
      expect(ly.indexAt(const Duration(minutes: 5)), 2);
    });

    test('учитывается [offset:]', () {
      final ly = Lyrics.fromLrclib({'syncedLyrics': '[offset:+500]\n[00:10.00]Строка'})!;
      expect(ly.lines.single.at, const Duration(milliseconds: 9500));
    });

    test('без синхронного — обычный текст', () {
      final ly = Lyrics.fromLrclib({'syncedLyrics': '', 'plainLyrics': 'Раз\nДва'})!;
      expect(ly.synced, isFalse);
      expect(ly.lines.length, 2);
    });
  });

  group('выбор версии', () {
    final long = {'duration': 245.0, 'syncedLyrics': '[00:01.00]a', 'id': 1};
    final closePlain = {'duration': 200.0, 'plainLyrics': 'a', 'id': 2};
    final closeSynced = {'duration': 202.0, 'syncedLyrics': '[00:01.00]a', 'id': 3};
    final empty = {'duration': 200.0, 'id': 4};

    test('близкий по длительности синхронный важнее точного обычного', () {
      expect(LyricsService.pickBest([long, closePlain, closeSynced], const Duration(seconds: 200))?['id'], 3);
    });

    test('слишком разная длительность — не подходит', () {
      expect(LyricsService.pickBest([long], const Duration(seconds: 200)), isNull);
    });

    test('без текста не выбираем', () {
      expect(LyricsService.pickBest([empty], const Duration(seconds: 200)), isNull);
    });

    test('длительность неизвестна — берём синхронный', () {
      expect(LyricsService.pickBest([closePlain, closeSynced], Duration.zero)?['id'], 3);
    });
  });

  group('очистка запроса', () {
    test('название', () {
      expect(LyricsService.cleanTitle('Song (Official Video)'), 'Song');
      expect(LyricsService.cleanTitle('Песня [Клип]'), 'Песня');
      expect(LyricsService.cleanTitle('Song (feat. X) [HD]'), 'Song');
      expect(LyricsService.cleanTitle('Song - 2011 Remaster'), 'Song');
      expect(LyricsService.cleanTitle('Song feat. Somebody'), 'Song');
      expect(LyricsService.cleanTitle('Song (Live)'), 'Song (Live)');
      expect(LyricsService.cleanTitle('(Official Video)'), '(Official Video)');
    });

    test('исполнитель', () {
      expect(LyricsService.firstArtist('A, B'), 'A');
      expect(LyricsService.firstArtist('A feat. B'), 'A');
      expect(LyricsService.firstArtist('A & B'), 'A');
      expect(LyricsService.firstArtist('A x B'), 'A');
      expect(LyricsService.firstArtist('Malcolm X'), 'Malcolm X');
    });

    test('ключ кэша меняется после правки названия', () {
      expect(LyricsService.keyFor(track('A', 'B')), isNot(LyricsService.keyFor(track('A2', 'B'))));
      expect(LyricsService.keyFor(track('A', 'B')), LyricsService.keyFor(track(' a ', 'b')));
    });
  });

  group('сервис текстов', () {
    test('сообщает, когда текст появился, и отдаёт его из памяти', () async {
      final dir = await Directory.systemTemp.createTemp('lyrics');
      final service = LyricsService(dir);
      final t = track('Песня', 'Группа');
      File('${dir.path}${Platform.pathSeparator}${LyricsService.keyFor(t)}.json')
          .writeAsStringSync(jsonEncode({'syncedLyrics': '[00:01.00]Раз'}));
      var calls = 0;
      service.addListener(() => calls++);
      expect(service.known(t), isFalse);
      final f = service.forTrack(t, const Duration(seconds: 100));
      expect(service.loading(t), isTrue);
      final ly = await f;
      expect(ly?.lines.single.text, 'Раз');
      expect(service.known(t), isTrue);
      expect(service.loading(t), isFalse);
      expect(service.cached(t)?.synced, isTrue);
      expect(calls, greaterThanOrEqualTo(2)); // начал искать и нашёл
      await dir.delete(recursive: true);
    });
  });
}
