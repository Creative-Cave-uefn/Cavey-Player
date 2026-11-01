import 'package:cave_player/core/album_match.dart';
import 'package:cave_player/core/library.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/store.dart';
import 'package:cave_player/core/web_info.dart';
import 'package:cave_player/ui/list_filter.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;
Track t(String title, {int? no, int? disc, int? sec, String added = '', String modified = '', String album = 'Album'}) => Track(
      id: 'b7_${_n++}',
      source: 's',
      title: title,
      artist: 'Artist',
      album: album,
      albumArtist: '',
      no: no,
      disc: disc,
      year: '',
      pic: null,
      cover: null,
      modified: modified,
      size: 0,
      by: '',
      path: 'p',
      added: added,
    )..durationMs = sec == null ? null : sec * 1000;

WebTrack w(String title, int sec, {int disc = 1}) => WebTrack(_n++, title, 'Artist', '', sec, '', disc: disc);

void main() {
  group('Номер диска', () {
    test('нет в тегах или нуль — первый диск', () {
      expect(discOf(t('a')), 1);
      expect(discOf(t('a', disc: 0)), 1);
      expect(discOf(t('a', disc: 2)), 2);
    });
  });

  group('Недостающие треки альбома', () {
    test('одно и то же название — трек есть', () {
      final own = [t('Intro', no: 1, sec: 60), t('Song (Remastered)', no: 2, sec: 200)];
      final miss = missingByMatch(own, [w('Intro', 60), w('Song', 200), w('Bonus', 180)]);
      expect(miss.map((x) => x.title), ['Bonus']);
    });

    test('японское название у вас и английское в Deezer — не предлагаем скачать заново', () {
      final own = [t('夜明け', no: 1, sec: 215), t('光', no: 2, sec: 187), t('星空', no: 3, sec: 240)];
      final web = [w('Daybreak', 215), w('Light', 188), w('Starry Sky', 240)];
      expect(missingByMatch(own, web), isEmpty);
    });

    test('номер совпал, а длительность сильно другая — это другой трек', () {
      final own = [t('夜明け', no: 1, sec: 215)];
      final miss = missingByMatch(own, [w('Other Song', 120)]);
      expect(miss.map((x) => x.title), ['Other Song']);
    });

    test('многодисковый альбом: номера на разных дисках не путаются', () {
      final own = [t('日', no: 1, disc: 1, sec: 100), t('月', no: 1, disc: 2, sec: 300)];
      final web = [w('Sun', 100, disc: 1), w('Moon', 300, disc: 2), w('Moon 2', 150, disc: 2)];
      expect(missingByMatch(own, web).map((x) => x.title), ['Moon 2']);
    });

    test('один свой трек засчитывается один раз', () {
      final own = [t('Song', no: 1, sec: 200)];
      final miss = missingByMatch(own, [w('Song', 200), w('Song (Live)', 201)]);
      expect(miss.length, 1);
    });

    test('трек, который лежит в другом альбоме библиотеки, не предлагается', () {
      final miss = missingByMatch([], [w('Lost', 100), w('Other', 90)], inLibrary: (x) => x.title == 'Lost');
      expect(miss.map((x) => x.title), ['Other']);
    });
  });

  group('Время лайка', () {
    test('ставится при лайке и убирается при снятии', () {
      final d = LibraryData();
      d.apply({'op': 'like', 'id': 'x', 'email': 'a@b', 'on': true, 'ts': 1700000000000});
      expect(d.likeTimes['x|a@b'], 1700000000000);
      d.apply({'op': 'like', 'id': 'x', 'email': 'a@b', 'on': false});
      expect(d.likeTimes.containsKey('x|a@b'), isFalse);
    });

    test('старый лайк без времени не ломает разбор', () {
      final d = LibraryData();
      d.apply({'op': 'like', 'id': 'x', 'email': 'a@b', 'on': true});
      expect(d.likes['x'], {'a@b'});
      expect(d.likeTimes, isEmpty);
    });

    test('время лайка переживает сохранение и чтение', () {
      final d = LibraryData();
      d.apply({'op': 'like', 'id': 'x', 'email': 'a@b', 'on': true, 'ts': 42});
      final back = LibraryData.fromJson(d.toJson());
      expect(back.likeTimes['x|a@b'], 42);
    });
  });

  group('Сортировка списков', () {
    test('запоминается вместе с направлением', () {
      final s = Settings();
      const ListSort('count', true).write(s, 'albums');
      final back = ListSort.read(s, 'albums');
      expect(back.mode, 'count');
      expect(back.desc, isTrue);
      const ListSort('first', false).write(s, 'albums');
      expect(ListSort.read(s, 'albums').desc, isFalse);
    });

    test('без записи — по названию; мусор вместо режима тоже даёт название', () {
      final s = Settings();
      expect(ListSort.read(s, 'eps').mode, 'name');
      expect(ListSort.read(s, 'eps', legacyDesc: true).desc, isTrue);
      s.view['sort.eps'] = 'странно|1';
      expect(ListSort.read(s, 'eps').mode, 'name');
    });

    test('новые и крупные сверху по умолчанию, имена по алфавиту', () {
      expect(ListSort.defaultDesc('first'), isTrue);
      expect(ListSort.defaultDesc('count'), isTrue);
      expect(ListSort.defaultDesc('name'), isFalse);
    });

    test('первая загрузка — самая ранняя дата среди треков', () {
      final tracks = [
        t('a', added: '2024-05-02T10:00:00Z'),
        t('b', added: '2023-01-09T10:00:00Z'),
        t('c', modified: '2025-01-01T10:00:00Z'),
      ];
      expect(firstUpload(tracks), '2023-01-09T10:00:00Z');
      expect(firstUpload(const []), '');
    });
  });
}
