import 'package:cave_player/core/jam.dart';
import 'package:cave_player/core/notices.dart';
import 'package:cave_player/core/ntfy.dart';
import 'package:cave_player/core/player.dart';
import 'package:cave_player/core/search_rank.dart';
import 'package:cave_player/core/web_info.dart';
import 'package:cave_player/ui/player_bar.dart' show seekWaveMin, seekWaveMax;
import 'package:flutter_test/flutter_test.dart';

WebAlbum al(int id, String title, String artist, {String type = 'album'}) => WebAlbum(id, title, 'c', '2024-10-25', type, artist, '');
WebTrack tk(int id, String title, String artist, int albumId, int rank) =>
    WebTrack(id, title, artist, '', 100, '', albumId: albumId, album: title, rank: rank);

JamSnapshot snap(String by, int at, {List<String> q = const ['a', 'b', 'c'], int i = 0, bool playing = true, int pos = 0}) =>
    JamSnapshot(jam: 'j1', by: by, at: at, queue: q, index: i, playing: playing, posMs: pos);

void main() {
  group('Поиск: порядок результатов', () {
    const query = 'sonic x shadow generations';
    final official = al(7, 'Perfect | Reflections - Sonic X Shadow Generations Original Soundtrack', 'Sonic The Hedgehog');
    final metal = al(1, 'Sonic X Shadow Generations (Metal Version)', 'Lame Genie', type: 'single');
    final faker = al(2, 'Faker (Sonic x Shadow Generations Song)', 'Thai McGrath', type: 'single');
    final collide = al(3, 'Sonic X Shadow: Generations Collide', 'Hotline Sehwani');
    final karaoke = al(4, 'Sonic X Shadow Generations (Karaoke Version)', 'Karaoke Hits', type: 'single');

    test('официальный альбом выше каверов, даже если Deezer поставил его седьмым', () {
      final relevance = [metal, faker, collide, karaoke, al(5, 'Chaos Island', 'R.B.U.', type: 'single'), al(6, 'Space Colony Ark', 'Jun Senoue', type: 'single'), official];
      final ranking = [official, collide, faker, metal];
      final ranked = rankAlbums(query, relevance, ranking, tracks: [tk(1, 'Title', 'Sonic Adventure Music Experience', 7, 700000)]);
      expect(ranked.first.id, 7);
      expect(ranked.indexWhere((a) => a.id == 4), greaterThan(ranked.indexWhere((a) => a.id == 7)));
    });

    test('слова «cover» и «karaoke» не штрафуются, если человек искал именно их', () {
      expect(noiseCount('Song (Karaoke Version)', 'song'), 1);
      expect(noiseCount('Song (Karaoke Version)', 'song karaoke'), 0);
      expect(noiseCount('Obvious Album', 'obvious'), 0);
    });

    test('порядок без данных о популярности не ломается и не теряет альбомы', () {
      final a = [al(1, 'One', 'A'), al(2, 'Two', 'B')];
      final ranked = rankAlbums('x', a, const []);
      expect(ranked.map((e) => e.id), unorderedEquals([1, 2]));
      expect(rankAlbums('x', const [], const []), isEmpty);
    });

    test('треки: популярный оригинал выше кавера', () {
      final list = [tk(1, 'Song (Piano Version)', 'Cover Guy', 1, 900000), tk(2, 'Song', 'Real Artist', 2, 500000)];
      expect(rankTracks('song', list).first.id, 2);
    });

    test('исполнители: совпавшее имя и больше подписчиков выше', () {
      final list = [WebArtist(1, 'Sonic Fan', '', 10, ''), WebArtist(2, 'Sonic', '', 1000000, ''), WebArtist(3, 'Other', '', 9000000, '')];
      expect(rankArtists('sonic', list).first.id, 2);
    });
  });

  group('Ровная громкость', () {
    test('поправка в пределах −12…+12 дБ', () {
      expect(PlayerController.normGainDb(-40, -16), 12);
      // Тихий трек из жизни: громкость по шкале анализатора −26,5 дБ при цели «Обычно» поднимается почти на 10 дБ
      expect(PlayerController.normGainDb(-26.5, PlayerController.normTargetDb('normal')), closeTo(10.5, 1e-9));
      expect(PlayerController.normGainDb(-5, -16), -11);
      expect(PlayerController.normGainDb(0, -16), -12);
      expect(PlayerController.normGainDb(-16, -16), 0);
    });

    test('уровни: тише < обычно < громче', () {
      expect(PlayerController.normTargetDb('quiet'), lessThan(PlayerController.normTargetDb('normal')));
      expect(PlayerController.normTargetDb('normal'), lessThan(PlayerController.normTargetDb('loud')));
      expect(PlayerController.normTargetDb('что-то'), PlayerController.normTargetDb('normal'));
    });

    test('множитель: 0 дБ — без изменений, −6 дБ — примерно вдвое тише', () {
      expect(PlayerController.dbToFactor(0), closeTo(1, 1e-9));
      expect(PlayerController.dbToFactor(-6), closeTo(0.501, 0.001));
    });

    test('громкость mpv кубическая: множитель для volume в кубе даёт ровно заданные децибелы', () {
      for (final db in [-12.0, -7.0, -3.0, 0.0, 2.0, 4.0]) {
        final f = PlayerController.dbToVolumeFactor(db);
        expect(f * f * f, closeTo(PlayerController.dbToFactor(db), 1e-9));
      }
      // Приглушение на 7 дБ срезает свойство volume лишь до ~0,76, а не до ~0,45 как при линейном множителе
      expect(PlayerController.dbToVolumeFactor(-7), greaterThan(0.75));
    });
  });

  group('Плавный переход', () {
    test('ход перехода идёт от 0 до 1', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final info = CrossfadeInfo(0.9, t0, 4000);
      expect(info.progress(t0), 0);
      expect(info.progress(t0.add(const Duration(seconds: 2))), closeTo(0.5, 1e-9));
      expect(info.progress(t0.add(const Duration(seconds: 9))), 1);
    });

    test('полоса уходящего трека идёт с прежней скоростью и доходит до края', () {
      final t0 = DateTime(2026, 1, 1, 12);
      // Трек 100 с, переход начался на 90 %: осталось 10 с
      final info = CrossfadeInfo(0.9, t0, 10000, oldDurationMs: 100000);
      double at(int s) => info.fraction(t0.add(Duration(seconds: s)));
      expect(at(0), closeTo(0.9, 1e-9));
      // Скорость одинакова на всём протяжении: 1 % длины трека в секунду, как и до перехода
      expect(at(1) - at(0), closeTo(0.01, 1e-9));
      expect(at(6) - at(5), closeTo(0.01, 1e-9));
      expect(at(10), closeTo(1.0, 1e-9));
      expect(at(15), 1.0);
    });

    test('хвост полосы: ровно гаснет за время перехода, пока идёт с прежней скоростью', () {
      final t0 = DateTime(2026, 1, 1, 12);
      // Переход 4 с, до конца трека ещё 10 с: полоса гаснет за 4 с и не доезжает до края, а не прыгает к нему
      final info = CrossfadeInfo(0.9, t0, 4000, oldDurationMs: 100000);
      expect(info.fadeMs, 4000);
      expect(info.totalMs, 4000);
      expect(info.alpha(t0), 1.0);
      expect(info.alpha(t0.add(const Duration(seconds: 2))), closeTo(0.5, 1e-9));
      expect(info.alpha(t0.add(const Duration(seconds: 4))), 0.0);
      // За это время она прошла ровно столько, сколько прошёл бы слайдер
      expect(info.fraction(t0.add(const Duration(seconds: 4))), closeTo(0.94, 1e-9));
    });

    test('обычный переход: до края остаётся ровно время перехода, полоса гаснет к моменту прихода', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final info = CrossfadeInfo(0.97, t0, 3000, oldDurationMs: 100000);
      expect(info.reachMs, 3000);
      expect(info.fadeMs, 3000);
      expect(info.fraction(t0.add(const Duration(seconds: 3))), closeTo(1.0, 1e-9));
      expect(info.alpha(t0.add(const Duration(seconds: 3))), 0.0);
    });

    test('полоса не ускоряется и не прыгает: шаг по кадрам везде одинаковый', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final info = CrossfadeInfo(0.95, t0, 5000, oldDurationMs: 200000);
      var prev = info.fraction(t0);
      for (var ms = 16; ms <= info.totalMs; ms += 16) {
        final f = info.fraction(t0.add(Duration(milliseconds: ms)));
        expect(f - prev, closeTo(16 / 200000, 1e-9));
        prev = f;
      }
    });

    test('без плавного перехода полоса плавно гаснет на месте', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final info = CrossfadeInfo(0.4, t0, 0);
      expect(info.fraction(t0.add(const Duration(seconds: 1))), 0.4);
      expect(info.alpha(t0), 1.0);
      expect(info.alpha(t0.add(const Duration(milliseconds: 450))), closeTo(0.5, 1e-9));
      expect(info.alpha(t0.add(const Duration(seconds: 1))), 0.0);
    });

    test('без длины трека полоса идёт линейно за время перехода', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final info = CrossfadeInfo(0.8, t0, 4000);
      expect(info.fraction(t0.add(const Duration(seconds: 2))), closeTo(0.9, 1e-9));
    });
  });

  group('Длина волны', () {
    test('шкала: короче 17 нельзя, вправо длиннее прежнего', () {
      expect(seekWaveMin, 17);
      expect(seekWaveMax, greaterThan(40));
    });
  });

  group('Джем: состояние', () {
    test('побеждает снимок с более поздним временем, при равенстве — по почте', () {
      final a = snap('a@x', 100);
      final b = snap('b@x', 200);
      expect(b.newerThan(a), isTrue);
      expect(a.newerThan(b), isFalse);
      expect(snap('b@x', 100).newerThan(snap('a@x', 100)), isTrue);
      expect(a.newerThan(null), isTrue);
    });

    test('любой порядок получения даёт одно и то же итоговое состояние', () {
      final list = [snap('a@x', 100, i: 1), snap('b@x', 300, i: 2), snap('c@x', 200, i: 0), snap('a@x', 300, i: 1)];
      JamSnapshot? run(List<JamSnapshot> order) {
        JamSnapshot? st;
        for (final s in order) {
          if (s.newerThan(st)) st = s;
        }
        return st;
      }

      final forward = run(list)!;
      final backward = run(list.reversed.toList())!;
      final shuffled = run([list[2], list[0], list[3], list[1]])!;
      expect(forward.by, backward.by);
      expect(forward.by, shuffled.by);
      expect(forward.at, 300);
      expect(forward.by, 'b@x'); // при одинаковом времени побеждает большая почта
    });

    test('позиция досчитывается по времени действия, на паузе стоит', () {
      expect(snap('a', 1000, pos: 83000).positionAt(3000), const Duration(milliseconds: 85000));
      expect(snap('a', 1000, pos: 83000, playing: false).positionAt(9000), const Duration(milliseconds: 83000));
      // Часы участника чуть впереди: позиция не уходит в минус
      expect(snap('a', 5000, pos: 1000).positionAt(4000), const Duration(milliseconds: 1000));
    });

    test('перемотка нужна только при расхождении больше 0,7 с', () {
      expect(jamNeedsSeek(const Duration(seconds: 10), const Duration(milliseconds: 10500)), isFalse);
      expect(jamNeedsSeek(const Duration(seconds: 10), const Duration(milliseconds: 11000)), isTrue);
    });

    test('в сообщение попадает окно очереди: не больше лимита, текущий в нём', () {
      final big = [for (var i = 0; i < 300; i++) 't$i'];
      final (w, i) = jamWindow(big, 150);
      expect(w.length, jamQueueWindow);
      expect(w[i], 't150');
      final (w2, i2) = jamWindow(big, 1);
      expect(w2.first, 't0');
      expect(w2[i2], 't1');
      expect(jamWindow(const [], -1).$1, isEmpty);
    });

    test('снимок переживает запись и чтение', () {
      final s = snap('a@x', 42, q: ['x', 'y'], i: 1, playing: false, pos: 1234);
      final back = JamSnapshot.fromJson(s.toJson())!;
      expect(back.by, 'a@x');
      expect(back.queue, ['x', 'y']);
      expect(back.index, 1);
      expect(back.playing, isFalse);
      expect(back.posMs, 1234);
      expect(back.trackId, 'y');
      expect(JamSnapshot.fromJson('мусор'), isNull);
    });

    test('«трек закончился» от нескольких участников не пропускает трек', () {
      // Каждый строит «следующий» от одной и той же очереди и индекса — получается один результат
      JamSnapshot next(String by, int at) => JamSnapshot(jam: 'j1', by: by, at: at, queue: const ['a', 'b', 'c'], index: 1, playing: true, posMs: 0);
      var st = snap('a@x', 100);
      for (final s in [next('a@x', 200), next('b@x', 201), next('c@x', 202)]) {
        if (s.newerThan(st)) st = s;
      }
      expect(st.trackId, 'b');
    });
  });

  group('Уведомления о джеме', () {
    final now = DateTime.utc(2026, 11, 9, 12);
    test('приглашение разбирается и действует 10 минут', () {
      final list = collectNotices(
        me: 'me@x',
        events: [
          ('a@x', now, {'k': 'jaminv', 'jam': 'j1', 'to': ['me@x', 'z@x']}),
          ('b@x', now, {'k': 'jaminv', 'jam': 'j2', 'to': ['z@x']}),
        ],
        uploaderOf: (_) => '',
      );
      expect(list.length, 1);
      final n = list.single;
      expect(n.kind, NoticeKind.jamInvite);
      expect(n.jam, 'j1');
      expect(n.expired(now.add(const Duration(minutes: 9))), isFalse);
      expect(n.expired(now.add(const Duration(minutes: 11))), isTrue);
    });

    test('запрос на вход приходит каждому участнику; ответ-приглашение помечен', () {
      final events = [
        ('a@x', now, {'k': 'jamreq', 'jam': 'j1', 'to': ['me@x', 'other@x']}),
        ('c@x', now, {'k': 'jaminv', 'jam': 'j1', 'to': ['me@x'], 're': true}),
      ];
      final mine = collectNotices(me: 'me@x', events: events, uploaderOf: (_) => '');
      expect(mine.where((n) => n.kind == NoticeKind.jamRequest).length, 1);
      expect(mine.singleWhere((n) => n.kind == NoticeKind.jamInvite).reply, isTrue);
      final theirs = collectNotices(me: 'other@x', events: events, uploaderOf: (_) => '');
      expect(theirs.single.kind, NoticeKind.jamRequest);
    });

    test('текст уведомления о джеме не требует трека', () {
      final n = Notice(NoticeKind.jamInvite, 'a@x', now, const [], jam: 'j1');
      expect(noticeText(n, who: 'Данила', title: (_) => '', label: (_) => ''), 'Данила зовёт в джем');
    });
  });

  group('Быстрый канал', () {
    test('тема стабильна, не угадывается и не раскрывает папку', () {
      final t = NtfyChannel.topicFor('folder123');
      expect(t, NtfyChannel.topicFor('folder123'));
      expect(t, isNot(NtfyChannel.topicFor('folder124')));
      expect(t.startsWith('cavey-'), isTrue);
      expect(t.contains('folder123'), isFalse);
      expect(t.length, 'cavey-'.length + 32);
    });
  });
}
