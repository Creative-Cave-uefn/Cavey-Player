import 'dart:math';

import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/wave.dart';
import 'package:flutter_test/flutter_test.dart';

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
  ];

  Set<String> drawn(WaveInputs x, {int rounds = 30}) {
    final all = <String>{};
    for (var s = 0; s < rounds; s++) {
      all.addAll(WaveEngine.pick(x, WaveMode.mix, 6, rnd: Random(s)));
    }
    return all;
  }

  test('«не нравится» действует только в том контексте, где поставлено', () {
    final taste = WaveTaste()..dislike('a0', '');
    expect(drawn(WaveInputs(tracks: lib, taste: taste)), isNot(contains('a0')));
    // В «мрачном» настроении этот трек снова доступен
    expect(drawn(WaveInputs(tracks: lib, taste: taste, ctx: 'dark')), contains('a0'));
  });

  test('«не нравится», поставленное в настроении, не действует в обычной волне', () {
    final taste = WaveTaste()..dislike('a0', 'dark');
    expect(drawn(WaveInputs(tracks: lib, taste: taste, ctx: 'dark')), isNot(contains('a0')));
    expect(drawn(WaveInputs(tracks: lib, taste: taste)), contains('a0'));
  });

  test('«не нравится» забывается через 30 дней', () {
    final t0 = DateTime(2026, 1, 1);
    final taste = WaveTaste()..dislike('a0', '', t0);
    taste.decay(t0.add(const Duration(days: 29)));
    expect(taste.isDisliked('a0', ''), isTrue);
    taste.decay(t0.add(const Duration(days: 31)));
    expect(taste.isDisliked('a0', ''), isFalse);
    expect(taste.disliked, isEmpty);
  });

  test('минус исполнителю не выходит за свой контекст', () {
    final taste = WaveTaste()..bump('beta', -8, ctx: '');
    List<String> picks(String ctx) {
      final x = WaveInputs(tracks: lib, taste: taste, ctx: ctx);
      return [for (var s = 0; s < 30; s++) ...WaveEngine.pick(x, WaveMode.mix, 6, rnd: Random(s))];
    }

    int betas(List<String> l) => l.where((id) => id.startsWith('b')).length;
    // В обычной волне Beta почти не звучит, а в «мрачном» настроении — как будто минуса и не было
    expect(betas(picks('')), lessThan(betas(picks('dark')) ~/ 2));
  });

  test('минус исполнителю остывает заметно быстрее плюса', () {
    final t0 = DateTime(2026, 1, 1);
    final taste = WaveTaste()
      ..decayedAt = t0
      ..bump('alpha', 4)
      ..bump('beta', -4);
    taste.decay(t0.add(const Duration(days: 14)));
    // ×0,98^14 ≈ 0,75 у плюса и ×0,92^14 ≈ 0,31 у минуса
    expect(taste.artists['alpha']!, greaterThan(2.5));
    expect(taste.negFor('')['beta']!.abs(), lessThan(1.5));
  });

  test('пропуски трека учитываются по контексту и забываются', () {
    final t0 = DateTime(2026, 1, 1);
    final taste = WaveTaste()
      ..addSkip('a1', 'dark', t0)
      ..addSkip('a1', 'dark', t0);
    expect(taste.skipsOf('a1', 'dark'), 2);
    expect(taste.skipsOf('a1', ''), 0);
    taste.decay(t0.add(const Duration(days: 22)));
    expect(taste.skipsOf('a1', 'dark'), 0);
  });

  test('дослушивание прощает один пропуск', () {
    final taste = WaveTaste()
      ..addSkip('a1', '')
      ..addSkip('a1', '');
    taste.forgiveSkip('a1', '');
    expect(taste.skipsOf('a1', ''), 1);
    taste.forgiveSkip('a1', '');
    expect(taste.skipsOf('a1', ''), 0);
    expect(taste.skips, isEmpty);
  });

  test('режим настройки: лайки весят в полтора раза больше', () {
    double alpha(double k) =>
        WaveEngine.affinity(WaveInputs(tracks: lib, liked: {'a1', 'a2', 'a3'}, likeBoost: k))['alpha']!;
    expect(alpha(1.5), closeTo(alpha(1.0) * 1.5, 0.001));
  });

  test('новые поля сохраняются и читаются', () {
    final taste = WaveTaste()
      ..dislike('x', 'dark')
      ..addSkip('y', 'sad')
      ..bump('alpha', -3, ctx: 'dark');
    final back = WaveTaste.fromJson(taste.toJson());
    expect(back.isDisliked('x', 'dark'), isTrue);
    expect(back.skipsOf('y', 'sad'), 1);
    expect(back.negFor('dark')['alpha'], lessThan(0));
  });

  test('старый формат: минусы из artists уходят в обычную волну, у банов появляется срок', () {
    final back = WaveTaste.fromJson({
      'artists': {'alpha': 3.0, 'beta': -5.0},
      'disliked': ['x'],
      'skips': {'y': 2},
    });
    expect(back.artists.containsKey('beta'), isFalse);
    expect(back.negFor('')['beta'], lessThan(0));
    expect(back.artists['alpha'], greaterThan(2.9));
    expect(back.isDisliked('x', ''), isTrue);
    expect(back.dislikedMeta.containsKey('x'), isTrue);
    expect(back.skipsOf('y', ''), 2);
  });
}
