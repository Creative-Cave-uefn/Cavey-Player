import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/crossfade.dart';

void main() {
  test('both tracks sustain a stable overlap before and after the bass swap', () {
    final plateau = phraseBlendGains(0.5);
    for (final t in [0.2, 0.3, 0.5, 0.7, 0.8]) {
      final g = phraseBlendGains(t);
      expect(g.$1, closeTo(plateau.$1, 1e-9));
      expect(g.$2, closeTo(plateau.$2, 1e-9));
      expect(g.$1, greaterThan(0.7));
      expect(g.$2, greaterThan(0.7));
    }
  });
  test('entry and exit keep constant power and continuous endpoints', () {
    expect(phraseBlendGains(0).$1, 1);
    expect(phraseBlendGains(0).$2, 0);
    expect(phraseBlendGains(1).$1, closeTo(0, 1e-9));
    expect(phraseBlendGains(1).$2, closeTo(1, 1e-9));
    for (var i = 0; i <= 100; i++) {
      final g = phraseBlendGains(i / 100);
      expect(g.$1 * g.$1 + g.$2 * g.$2, closeTo(1, 1e-9));
    }
  });
  test('mpv slider conversion preserves the intended audible amplitude envelope', () {
    for (final amplitude in [0.0, 0.1, 0.3, 0.707, 1.0]) {
      final slider = amplitudeToMpvVolume(amplitude);
      expect(math.pow(slider, 3), closeTo(amplitude, 1e-9));
    }
  });
}
