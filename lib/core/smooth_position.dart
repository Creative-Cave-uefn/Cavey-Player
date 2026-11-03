import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'player.dart';

/// Позиция воспроизведения для полосы перемотки без рывков.
/// Движок присылает позицию несколько раз в секунду, и полоса прыгает; здесь между такими сообщениями
/// позиция досчитывается по часам на каждом кадре, а новое значение от движка подтягивает её мягко.
/// Кадры запрашиваются только пока трек играет и у полосы есть слушатели.
class SmoothPosition extends ChangeNotifier implements ValueListenable<Duration> {
  final PlayerController player;
  final Stopwatch _clock = Stopwatch()..start();
  int _anchorMs = 0;
  int _stampMs = 0;
  bool _running = false;

  SmoothPosition(this.player) {
    _anchorMs = player.position.value.inMilliseconds;
    player.position.addListener(_onReal);
    player.addListener(_wake);
  }

  /// Одна на плеер: у всех полос общие часы
  static final Expando<SmoothPosition> _of = Expando();
  static SmoothPosition of(PlayerController p) => _of[p] ??= SmoothPosition(p);

  int get _nowMs => _clock.elapsedMilliseconds;

  /// Предсказанное сейчас значение
  int _predictedMs() {
    final real = player.position.value.inMilliseconds;
    if (!player.playing) return real;
    var v = _anchorMs + (_nowMs - _stampMs);
    final total = player.duration.inMilliseconds;
    if (total > 0 && v > total) v = total;
    return v < 0 ? 0 : v;
  }

  @override
  Duration get value => Duration(milliseconds: _predictedMs());

  void _onReal() {
    final real = player.position.value.inMilliseconds;
    final predicted = _predictedMs();
    final diff = real - predicted;
    // Небольшое расхождение гасим плавно; перемотка или новый трек — прыжок сразу
    _anchorMs = (diff.abs() < 350 && player.playing) ? predicted + (diff * 0.25).round() : real;
    _stampMs = _nowMs;
    notifyListeners();
    _wake();
  }

  void _wake() {
    if (_running || !player.playing || !hasListeners) return;
    // После паузы или перемотки отсчёт идёт от свежей позиции
    _anchorMs = player.position.value.inMilliseconds;
    _stampMs = _nowMs;
    _running = true;
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  void _tick(Duration _) {
    if (!player.playing || !hasListeners) {
      _running = false;
      return;
    }
    notifyListeners();
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _wake();
  }
}
