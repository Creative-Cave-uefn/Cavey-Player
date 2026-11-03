import 'package:cave_player/core/dl/service.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/store.dart';
import 'package:cave_player/core/web_info.dart';
import 'package:cave_player/ui/download_view.dart';
import 'package:cave_player/ui/list_filter.dart';
import 'package:cave_player/ui/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;
Track tr(String album, {bool covered = true, String? custom}) => Track(
      id: 'b8_${_n++}',
      source: 's',
      title: 'T',
      artist: 'Artist',
      album: album,
      albumArtist: '',
      no: null,
      disc: null,
      year: '',
      pic: null,
      cover: covered ? 'cover.jpg' : null,
      modified: '',
      size: 0,
      by: '',
      path: 'p',
      added: '',
    )..customCover = custom;

WebAlbum wa(String date, {String cover = 'https://cdn-images.dzcdn.net/images/cover/0123456789abcdef0123456789abcdef/1000x1000-000000-80-0-0.jpg'}) =>
    WebAlbum(1, 'A', cover, date, 'album', 'Artist', '');

void main() {
  group('Сетка обложек плейлиста', () {
    test('четыре разных обложки — сетка', () {
      final g = gridCoverTracks([tr('a'), tr('b'), tr('c'), tr('d'), tr('e')]);
      expect(g.length, 4);
      expect(g.map((t) => t.album), ['a', 'b', 'c', 'd']);
    });

    test('повторы обложек не считаются, треки без обложки пропускаются', () {
      final g = gridCoverTracks([tr('a'), tr('a'), tr('x', covered: false), tr('b'), tr('c'), tr('c'), tr('d')]);
      expect(g.map((t) => t.album), ['a', 'b', 'c', 'd']);
    });

    test('меньше четырёх разных — сетки нет', () {
      expect(gridCoverTracks([tr('a'), tr('a'), tr('b'), tr('c')]), isEmpty);
      expect(gridCoverTracks(const []), isEmpty);
    });

    test('своя обложка трека отличает его от остальных того же альбома', () {
      final g = gridCoverTracks([tr('a'), tr('a', custom: 'c1'), tr('a', custom: 'c2'), tr('a', custom: 'c3')]);
      expect(g.length, 4);
    });
  });

  group('Сортировка плейлистов', () {
    test('новые режимы читаются и пишутся', () {
      final s = Settings();
      const ListSort('count', true).write(s, 'playlists');
      expect(ListSort.read(s, 'playlists').mode, 'count');
      const ListSort('author', false).write(s, 'playlists');
      final back = ListSort.read(s, 'playlists');
      expect(back.mode, 'author');
      expect(back.desc, isFalse);
      const ListSort('date', true).write(s, 'playlists');
      expect(ListSort.read(s, 'playlists').mode, 'date');
    });

    test('неизвестный режим — по названию; направление по умолчанию', () {
      final s = Settings()..view['sort.playlists'] = 'bogus|1';
      expect(ListSort.read(s, 'playlists').mode, 'name');
      expect(ListSort.defaultDesc('name'), isFalse);
      expect(ListSort.defaultDesc('author'), isFalse);
      expect(ListSort.defaultDesc('count'), isTrue);
      expect(ListSort.defaultDesc('date'), isTrue);
    });
  });

  group('Офлайн-альбомы', () {
    test('сохраняются в настройках', () {
      final s = Settings()..offlineAlbums = {'artist|album'};
      final back = Settings.fromJson(s.toJson());
      expect(back.offlineAlbums, {'artist|album'});
      expect(Settings.fromJson({}).offlineAlbums, isEmpty);
    });
  });

  group('Новинки: заглушки Deezer', () {
    final now = DateTime(2026, 11, 3);
    final since = now.subtract(const Duration(days: 120));

    test('дата 31.12.2999 не годится и не показывается', () {
      final a = wa('2999-12-31');
      expect(a.hasRealDate, isFalse);
      expect(a.year, '');
      expect(a.isFreshRelease(since, now), isFalse);
    });

    test('сортировка: заглушка уходит вниз', () {
      final dates = ['2999-12-31', '2026-10-01', '2026-09-01']..sort((a, b) => wa(b).sortDate.compareTo(wa(a).sortDate));
      expect(dates.first, '2026-10-01');
      expect(dates.last, '2999-12-31');
    });

    test('свежий релиз с обложкой проходит; без обложки, старый и из далёкого будущего — нет', () {
      expect(wa('2026-10-20').isFreshRelease(since, now), isTrue);
      expect(wa('2026-11-20').isFreshRelease(since, now), isTrue); // анонс на ближайшие недели
      expect(wa('2027-06-01').isFreshRelease(since, now), isFalse);
      expect(wa('2025-01-01').isFreshRelease(since, now), isFalse);
      expect(wa('2026-10-20', cover: '').isFreshRelease(since, now), isFalse);
      expect(wa('2026-10-20', cover: 'https://cdn-images.dzcdn.net/images/cover/1000x1000-000000-80-0-0.jpg').isFreshRelease(since, now), isFalse);
    });

    test('обычная дата показывает год', () {
      expect(wa('2024-05-17').year, '2024');
    });
  });

  group('Сторож заданий «Скачать»', () {
    test('3 минуты без движения — зависание', () {
      final last = DateTime(2026, 11, 3, 12);
      expect(DownloadService.isStalled(last, last.add(const Duration(minutes: 2, seconds: 59))), isFalse);
      expect(DownloadService.isStalled(last, last.add(const Duration(minutes: 3))), isTrue);
    });

    test('«Перезапустить» есть не у замены аудио', () {
      expect(DownloadJob('a - b', 'src', 'F').restartable, isTrue);
      expect(DownloadJob('a - b', 'src', 'F', replaceTrackId: 'x').restartable, isFalse);
      expect(DownloadJob('Обновление', '', '').restartable, isFalse);
    });
  });

  group('Плавная полоса прогресса', () {
    test('растёт внутри текущего трека, но не доходит до следующего шага', () {
      const total = 10;
      final start = jobProgressTarget(3, total, Duration.zero);
      final mid = jobProgressTarget(3, total, const Duration(seconds: 20));
      final late = jobProgressTarget(3, total, const Duration(minutes: 10));
      expect(start, closeTo(0.3, 1e-9));
      expect(mid, greaterThan(start));
      expect(late, lessThan(0.4));
      expect(late, greaterThan(mid));
    });

    test('всё готово — полная полоса; пустое задание — ноль', () {
      expect(jobProgressTarget(10, 10, const Duration(minutes: 1)), 1.0);
      expect(jobProgressTarget(0, 0, Duration.zero), 0);
    });
  });
}
