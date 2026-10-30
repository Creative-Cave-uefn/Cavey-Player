import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Куда повёл мышь человек, зажав правую кнопку
enum GestureDir { left, right, up, down }

/// Жест «зажатая правая кнопка + движение» в четыре стороны, как кнопка жестов на мышах Logitech.
/// Срабатывает, когда курсор ушёл от точки отсчёта на [threshold] пикселей; после срабатывания точка
/// отсчёта переносится на курсор, поэтому продолжая вести мышь можно повторить действие (например, прибавить громкость ещё).
class MouseGesture {
  final double threshold;
  MouseGesture({this.threshold = 60});

  Offset? _origin;

  bool get active => _origin != null;

  void start(Offset p) => _origin = p;

  void end() => _origin = null;

  /// Возвращает направление, если жест сработал, иначе null
  GestureDir? move(Offset p) {
    final o = _origin;
    if (o == null) return null;
    final dx = p.dx - o.dx, dy = p.dy - o.dy;
    if (dx.abs() < threshold && dy.abs() < threshold) return null;
    _origin = p;
    if (dx.abs() >= dy.abs()) return dx > 0 ? GestureDir.right : GestureDir.left;
    return dy > 0 ? GestureDir.down : GestureDir.up;
  }
}

/// Скорость автопрокрутки (пикселей в секунду) при смещении курсора от якоря на [dy] пикселей
double autoScrollSpeed(double dy) {
  const dead = 14.0;
  final a = dy.abs();
  if (a <= dead) return 0;
  return math.min((a - dead) * 7, 3000) * dy.sign;
}
