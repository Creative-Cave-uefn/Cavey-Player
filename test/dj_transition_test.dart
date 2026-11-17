import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dj.dart';
import 'package:cave_player/core/dj_transition.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/transition_verifier.dart';

void main() {
  test('phase sign and seek latency correction converge without 45ms guess', () {
    const g=(0.0,500.0,0.0,500.0);
    expect(djPhaseError(g,1,1000,1167),167);
    expect(djPhaseError(g,1,1167,1000),-167);
    final target=alignedIncomingPosition(1167,167,1,1,80);
    expect(target,1080);
    expect(djPhaseError(g,1,1080,target),0);
    expect(djPhaseError((0,500,0,250),1,1250,1250),0);
    expect(djPhaseError((0,250,0,500),1,1250,1250),0);
  });
  test('pitch restoration is bounded, monotonic, and ends at original', () {
    for(final shift in [-1,1]) {
      var previous=restoredPitchScale(shift,0);
      expect(previous,pitchScale(shift));
      for(var i=1;i<=12;i++) {
        final next=restoredPitchScale(shift,i/12);
        expect((next-1).abs(),lessThanOrEqualTo((previous-1).abs()+1e-12));
        previous=next;
      }
      expect(previous,1);
    }
  });
  test('semitone transposition follows pitches, not Camelot neighbours', () {
    expect(shiftedKey(Camelot.parse('C')!, 1), Camelot.parse('C#'));
    expect(shiftedKey(Camelot.parse('Am')!, -1), Camelot.parse('Abm'));
    for (var n = 1; n <= 12; n++) {
      for (final minor in [false, true]) {
        final key = Camelot(n, minor);
        expect(shiftedKey(shiftedKey(key, 1), -1), key);
      }
    }
    expect(pitchScale(1) * pitchScale(-1), closeTo(1, 1e-12));
  });
  test('original pitch wins for already compatible tracks', () {
    expect(harmonicShift(const Camelot(8, true), const Camelot(9, true)), 0);
    expect(harmonicShift(Camelot.parse('Am')!, Camelot.parse('Abm')!), 1);
    for (var n = 1; n <= 12; n++) {
      final a = Camelot(8, true), b = Camelot(n, false);
      final shift = harmonicShift(a, b);
      expect(shift.abs(), lessThanOrEqualTo(1));
      expect(Camelot.compat(a, shiftedKey(b, shift)),
          greaterThanOrEqualTo(Camelot.compat(a, b)));
    }
  });
  test('shared tempo remains synced and finishes at the incoming native tempo',
      () {
    // Includes ratios arising from half/double-time matches.
    for (final ratio in [0.84, 0.92, 1.0, 1.08, 1.2]) {
      expect(djTempoAt(0, ratio).$1, 1);
      expect(djTempoAt(0, ratio).$2, ratio);
      expect(djTempoAt(0.75, ratio).$2, closeTo(1, 1e-12));
      for (var i = 0; i <= 100; i++) {
        final rates = djTempoAt(i / 100, ratio);
        expect(rates.$2 / rates.$1, closeTo(ratio, 1e-12));
        expect(rates.$1, inInclusiveRange(0.8, 1.25));
      }
    }
  });
  test('tempo ramp consumes the exact planned source windows', () {
    for (final ratio in [0.92, 1.08]) {
      var outgoing = 0.0, incoming = 0.0;
      const length = 16000.0, step = 1.0;
      while (outgoing < length) {
        final rates = djTempoAt(outgoing / length, ratio);
        final dt = ((length - outgoing) / rates.$1).clamp(0.0, step);
        outgoing += rates.$1 * dt;
        incoming += rates.$2 * dt;
      }
      expect(outgoing, closeTo(length, 0.001));
      expect(incoming, closeTo(length * ratio, 0.001));
    }
  });
  test('preflight renders both actual pitch shifts', () {
    const p = MixPlan(Duration.zero, Duration(seconds: 4), Duration.zero, 1,
        dj: true, transpose: 1, outgoingShift: -1, tempoRamp: true);
    final graph = TransitionVerifier.graph(p);
    expect(graph, contains(pitchFilter(1)));
    expect(graph, contains(pitchFilter(-1)));
    expect(const DjMix().transpose, isFalse);
  });
}
