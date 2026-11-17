import 'dart:math' as math;

// Плавный переход между треками: последние N секунд трека затихают, следующий параллельно нарастает.

/// Пора ли начинать переход. Условия:
/// • переход включён, а трек не короче 2·N секунд (иначе почти весь трек был бы «переходом»);
/// • до конца осталось N секунд или меньше, а на прошлом отсчёте было больше — граница пройдена только что;
/// • позиция сдвинулась на малую величину: это обычное воспроизведение, а не перемотка в конец.
bool crossfadeDue({
  required int seconds,
  required Duration duration,
  required Duration position,
  required Duration previous,
}) {
  if (seconds <= 0) return false;
  final n = Duration(seconds: seconds);
  if (duration < n * 2) return false;
  final left = duration - position;
  final prevLeft = duration - previous;
  if (left > n || prevLeft <= n) return false;
  final step = position - previous;
  return step >= Duration.zero && step < const Duration(seconds: 2);
}

/// Громкость уходящего и приходящего трека в долях от обычной на отметке [t] (0…1) перехода.
/// Кривая «равной мощности»: общая громкость не проваливается посередине.
(double out, double inn) fadeGains(double t) {
  final x = t.clamp(0.0, 1.0);
  return (math.cos(x * math.pi / 2), math.sin(x * math.pi / 2));
}

/// Громкость в диджейском переходе: следующий трек быстро входит (за первую половину), уходящий держится почти на полной
/// громкости и уходит во второй половине, когда басы уже поменялись местами
(double out, double inn) djGains(double t) {
  final x = t.clamp(0.0, 1.0);
  final inn = math.sin(math.min(x / 0.5, 1.0) * math.pi / 2) * (x < 0.5 ? 0.85 : 0.85 + 0.15 * (x - 0.5) / 0.5);
  final out = x < 0.5 ? 1.0 - 0.15 * (x / 0.5) : 0.85 * math.cos((x - 0.5) / 0.5 * math.pi / 2);
  return (out, inn);
}

/// A phrase blend has three stages: entry, sustained overlap, exit.
/// Returned gains are amplitudes, not mpv's cubic volume slider values.
(double out, double inn) phraseBlendGains(double t) {
  final x = t.clamp(0.0, 1.0);
  final angle = x < 0.2 ? (x / 0.2) * math.pi / 4
      : x > 0.8 ? math.pi / 4 + ((x - 0.8) / 0.2) * math.pi / 4
      : math.pi / 4;
  return (math.cos(angle), math.sin(angle));
}

/// Inverse of the mpv volume scale used by PlayerController normalization.
/// Apply once to an amplitude envelope, so entry is not cubically suppressed.
double amplitudeToMpvVolume(double amplitude) => math.pow(amplitude.clamp(0.0, 1.0), 1 / 3).toDouble();
