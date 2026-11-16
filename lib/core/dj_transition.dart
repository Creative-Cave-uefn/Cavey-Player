import 'dart:math' as math;
import 'dj.dart';

/// Equal-tempered semitones move seven positions around the Camelot wheel.
Camelot shiftedKey(Camelot key, int semitones) =>
    Camelot((key.n - 1 + 7 * semitones) % 12 + 1, key.minor);

/// Prefer the original recording; change pitch only for a useful harmonic gain.
int harmonicShift(Camelot outgoing, Camelot incoming) {
  final original = Camelot.compat(outgoing, incoming);
  if (original >= 0.85) return 0;
  var best = original, shift = 0;
  for (final s in [-1, 1]) {
    final fit = Camelot.compat(outgoing, shiftedKey(incoming, s)) - 0.03;
    if (fit > best + 0.1) {
      best = fit;
      shift = s;
    }
  }
  return shift;
}

double pitchScale(int semitones) => math.pow(2, semitones / 12).toDouble();

/// Same FFmpeg graph in live mpv and offline preflight. Correct duration after
/// resampling with the actual rounded rate, avoiding a cumulative tempo error.
String pitchFilter(int semitones) {
  if (semitones.abs() > 1) throw ArgumentError.value(semitones, 'semitones');
  return 'rubberband=pitch=${pitchScale(semitones)}';
}

double restoredPitchScale(int semitones, double progress) {
  final t=progress.clamp(0.0,1.0), smooth=t*t*(3-2*t);
  return math.pow(2,semitones*(1-smooth)/12).toDouble();
}

/// Compare on the common pulse lattice; half/double-time beats remain congruent.
double? djPhaseError((double,double,double,double)? grid, double ratio,
    double outgoingMs,double incomingMs,{int offsetMs=0}) {
  if(grid==null || ratio<=0 || !ratio.isFinite) return null;
  final period=math.min(grid.$2,grid.$4/ratio);
  if(!period.isFinite || period<=0) return null;
  var error=((incomingMs-grid.$3)/ratio-(outgoingMs-grid.$1)+offsetMs)%period;
  if(error>period/2) error-=period;
  return error;
}

/// The muted incoming deck must advance by the measured seek elapsed time.
double alignedIncomingPosition(double incomingMs,double errorMs,double ratio,
    double outgoingRate,double seekLatencyMs) =>
    math.max(0.0,incomingMs-errorMs*ratio+seekLatencyMs*outgoingRate*ratio);

/// Shared tempo ramp, expressed in outgoing SOURCE progress. Keeping the
/// incoming/outgoing rate ratio constant preserves half/double-time alignment
/// and the exact source windows selected by the planner.
(double outgoing, double incoming) djTempoAt(double progress, double ratio) {
  if (!ratio.isFinite || ratio < 0.8 || ratio > 1.25) return (1, 1);
  final t = (progress / 0.75).clamp(0.0, 1.0);
  final smooth = t * t * (3 - 2 * t);
  final outgoing = 1 + (1 / ratio - 1) * smooth;
  return (outgoing, outgoing * ratio);
}
