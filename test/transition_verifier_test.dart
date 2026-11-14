import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/transition_verifier.dart';

void main() {
  const p = MixPlan(Duration.zero, Duration(seconds: 4), Duration.zero, 1,
      dj: true, swapAt: Duration(seconds: 2));
  test(
      'preflight rejects missing measurements, silence, nonfinite and inadequate headroom',
      () {
    expect(TransitionVerifier.parseMeasurements('Peak: -8.0 dBFS').verdict,
        TransitionVerdict.accepted);
    for (final log in [
      'Peak: 0.2 dBFS',
      'Peak: -90.0 dBFS',
      'Number of NaNs: 12\nPeak: -8 dBFS'
    ]) {
      expect(TransitionVerifier.parseMeasurements(log).verdict,
          TransitionVerdict.rejected);
    }
    expect(TransitionVerifier.parseMeasurements('').verdict,
        TransitionVerdict.unavailable);
    expect(
        TransitionVerifier.parseMeasurements(
                'Number of samples: 1200\nPeak: -8 dBFS',
                expectedSamples: 192000)
            .verdict,
        TransitionVerdict.rejected);
  });
  test('EQ graph is bounded and has no hidden limiter', () {
    final g = TransitionVerifier.graph(p, eq: true);
    expect(g, contains('asendcmd'));
    expect(g, contains('equalizer@mid'));
    expect(g, contains('ebur128=peak=true'));
    expect(g.length, lessThan(30000));
    expect(g, isNot(contains('limiter')));
  });
  test('missing originals explicitly fall back', () async {
    final c = await const TransitionVerifier('/missing/ffmpeg')
        .verify(File('/missing/a'), File('/missing/b'), p);
    expect(c.verdict, TransitionVerdict.unavailable);
  });
  final found =
      Process.runSync(Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
  test(
      'real stereo PCM: EQ render, clipping rejection and normalization levels',
      () async {
    final ffmpeg = '${found.stdout}'.trim().split(RegExp(r'\r?\n')).first;
    final dir = await Directory.systemTemp.createTemp('dj-verifier-');
    try {
      Future<File> tone(String name, double amplitude) async {
        final f = File('${dir.path}/$name.wav');
        final r = await Process.run(ffmpeg, [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000:duration=5',
          '-af',
          'pan=stereo|c0=c0|c1=c0,volume=${amplitude * 8}',
          '-c:a',
          'pcm_f32le',
          f.path
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return f;
      }

      final quiet = await tone('quiet', 0.1),
          loud = await tone('loud', 0.9),
          v = TransitionVerifier(ffmpeg);
      final good = await v.verify(quiet, quiet, p, eq: true);
      expect(good.verdict, TransitionVerdict.accepted, reason: good.reason);
      const plain = MixPlan(
          Duration.zero, Duration(seconds: 4), Duration.zero, 1,
          dj: true);
      final bad = await v.verify(loud, loud, plain);
      expect(bad.verdict, TransitionVerdict.rejected);
      expect(bad.truePeakDb, greaterThan(0));
      final normal = await v.verify(loud, loud, plain,
          levels: const TransitionLevels(
              outAmplitude: 0.4, inAmplitude: 0.4, matchGain: 1));
      expect(normal.verdict, TransitionVerdict.accepted, reason: normal.reason);
      expect(normal.truePeakDb, lessThan(bad.truePeakDb! - 7));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: found.exitCode != 0 ? 'FFmpeg not installed in PATH' : false);
}
