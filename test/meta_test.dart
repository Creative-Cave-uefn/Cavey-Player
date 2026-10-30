import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/models.dart';

LibraryData withTrack() => LibraryData()
  ..apply({
    'op': 'upsertTracks',
    'tracks': {
      't1': {'s': 'src', 't': 'Песня', 'a': 'Исполнитель', 'al': 'Альбом', 'm': '2026-01-01', 'sz': 100},
    },
  });

void main() {
  group('данные беты хранятся в edits', () {
    test('длительность и обложка трека накладываются на трек', () {
      final d = withTrack();
      expect(d.tracks['t1']!.durationMs, isNull);
      d.apply({
        'op': 'setMeta',
        'meta': {
          't1': {'d': '183000', 'cv': 'fileX'},
        },
      });
      expect(d.tracks['t1']!.durationMs, 183000);
      expect(d.tracks['t1']!.customCover, 'fileX');
      expect(d.tracks['t1']!.hasCover, isTrue);
    });

    test('пустая обложка и ноль — значит «нет»', () {
      final d = withTrack();
      d.apply({
        'op': 'setMeta',
        'meta': {
          't1': {'d': '0', 'cv': ''},
        },
      });
      expect(d.tracks['t1']!.durationMs, isNull);
      expect(d.tracks['t1']!.customCover, isNull);
      expect(d.tracks['t1']!.hasCover, isFalse);
    });

    test('правки переживают сохранение и перезагрузку файла', () {
      final d = withTrack();
      d.apply({
        'op': 'setMeta',
        'meta': {
          't1': {'d': '5000', 'cv': 'c1', 'a': 'Другой'},
          'album:a\u0001b': {'cv': 'albumCover'},
          'pl:p1': {'cv': 'plCover'},
          'u:me@x.y': {'fa:artist': '1'},
        },
      });
      final back = LibraryData.fromJson(d.toJson());
      expect(back.tracks['t1']!.durationMs, 5000);
      expect(back.tracks['t1']!.customCover, 'c1');
      expect(back.tracks['t1']!.artist, 'Другой');
      expect(back.edits['album:a\u0001b']!['cv'], 'albumCover');
      expect(back.edits['pl:p1']!['cv'], 'plCover');
      expect(back.edits['u:me@x.y']!['fa:artist'], '1');
    });

    test('новый скан файла не стирает правки', () {
      final d = withTrack();
      d.apply({
        'op': 'setMeta',
        'meta': {
          't1': {'d': '777'},
        },
      });
      d.apply({
        'op': 'upsertTracks',
        'tracks': {
          't1': {'s': 'src', 't': 'Песня', 'm': '2026-02-02', 'sz': 120},
        },
      });
      expect(d.tracks['t1']!.durationMs, 777);
    });

    test('повтор операции ничего не ломает', () {
      final d = withTrack();
      final op = {
        'op': 'setMeta',
        'meta': {
          't1': {'d': '42'},
        },
      };
      d.apply(op);
      d.apply(op);
      expect(d.tracks['t1']!.durationMs, 42);
    });
  });
}
