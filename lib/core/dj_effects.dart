/// Musical transition programs, executed in source time by the audio graph.
enum DjEffect { none, echoOut, filterOut, rhythmicGate }

DjEffect chooseDjEffect({required double vocalRisk, required double onsets,
    required double brightness, required bool reliableBeat}) {
  if (!reliableBeat) return DjEffect.none;
  if (vocalRisk >= 0.5) return DjEffect.echoOut;
  if (onsets >= 2.5) return DjEffect.rhythmicGate;
  return brightness > 1800 ? DjEffect.filterOut : DjEffect.echoOut;
}

/// Graph accepts a named input/output, usable both inside mpv and FFmpeg.
/// Echo is a bounded send (two taps), rather than recursive feedback.
String djEffectGraph(DjEffect effect, {required String input, required String output,
    required double start, required double length, required double beat}) {
  final end = start + length;
  final begin = end - (4 * beat).clamp(0.0, length);
  final x = 'clip((t-$begin)/${end-begin},0,1)';
  switch (effect) {
    case DjEffect.none: return '$input anull $output';
    case DjEffect.echoOut:
      final tap = (beat * 750).round().clamp(1, 2000);
      return '$input asplit=2[dry][send];'
          "[send]volume='if(gte(t,$begin),0.22,0)':eval=frame,"
          'aecho=0.8:0.8:$tap|${tap*2}:0.45|0.22[echo];'
          '[dry][echo]amix=inputs=2:normalize=0:duration=first $output';
    case DjEffect.filterOut:
      final commands = <String>[];
      for (var i=0;i<=24;i++) {
        final time=begin+(end-begin)*i/24;
        final frequency=40+3960*(i/24)*(i/24);
        commands.add('$time highpass@sweep f $frequency');
      }
      return "$input asendcmd=c='${commands.join(';')}',highpass@sweep=f=40 $output";
    case DjEffect.rhythmicGate:
      // Soft 20%-floor chopping on half beats in the final bar; no hard mute.
      return "$input volume='if(lt(t,$begin),1,0.2+0.8*pow(0.5+0.5*cos(4*PI*(t-$begin)/$beat),2))':eval=frame $output";
  }
}
