import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../automix.dart';
import '../dj_eq.dart';

enum TransitionVerdict { accepted, rejected, unavailable }

class TransitionLevels {
  final double outAmplitude, inAmplitude;
  final double? matchGain;
  const TransitionLevels(
      {this.outAmplitude = 1, this.inAmplitude = 1, this.matchGain});
  Map<String, Object?> toJson() => {
        'outAmplitude': outAmplitude,
        'inAmplitude': inAmplitude,
        'matchGain': matchGain
      };
}

class TransitionCheck {
  final TransitionVerdict verdict;
  final String reason;
  final double? truePeakDb;
  const TransitionCheck(this.verdict, this.reason, [this.truePeakDb]);
  Map<String, Object?> toJson() => {
        'verdict': verdict.name,
        'reason': reason,
        'truePeakDbtp': truePeakDb,
        'measurement': 'offline_ffmpeg_plan_not_mpv_output'
      };
}

/// Bounded preflight of cached originals; no download, hidden limiter or output
/// capture claim. Inputs start at source cues. MPV clamp makes this conservative.
class TransitionVerifier {
  final String ffmpeg;
  const TransitionVerifier(this.ffmpeg);
  Future<TransitionCheck> verify(File a, File b, MixPlan p,
      {bool eq = false,
      TransitionLevels levels = const TransitionLevels()}) async {
    if (!a.existsSync() || !b.existsSync() || !File(ffmpeg).existsSync())
      return const TransitionCheck(
          TransitionVerdict.unavailable, 'originals_not_cached');
    if (p.length.inMilliseconds < 200 ||
        p.length.inSeconds > 40 ||
        p.rate < 0.5 ||
        p.rate > 2 ||
        !p.rate.isFinite ||
        !p.inGain.isFinite ||
        !levels.outAmplitude.isFinite ||
        !levels.inAmplitude.isFinite ||
        levels.outAmplitude <= 0 ||
        levels.inAmplitude <= 0 ||
        (levels.matchGain != null &&
            (!levels.matchGain!.isFinite || levels.matchGain! <= 0)))
      return const TransitionCheck(TransitionVerdict.rejected, 'invalid_plan');
    Process? process;
    try {
      process = await Process.start(
          ffmpeg,
          [
            '-hide_banner',
            '-nostdin',
            '-v',
            'info',
            '-ss',
            '${p.start.inMilliseconds / 1000}',
            '-i',
            a.path,
            '-ss',
            '${p.inStart.inMilliseconds / 1000}',
            '-i',
            b.path,
            '-filter_complex',
            graph(p, eq: eq, levels: levels),
            '-map',
            '[out]',
            '-f',
            'null',
            '-'
          ],
          runInShell: false);
      final stdout = process.stdout.drain<void>(),
          stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(const Duration(seconds: 20));
      await stdout;
      final log = await stderr;
      if (code != 0)
        return const TransitionCheck(
            TransitionVerdict.unavailable, 'render_failed');
      return parseMeasurements(log,
          expectedSamples: p.length.inMilliseconds * 48);
    } on TimeoutException {
      process?.kill();
      return const TransitionCheck(
          TransitionVerdict.unavailable, 'render_deadline');
    } catch (_) {
      return const TransitionCheck(
          TransitionVerdict.unavailable, 'render_failed');
    }
  }

  static TransitionCheck parseMeasurements(String log, {int? expectedSamples}) {
    if (expectedSamples != null) {
      final counts = RegExp(r'Number of samples:\s*(\d+)').allMatches(log);
      if (counts.isEmpty || int.parse(counts.last[1]!) < expectedSamples * 0.95)
        return const TransitionCheck(
            TransitionVerdict.rejected, 'incomplete_render');
    }
    final matches = RegExp(r'Peak:\s*(-?\d+(?:\.\d+)?)\s*dBFS').allMatches(log);
    if (matches.isEmpty)
      return const TransitionCheck(
          TransitionVerdict.unavailable, 'missing_true_peak');
    final peak = double.tryParse(matches.last[1]!);
    if (peak == null || !peak.isFinite)
      return const TransitionCheck(TransitionVerdict.rejected, 'invalid_pcm');
    if (RegExp(r'Number of (?:NaNs|Infs):\s*[1-9]').hasMatch(log))
      return TransitionCheck(TransitionVerdict.rejected, 'nonfinite_pcm', peak);
    if (peak < -65)
      return TransitionCheck(TransitionVerdict.rejected, 'silent_render', peak);
    if (peak > -1)
      return TransitionCheck(
          TransitionVerdict.rejected, 'true_peak_headroom', peak);
    return TransitionCheck(TransitionVerdict.accepted, 'pcm_peak_passed', peak);
  }

  static String _eq(MixPlan p, bool incoming) {
    final commands = <String>[], last = <double?>[null, null, null];
    final len = p.length.inMilliseconds;
    final swap = (p.swapAt?.inMilliseconds ?? len ~/ 2) / len;
    for (var ms = 0; ms <= len; ms += 100) {
      final pair = djEqAt(ms / len, swap),
          bands = (incoming ? pair.$2 : pair.$1).bands;
      for (var k = 0; k < 3; k++) {
        final v = (bands[k] * 2).round() / 2;
        if (last[k] == v) continue;
        last[k] = v;
        commands.add('${(ms / 1000).toStringAsFixed(3)} ${[
          'bass@low',
          'equalizer@mid',
          'treble@high'
        ][k]} g $v');
      }
    }
    return ",asendcmd=c='${commands.join(';')}',bass@low=f=180:g=0,equalizer@mid=f=1400:t=o:w=2:g=0,treble@high=f=6000:g=0";
  }

  static String graph(MixPlan p,
      {bool eq = false, TransitionLevels levels = const TransitionLevels()}) {
    final len = p.length.inMilliseconds / 1000, x = 'clip(t/$len,0,1)';
    final angle =
        'if(lt($x,0.2),($x)/0.2*PI/4,if(gt($x,0.8),PI/4+(($x)-0.8)/0.2*PI/4,PI/4))';
    final outGain = p.dj ? 'cos($angle)' : 'pow(cos(($x)*PI/2),3)',
        match = levels.matchGain ?? p.inGain;
    final input = '$match+(1-$match)*($x)',
        inGain =
            p.dj ? 'sin($angle)*($input)' : 'pow(sin(($x)*PI/2)*($input),3)';
    final outFx = eq
        ? _eq(p, false)
        : p.swapAt == null
            ? ''
            : ",highpass=f=220:enable='gte(t,${p.swapAt!.inMilliseconds / 1000})'";
    final inFx = eq
        ? _eq(p, true)
        : p.swapAt == null
            ? ''
            : ",highpass=f=220:enable='lt(t,${p.swapAt!.inMilliseconds / 1000})'";
    return '[0:a]atrim=duration=$len,asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo'
        "$outFx,volume='($outGain)*${levels.outAmplitude}':eval=frame[a];"
        '[1:a]atrim=duration=${len * p.rate},asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
        "atempo=${p.rate}$inFx,volume='($inGain)*${levels.inAmplitude}':eval=frame[b];"
        '[a][b]amix=inputs=2:duration=shortest:normalize=0,astats=reset=0,ebur128=peak=true[out]';
  }
}
