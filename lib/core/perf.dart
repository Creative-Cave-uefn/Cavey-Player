// И1: замер нагрузки. Раз в минуту в журнал пишется, сколько кадров нарисовано, сколько времени
// занимает сборка и отрисовка кадра и не включился ли программный режим отрисовки (тогда всё ложится на процессор).
// Сравните цифры с живым фоном и с режимом «Неподвижный» в настройках.

import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/scheduler.dart';

import 'log.dart';

class PerfLog {
  static bool _started = false;
  static int _frames = 0;
  static int _buildUs = 0, _rasterUs = 0, _maxUs = 0, _slow = 0;

  static void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    Timer.periodic(const Duration(minutes: 1), (_) => _report());
  }

  static void _onTimings(List<FrameTiming> list) {
    for (final t in list) {
      _frames++;
      _buildUs += t.buildDuration.inMicroseconds;
      _rasterUs += t.rasterDuration.inMicroseconds;
      final total = t.totalSpan.inMicroseconds;
      if (total > _maxUs) _maxUs = total;
      if (total > 20000) _slow++;
    }
  }

  static void _report() {
    if (_frames == 0) {
      AppLog.info('Нагрузка: за минуту кадров не рисовалось (окно скрыто или фон неподвижен)');
      return;
    }
    AppLog.info('Нагрузка: за минуту $_frames кадров, сборка ${(_buildUs / _frames / 1000).toStringAsFixed(1)} мс, '
        'отрисовка ${(_rasterUs / _frames / 1000).toStringAsFixed(1)} мс, самый долгий ${(_maxUs / 1000).toStringAsFixed(0)} мс, '
        'дольше 20 мс: $_slow');
    _frames = 0;
    _buildUs = _rasterUs = _maxUs = _slow = 0;
  }
}
