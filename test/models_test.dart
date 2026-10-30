import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/updater.dart';

LibraryData withPlaylist(List<String> items) => LibraryData()
  ..apply({
    'op': 'createPlaylist',
    'playlist': {'id': 'p', 'name': 'P', 'by': 'me', 'at': 0, 'items': items},
  });

void main() {
  group('порядок в плейлисте', () {
    test('перенос за соседа и в начало', () {
      final d = withPlaylist(['a', 'b', 'c', 'd']);
      d.apply({'op': 'movePlaylistItem', 'id': 'p', 'track': 'a', 'after': 'c'});
      expect(d.playlists.single.items, ['b', 'c', 'a', 'd']);
      d.apply({'op': 'movePlaylistItem', 'id': 'p', 'track': 'd', 'after': null});
      expect(d.playlists.single.items, ['d', 'b', 'c', 'a']);
    });

    test('повтор операции ничего не ломает', () {
      final d = withPlaylist(['a', 'b', 'c']);
      final op = {'op': 'movePlaylistItem', 'id': 'p', 'track': 'c', 'after': 'a'};
      d.apply(op);
      d.apply(op);
      expect(d.playlists.single.items, ['a', 'c', 'b']);
    });

    test('сосед пропал или трек уже удалили', () {
      final d = withPlaylist(['a', 'b']);
      d.apply({'op': 'movePlaylistItem', 'id': 'p', 'track': 'b', 'after': 'zzz'});
      expect(d.playlists.single.items, ['b', 'a']);
      d.apply({'op': 'movePlaylistItem', 'id': 'p', 'track': 'x', 'after': 'a'});
      expect(d.playlists.single.items, ['b', 'a']);
    });

    test('операция переживает сохранение', () {
      final d = withPlaylist(['a', 'b', 'c'])..apply({'op': 'movePlaylistItem', 'id': 'p', 'track': 'c', 'after': null});
      expect(LibraryData.fromJson(d.toJson()).playlists.single.items, ['c', 'a', 'b']);
    });
  });

  group('тестовые сборки', () {
    test('имя ветки в теге как в сборке на GitHub', () {
      expect(Updater.slugOf('feature/New-Queue'), 'feature-new-queue');
      expect(Updater.slugOf('fix/lyrics-stability'), 'fix-lyrics-stability');
      expect(Updater.slugOf('--x__y--'), 'x-y');
      expect(Updater.slugOf('ветка'), 'branch');
    });

    test('сравнение версий', () {
      expect(Updater.isNewer('0.2.40', '0.2.39'), isTrue);
      expect(Updater.isNewer('0.2.9', '0.2.10'), isFalse);
      expect(Updater.isNewer('0.2.10', '0.2.10'), isFalse);
    });
  });

  group('соавторы', () {
    test('разделители в поле исполнителя', () {
      expect(splitArtists('A, B'), ['A', 'B']);
      expect(splitArtists('A feat. B'), ['A', 'B']);
      expect(splitArtists('A ft. B & C'), ['A', 'B', 'C']);
      expect(splitArtists('A x B'), ['A', 'B']);
      expect(splitArtists('A; B'), ['A', 'B']);
      expect(splitArtists('Скриптонит, 104'), ['Скриптонит', '104']);
    });

    test('не режет то, что похоже на одно имя', () {
      expect(splitArtists('AC/DC'), ['AC/DC']);
      expect(splitArtists('A&B'), ['A&B']);
      expect(splitArtists('Malcolm X'), ['Malcolm X']);
      expect(splitArtists('Xzibit'), ['Xzibit']);
    });

    test('соавторы из названия и без повторов', () {
      expect(splitArtists('A', 'Песня (feat. B, C)'), ['A', 'B', 'C']);
      expect(splitArtists('A, B', 'Песня [ft. b]'), ['A', 'B']);
    });
  });
}
