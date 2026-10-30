import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app.dart' show navigatorKey;
import 'mouse_gesture.dart' show autoScrollSpeed;
import 'theme.dart';

// Плавная прокрутка колесом мыши и автопрокрутка нажатием на колесо (как в браузере).
//
// События мыши перехватываются до того, как они дойдут до виджетов: так плавность появляется у всех списков
// сразу, а не только у тех, которым подставили свой контроллер. Если прокручивать в эту сторону некуда
// (край списка), событие уходит дальше, и прокручивается внешняя страница, как и раньше.

/// Нужно подставить вместо [WidgetsFlutterBinding], чтобы получать события указателя первыми
class CaveBinding extends WidgetsFlutterBinding {
  static void ensureInitialized() {
    CaveBinding();
  }

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    var taken = false;
    if (hitTestResult != null) {
      try {
        taken = SmoothScroll.intercept(event, hitTestResult);
      } catch (_) {
        taken = false;
      }
    }
    if (!taken) super.dispatchEvent(event, hitTestResult);
  }
}

/// Плавное «доезжание» одного списка до целевой позиции: на каждом кадре проходит долю оставшегося пути.
/// Новые щелчки колеса просто сдвигают цель, поэтому быстрая прокрутка остаётся непрерывной (без рывков на каждом щелчке).
class _Glide {
  final ScrollPosition pos;
  double target;
  Ticker? _ticker;
  Duration _last = Duration.zero;
  _Glide(this.pos, this.target);

  /// За сколько секунд остаётся 1/e пути; ~0,06 с даёт общее время успокоения около 180 мс
  static const tau = 0.06;

  void start() {
    if (_ticker != null) return;
    _last = Duration.zero;
    _ticker = Ticker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 1 / 60 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    try {
      if (!pos.hasPixels) return stop();
      final left = target - pos.pixels;
      if (left.abs() < 0.5) {
        pos.jumpTo(target);
        return stop();
      }
      final k = 1 - math.exp(-dt / tau);
      pos.jumpTo((pos.pixels + left * k).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble());
    } catch (_) {
      stop();
    }
  }

  void stop() {
    _ticker?.dispose();
    _ticker = null;
    SmoothScroll._glides.remove(pos);
  }
}

class SmoothScroll {
  SmoothScroll._();

  static final _glides = <ScrollPosition, _Glide>{};
  static _Auto? _auto;

  /// true — событие обработано здесь и дальше не идёт
  static bool intercept(PointerEvent e, HitTestResult r) {
    final auto = _auto;
    if (auto != null) {
      if (e is PointerHoverEvent || e is PointerMoveEvent) auto.pointer = e.position;
      if (e is PointerDownEvent) {
        _stopAuto();
        return true; // клик, которым выходим из автопрокрутки, не должен ещё и нажимать на то, что под ним
      }
      if (e is PointerScrollEvent) _stopAuto();
      return false;
    }
    if (e is PointerScrollEvent) return _wheel(e, r);
    if (e is PointerDownEvent && e.buttons == kMiddleMouseButton) {
      _startAuto(e, r);
    }
    return false;
  }

  /// Список, к которому относится объект под курсором: сам окно прокрутки или, если курсор над пустым местом
  /// между строками, обёртки Scrollable над ним (они лежат цепочкой по одному ребёнку).
  static ScrollPosition? _viewportOf(RenderObject start) {
    RenderObject? node = start;
    for (var depth = 0; node != null && depth < 8; depth++) {
      if (node is RenderViewportBase) {
        final off = node.offset;
        return off is ScrollPosition && off.hasPixels ? off : null;
      }
      RenderObject? only;
      var count = 0;
      node.visitChildren((c) {
        only = c;
        count++;
      });
      node = count == 1 ? only : null;
    }
    return null;
  }

