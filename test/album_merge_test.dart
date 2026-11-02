import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/library.dart';
import 'package:cave_player/core/models.dart';

var _n = 0;
Track t(String title, String artist, String album, {String path = 'p5t', String source = 's', int? no, String aa = ''}) => Track(
      id: 'id${_n++}',
      source: source,
      title: title,
      artist: artist,
      album: album,
      albumArtist: aa,
      no: no,
      year: '',
      pic: null,
      cover: null,
      modified: '',
      size: 0,
      by: '',
      path: path,
    );

Map<String, List<Track>> groups(List<Track> tracks) {
  final m = <String, List<Track>>{};
  for (final x in tracks) {
    m.putIfAbsent(x.albumKey, () => []).add(x);
  }
  return m;
}

void main() {
  test('Альбом с треками разных исполнителей из одной папки — один альбом', () {
    final g = groups([
      t('Ultimate', 'ATLUS Sound Team', 'Persona 5 Tactica OST', no: 1),
      t('Fall Out', 'ATLUS Sound Team', 'Persona 5 Tactica OST', no: 2),
      t('Got Your Tail', 'Lyn Inaizumi', 'Persona 5 Tactica OST', no: 3),
      t('Revolution', 'Haruko Komiya', 'Persona 5 Tactica OST', no: 4),
    ]);
    expect(g.length, 3);
    final merged = mergeAlbumGroups(g);
    expect(merged.length, 1);
    final a = buildAlbum(merged.single, g);
    expect(a.tracks.map((x) => x.no), [1, 2, 3, 4]);
    expect(a.artist, 'ATLUS Sound Team');
    expect(a.artists.first, 'ATLUS Sound Team');
    expect(a.artists, containsAll(['Lyn Inaizumi', 'Haruko Komiya']));
    // Старые ключи частей ведут в склеенный альбом
    expect(a.keys, g.keys.toSet());
  });

  test('Общий исполнитель склеивает части из разных папок', () {
    final g = groups([
      t('A', 'Lyn', 'PERSONA5 ORIGINAL', path: 'cd1'),
      t('B', 'Lyn, ATLUS Sound Team', 'PERSONA5 ORIGINAL', path: 'cd2'),
    ]);
    expect(mergeAlbumGroups(g).length, 1);
  });

  test('Тёзки разных исполнителей в разных папках не склеиваются', () {
    final g = groups([
      t('One', 'Queen', 'Greatest Hits', path: 'queen'),
      t('Two', 'ABBA', 'Greatest Hits', path: 'abba'),
    ]);
    expect(mergeAlbumGroups(g).length, 2);
  });

  test('Треки без альбома в тегах не склеиваются по папке', () {
    final g = groups([
      t('One', 'X', '', path: ''),
      t('Two', 'Y', '', path: ''),
    ]);
    expect(mergeAlbumGroups(g).length, 2);
  });

  test('Нет явного лидера — «Разные исполнители»', () {
    final g = groups([
      t('1', 'A', 'Mix'),
      t('2', 'B', 'Mix'),
      t('3', 'C', 'Mix'),
    ]);
    final a = buildAlbum(mergeAlbumGroups(g).single, g);
    expect(a.artist, 'Разные исполнители');
  });

  test('Tyler, The Creator — один артист, запятая не создаёт второго', () {
    expect(splitArtists('Tyler, The Creator'), ['Tyler, The Creator']);
    expect(splitArtists('Tyler The Creator'), ['Tyler, The Creator']);
    expect(splitArtists('Tyler, The Creator, Kali Uchis'),
        ['Tyler, The Creator', 'Kali Uchis']);
    expect(splitArtists('Tyler, The Creator feat. Pharrell Williams'),
        ['Tyler, The Creator', 'Pharrell Williams']);
    expect(splitArtists('Korn, Slipknot'), ['Korn', 'Slipknot']);
  });

  test('IGOR 2019 с разными написаниями исполнителя остаётся одним альбомом', () {
    final first = t('EARFQUAKE', 'Tyler, The Creator', 'IGOR', no: 3);
    final second = t('NEW MAGIC WAND', 'Tyler The Creator', 'IGOR', no: 6);
    final third = t('ARE WE STILL FRIENDS?', 'Tyler, the Creator', 'IGOR', no: 12,
        aa: 'Tyler The Creator');
    final g = groups([first, second, third]);
    expect(g.length, 1);
    final albums = mergeAlbumGroups(g);
    expect(albums.length, 1);
    final album = buildAlbum(albums.single, g);
    expect(album.tracks.length, 3);
    expect(album.artist, 'Tyler, The Creator');
    expect(album.artists, ['Tyler, The Creator']);
    expect(first.artists, ['Tyler, The Creator']);
    expect(second.displayArtist, 'Tyler, The Creator');
  });

  test('Ключ после правки исполнителя альбома', () {
    final x = t('1', 'Lyn', 'P5');
    expect(x.albumKeyWith(newAlbumArtist: 'ATLUS'), 'atlus\u0001p5');
    expect(x.albumKeyWith(newAlbum: 'P5R'), 'lyn\u0001p5r');
  });
}
