import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dj_eq.dart';

void main() {
  test(
      'bands transfer independently, only attenuation and flat incoming finish',
      () {
    final a = djEqAt(0, 0.5), m = djEqAt(0.5, 0.5), z = djEqAt(1, 0.5);
    expect(a.$1.bands, [0, 0, 0]);
    expect(a.$2.bands, [-18, -12, -6]);
    expect(z.$2.bands, [0, 0, 0]);
    expect(m.$1.low, closeTo(-9, 0.001));
    for (var i = -5; i < 110; i++) {
      final e = djEqAt(i / 100, 0.5);
      expect(
          [...e.$1.bands, ...e.$2.bands]
              .every((v) => v.isFinite && v >= -18 && v <= 0),
          isTrue);
    }
  });
  test('coalesced automation drains before removing only the owned filter',
      () async {
    final commands = <List<String>>[], gate = Completer<void>();
    final d = DjEqDriver('test', (c) async {
      commands.add(c);
      if (c.first == 'af-command') await gate.future;
    }, () => fail('unexpected failure'));
    expect(await d.install(DjEq.flat), isTrue);
    d.update(const DjEq(-3, -3, -3));
    d.update(const DjEq(-4, -4, -4));
    d.update(const DjEq(-12, -12, -6));
    final close = d.close();
    gate.complete();
    await close;
    expect(commands.first[1], 'add');
    expect(commands.last, ['af', 'remove', '@test']);
    final n = commands.length;
    d.update(DjEq.flat);
    await Future<void>.delayed(Duration.zero);
    expect(commands.length, n);
    expect(commands.where((c) => c.first == 'af-command').length, lessThan(6));
  });
  test('unsupported automation fails once and still cleans its owned filter',
      () async {
    var failures = 0;
    final commands = <List<String>>[];
    final d = DjEqDriver('owned', (c) async {
      commands.add(c);
      if (c.first == 'af-command') throw StateError('unsupported');
    }, () => failures++);
    await d.install(DjEq.flat);
    d.update(const DjEq(-12, 0, 0));
    await Future<void>.delayed(Duration.zero);
    d.update(DjEq.flat);
    await d.close();
    expect(failures, 1);
    expect(commands.last, ['af', 'remove', '@owned']);
  });
}