  static ScrollPosition? _positionAt(HitTestResult r, {Axis? only}) {
    for (final entry in r.path) {
      final t = entry.target;
      if (t is! RenderObject) continue;
      final off = _viewportOf(t);
      if (off == null) continue;
      if (only != null && off.axis != only) continue;
      return off;
    }
    return null;
  }

  static bool _wheel(PointerScrollEvent e, HitTestResult r) {
    final shift = e.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.logicalKeysPressed.any((k) =>
            k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight || k == LogicalKeyboardKey.shift);
    for (final entry in r.path) {
      final t = entry.target;
      if (t is! RenderObject) continue;
      final pos = _viewportOf(t);
      if (pos == null) continue;
      final axis = shift ? flipAxis(pos.axis) : pos.axis;
      var d = axis == Axis.horizontal ? e.scrollDelta.dx : e.scrollDelta.dy;
      if (axisDirectionIsReversed(pos.axisDirection)) d = -d;
      if (d == 0) continue;
      final glide = _glides[pos];
      final base = glide?.target ?? pos.pixels;
      final target = (base + d).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if ((target - base).abs() < 0.5) continue; // здесь дальше некуда — пусть крутится внешний список
      if (glide != null) {
        glide.target = target;
      } else {
        _glides[pos] = _Glide(pos, target)..start();
      }
      return true;
    }
    return false;
  }

  // ───── автопрокрутка по нажатию на колесо ─────

  static void _startAuto(PointerDownEvent e, HitTestResult r) {
    final pos = _positionAt(r, only: Axis.vertical);
    if (pos == null || pos.maxScrollExtent - pos.minScrollExtent < 1) return;
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final a = _Auto(pos, e.position);
    a.entry = OverlayEntry(builder: (ctx) {
      final box = overlay.context.findRenderObject();
      final local = box is RenderBox ? box.globalToLocal(a.anchor) : a.anchor;
      return Positioned(left: local.dx - 16, top: local.dy - 16, child: const IgnorePointer(child: _AnchorIcon()));
    });
    overlay.insert(a.entry!);
    a.keys = (KeyEvent k) {
      if (k is KeyDownEvent) _stopAuto();
      return false;
    };
    HardwareKeyboard.instance.addHandler(a.keys!);
    a.ticker = Ticker((elapsed) {
      final dt = (elapsed - a.last).inMicroseconds / 1e6;
      a.last = elapsed;
      a.step(dt);
    })
      ..start();
    _auto = a;
  }

  static void _stopAuto() {
    final a = _auto;
    if (a == null) return;
    _auto = null;
    a.dispose();
  }

  /// Для тестов и выхода по смене страницы
  static void stopAutoScroll() => _stopAuto();
}

class _Auto {
  final ScrollPosition pos;
  final Offset anchor;
  Offset pointer;
  OverlayEntry? entry;
  Ticker? ticker;
  bool Function(KeyEvent)? keys;
  Duration last = Duration.zero;
  _Auto(this.pos, this.anchor) : pointer = anchor;

  void step(double dt) {
    try {
      if (!pos.hasPixels || !pos.context.storageContext.mounted) {
        SmoothScroll._stopAuto();
        return;
      }
      final v = autoScrollSpeed(pointer.dy - anchor.dy);
      if (v == 0 || dt <= 0) return;
      final to = (pos.pixels + v * dt).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if (to != pos.pixels) pos.jumpTo(to);
    } catch (_) {
      SmoothScroll._stopAuto();
    }
  }

  void dispose() {
    ticker?.dispose();
    if (keys != null) HardwareKeyboard.instance.removeHandler(keys!);
    entry?.remove();
    entry?.dispose();
  }
}

class _AnchorIcon extends StatelessWidget {
  const _AnchorIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: C.panelRaised,
        shape: BoxShape.circle,
        border: Border.all(color: C.accent, width: 1.5),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
      ),
      child: const Icon(Icons.unfold_more_rounded, size: 18, color: C.accent),
    );
  }
}
