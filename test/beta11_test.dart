import 'package:cave_player/core/device_export.dart';
import 'package:cave_player/core/library.dart';
import 'package:cave_player/core/migration.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/pin_order.dart';
import 'package:cave_player/core/store.dart';
import 'package:cave_player/core/suggest.dart';
import 'package:cave_player/core/text_fold.dart';
import 'package:cave_player/ui/library_tabs.dart';
import 'package:cave_player/ui/shell.dart' show Nav;
import 'package:cave_player/ui/uploader_filter.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;
Track tr(String title, {String artist = 'A', String album = 'B', String by = '', String source = 's', int? no, int? disc, String ua = ''}) => Track(
      id: 'b11-${_n++}',
      source: source,
      title: title,
      artist: artist,
      album: album,
      albumArtist: '',
      no: no,
      disc: disc,
      year: '',
      pic: null,
      cover: null,
      modified: '',
      size: 0,
      by: by,
      path: 'p',
      uploadedAt: ua,
    );

void main() {
  group('Поиск без диакритики', () {
    test('foldText убирает акценты и приводит ё, й', () {
      expect(foldText('Beyoncé'), 'beyonce');
      expect(foldText('Björk'), 'bjork');
      expect(foldText('  Ёжик   в  Тумане '), 'ежик в тумане');
      expect(foldText('Мой'), 'мои');
    });

    test('foldAlbumTitle склеивает Remastered и знаки препинания', () {
      expect(foldAlbumTitle('Abbey Road (2019 Remaster)'), foldAlbumTitle('Abbey Road'));
      expect(foldAlbumTitle('Rumours - Remastered 2004'), foldAlbumTitle('Rumours'));
      expect(foldAlbumTitle('Café: Del Mar!'), foldAlbumTitle('cafe del mar'));
    });
  });

  group('Подсказки', () {
    final all = [
      const Suggestion('Café Tacvba', weight: 3),
      const Suggestion('The Cure', weight: 10),
      const Suggestion('Cure for Pain', weight: 1),
      const Suggestion('Obscure', weight: 50),
    ];

    test('сначала начало названия, затем начало слова, затем вхождение', () {
      final r = rankSuggestions(all, 'cur').map((s) => s.text).toList();
      // «Cure for Pain» и «The Cure»: начало названия выше начала второго слова; «Obscure» — просто вхождение
      expect(r, ['Cure for Pain', 'The Cure', 'Obscure']);
    });

    test('регистр и диакритика не мешают', () {
      expect(rankSuggestions(all, 'CAFE').map((s) => s.text), ['Café Tacvba']);
    });

    test('при равном совпадении выше те, где больше треков', () {
      final r = rankSuggestions([const Suggestion('Aa', weight: 1), const Suggestion('Ab', weight: 9)], 'a').map((s) => s.text).toList();
      expect(r, ['Ab', 'Aa']);
    });

    test('точное совпадение находится, «Создать» тогда не нужно', () {
      expect(hasExactSuggestion(all, 'the cure'), isTrue);
      expect(hasExactSuggestion(all, 'the cur'), isFalse);
    });

    test('последний исполнитель в списке через запятую', () {
      expect(splitLastArtist('Queen, Dav'), (head: 'Queen,', tail: 'Dav'));
      expect(splitLastArtist('Queen'), (head: '', tail: 'Queen'));
    });
  });

  group('Закрепы', () {
    test('закреплённые идут первыми в порядке закрепа', () {
      final s = splitPinned(['a', 'b', 'c', 'd'], (x) => ['fl:$x'], ['fl:c', 'fl:a']);
      expect(s.pinned, ['c', 'a']);
      expect(s.rest, ['b', 'd']);
    });

    test('перестановка внутри закреплённых', () {
      expect(dropOnto(['a', 'b', 'c', 'x'], 3, 'c', 'a'), ['c', 'a', 'b']);
    });

    test('незакреплённый, брошенный в зону закреплённых, закрепляется', () {
      expect(dropOnto(['a', 'b', 'x', 'y'], 2, 'x', 'a'), ['x', 'a', 'b']);
    });

    test('закреплённый, брошенный ниже, открепляется', () {
      expect(dropOnto(['a', 'b', 'x', 'y'], 2, 'a', 'y'), ['b']);
    });

    test('порядок среди незакреплённых не хранится', () {
      expect(dropOnto(['a', 'x', 'y'], 1, 'x', 'y'), isNull);
    });

    test('скрытые закрепы сохраняются в конце', () {
      expect(mergePins(['a', 'b', 'h'], ['a', 'b'], ['b', 'a']), ['b', 'a', 'h']);
    });

    test('закрепить и открепить', () {
      expect(togglePin(['a'], 'b'), ['a', 'b']);
      expect(togglePin(['a', 'b'], 'a'), ['b']);
    });
  });

  group('Скачать на устройство', () {
    test('безопасные имена для Windows', () {
      expect(safeFileName('AC/DC: Back?'), 'AC_DC_ Back_');
      expect(safeFileName('con'), '_con');
      expect(safeFileName('Конец...'), 'Конец');
      expect(safeFileName('   '), '_');
    });

    test('расширение по началу файла', () {
      expect(sniffAudioExt([0x49, 0x44, 0x33, 4]), 'mp3');
      expect(sniffAudioExt([0x66, 0x4C, 0x61, 0x43]), 'flac');
      expect(sniffAudioExt([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70]), 'm4a');
      expect(sniffAudioExt([0x4F, 0x67, 0x67, 0x53]), 'ogg');
    });

    test('имена: без нумерации с исполнителем, с нумерацией для альбома и плейлиста', () {
      final ts = [tr('One', artist: 'X', no: 1), tr('Two', artist: 'X', no: 2)];
      expect(exportFileNames(ts, ['mp3', 'mp3']), ['X - One.mp3', 'X - Two.mp3']);
      expect(exportFileNames(ts, ['mp3', 'mp3'], numbered: true, withArtist: false), ['01. One.mp3', '02. Two.mp3']);
      expect(exportFileNames(ts, ['mp3', 'mp3'], numbered: true), ['01. X - One.mp3', '02. X - Two.mp3']);
    });

    test('одинаковые имена получают номер', () {
      final ts = [tr('Same', artist: 'X'), tr('Same', artist: 'X')];
      expect(exportFileNames(ts, ['mp3', 'mp3']), ['X - Same.mp3', 'X - Same (2).mp3']);
    });
  });

  group('Перенос старых треков', () {
    test('переносится чужой файл из общей папки, загруженный по-старому', () {
      expect(isMigratable(tr('a', by: 'friend@x', source: 'hub'), hubId: 'hub', owner: 'me@x'), isTrue);
    });

    test('не переносятся свои, чужие папки, неизвестный загрузивший и файлы из брокера', () {
      expect(isMigratable(tr('a', by: 'me@x', source: 'hub'), hubId: 'hub', owner: 'me@x'), isFalse);
      expect(isMigratable(tr('a', by: 'friend@x', source: 'other'), hubId: 'hub', owner: 'me@x'), isFalse);
      expect(isMigratable(tr('a', by: '', source: 'hub'), hubId: 'hub', owner: 'me@x'), isFalse);
      expect(isMigratable(tr('a', by: 'friend@x', source: 'hub', ua: '2026-01-01T00:00:00Z'), hubId: 'hub', owner: 'me@x'), isFalse);
      expect(isMigratable(tr('a', by: 'friend@x', source: 'hub'), hubId: null, owner: 'me@x'), isFalse);
    });
  });

  group('Кто загрузил', () {
    test('люди по убыванию числа загрузок, почта без регистра', () {
      final r = uploadersOf([tr('1', by: 'B@x'), tr('2', by: 'a@x'), tr('3', by: 'b@x'), tr('4')]);
      expect([for (final u in r) (u.email, u.count)], [('b@x', 2), ('a@x', 1)]);
    });

    test('пустой выбор пропускает всех, иначе только выбранных', () {
      expect(passesUploaders({}, 'any@x'), isTrue);
      expect(passesUploaders({'a@x'}, 'A@x'), isTrue);
      expect(passesUploaders({'a@x'}, 'b@x'), isFalse);
      expect(passesUploaders({'a@x'}, ''), isFalse);
    });

    test('выбор записывается в настройки и читается обратно', () {
      final raw = encodeUploaders({'b@x', 'a@x'});
      expect(raw, 'a@x,b@x');
      expect(decodeUploaders(raw), {'a@x', 'b@x'});
      expect(decodeUploaders(null), isEmpty);
      expect(decodeUploaders(''), isEmpty);
    });
  });

  group('Вкладка Медиатеки', () {
    test('последняя вкладка запоминается и читается, чужая страница не запоминается', () {
      final s = Settings();
      expect(lastLibraryTab(s).same(const Nav('all')), isTrue);
      expect(rememberLibraryTab(s, const Nav('albums', 'ep')), isTrue);
      expect(lastLibraryTab(s).same(const Nav('albums', 'ep')), isTrue);
      expect(rememberLibraryTab(s, const Nav('albums', 'ep')), isFalse);
      expect(rememberLibraryTab(s, const Nav('company')), isFalse);
      expect(lastLibraryTab(s).same(const Nav('albums', 'ep')), isTrue);
    });
  });

  group('Склейка альбомов без диакритики', () {
    Map<String, List<Track>> byKey(List<Track> tracks) {
      final m = <String, List<Track>>{};
      for (final x in tracks) {
        m.putIfAbsent(x.albumKey, () => []).add(x);
      }
      return m;
    }

    test('Remastered, диакритика и регистр дают один альбом (одна папка)', () {
      final g = byKey([
        tr('1', artist: 'Beyoncé', album: 'Café Lemonade', no: 1),
        tr('2', artist: 'Beyonce', album: 'Cafe Lemonade (Remastered 2020)', no: 2),
      ]);
      expect(g.length, 2);
      expect(mergeAlbumGroups(g).length, 1);
    });

    test('разные альбомы не склеиваются', () {
      final g = byKey([tr('1', artist: 'X', album: 'One'), tr('2', artist: 'X', album: 'Two')]);
      expect(mergeAlbumGroups(g).length, 2);
    });
  });
}
