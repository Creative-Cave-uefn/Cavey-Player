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
