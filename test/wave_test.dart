import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/wave.dart';

Track tr(String id, String artist) => Track(
      id: id,
      source: 's',
      title: 'T$id',
      artist: artist,
      album: '',
      albumArtist: '',
      no: null,
      year: '',
      pic: null,
      cover: null,
      modified: '',
      size: 1,
      by: '',
      path: '',
    );

void main() {
  final lib = [
    for (var i = 0; i < 10; i++) tr('a$i', 'Alpha'),
    for (var i = 0; i < 10; i++) tr('b$i', 'Beta'),
    for (var i = 0; i < 10; i++) tr('c$i', 'Gamma'),
  ];

  Map<String, int> countArtists(List<String> ids) {
    final m = <String, int>{};
    for (final id in ids) {
      m[id[0]] = (m[id[0]] ?? 0) + 1;
    }
    return m;
  }

  test('без повторов внутри выборки и без «не нравится»', () {
    final taste = WaveTaste()..disliked.add('a0');
    final ids = WaveEngine.pick(WaveInputs(tracks: lib, taste: taste), WaveMode.mix, 20, rnd: Random(1));
    expect(ids.length, 20);
    expect(ids.toSet().length, 20);
    expect(ids, isNot(contains('a0')));
  });

  test('не повторяет недавнее, пока есть выбор', () {
    final recent = [for (var i = 0; i < 10; i++) 'a$i'];
    final ids = WaveEngine.pick(WaveInputs(tracks: lib), WaveMode.mix, 10, recent: recent, rnd: Random(2));
    expect(ids.where(recent.contains), isEmpty);
  });

  test('лайки тянут исполнителя наверх в «Любимом»', () {
    final x = WaveInputs(tracks: lib, liked: {'a1', 'a2', 'a3'});
    final all = <String>[];
    for (var s = 0; s < 40; s++) {
      all.addAll(WaveEngine.pick(x, WaveMode.favorite, 6, rnd: Random(s)));
    }
    final c = countArtists(all);
    expect(c['a']!, greaterThan((c['b'] ?? 0) * 2));
  });

  test('«Незнакомое» почти не ставит уже слышанное', () {
    final x = WaveInputs(tracks: lib, myPlays: {for (final t in lib.take(20)) t.id: 3});
    final ids = WaveEngine.pick(x, WaveMode.unfamiliar, 8, rnd: Random(3));
    expect(ids.where((id) => id.startsWith('c')).length, greaterThanOrEqualTo(6));
  });

  test('пропуски в этой волне убирают исполнителя', () {
    final x = WaveInputs(tracks: lib, session: {'beta': -12});
    final all = <String>[];
    for (var s = 0; s < 30; s++) {
      all.addAll(WaveEngine.pick(x, WaveMode.mix, 6, rnd: Random(s)));
    }
    final c = countArtists(all);
    expect(c['b'] ?? 0, lessThan((c['a'] ?? 0) ~/ 3));
  });

  test('похожие исполнители получают часть симпатии', () {
    final x = WaveInputs(tracks: lib, favArtists: {'alpha'}, related: {'alpha': ['gamma']});
    final aff = WaveEngine.affinity(x);
    expect(aff['gamma']!, greaterThan(0));
    expect(aff['beta'] ?? 0, 0);
  });

  test('один исполнитель не идёт подряд, если есть другие', () {
    final ids = WaveEngine.pick(WaveInputs(tracks: lib), WaveMode.mix, 12, rnd: Random(5));
    var same = 0;
    for (var i = 1; i < ids.length; i++) {
      if (ids[i][0] == ids[i - 1][0]) same++;
    }
    expect(same, lessThan(5));
  });

  test('вкус сохраняется', () {
    final t = WaveTaste()
      ..bump('alpha', 2)
      ..disliked.add('x')
      ..skips['y'] = 2;
    final back = WaveTaste.fromJson(t.toJson());
    expect(back.artists['alpha'], 2);
    expect(back.disliked, {'x'});
    expect(back.skips['y'], 2);
  });
}
