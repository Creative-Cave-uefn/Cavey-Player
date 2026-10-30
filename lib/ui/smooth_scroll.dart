import 'dart:async';
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

class _Target {
  final double target;
  final Duration at;
  const _Target(this.target, this.at);
}

class SmoothScroll {
  SmoothScroll._();

  /// Длительность одного шага колеса
  static const stepDuration = Duration(milliseconds: 180);
  static final _targets = Expando<_Target>();
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

  static ScrollPosition? _positionAt(HitTestResult r, {Axis? only}) {
    for (final entry in r.path) {
      final t = entry.target;
      if (t is! RenderViewportBase) continue;
      final off = t.offset;
      if (off is! ScrollPosition || !off.hasPixels) continue;
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
      if (t is! RenderViewportBase) continue;
      final pos = t.offset;
      if (pos is! ScrollPosition || !pos.hasPixels) continue;
      final axis = shift ? flipAxis(pos.axis) : pos.axis;
      var d = axis == Axis.horizontal ? e.scrollDelta.dx : e.scrollDelta.dy;
      if (axisDirectionIsReversed(pos.axisDirection)) d = -d;
      if (d == 0) continue;
      final prev = _targets[pos];
      final running = prev != null && (e.timeStamp - prev.at) < const Duration(milliseconds: 300);
      final base = running ? prev.target : pos.pixels;
      final target = (base + d).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if ((target - base).abs() < 0.5) continue; // здесь дальше некуда — пусть крутится внешний список
      _targets[pos] = _Target(target, e.timeStamp);
      unawaited(pos.animateTo(target, duration: stepDuration, curve: Curves.easeOutCubic));
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
        color: C.surface.withValues(alpha: 0.92),
        shape: BoxShape.circle,
        border: Border.all(color: C.accent, width: 1.5),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
      ),
      child: const Icon(Icons.unfold_more_rounded, size: 18, color: C.accent),
    );
  }
}
