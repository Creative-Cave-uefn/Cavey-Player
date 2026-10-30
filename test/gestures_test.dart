import 'dart:ui';

import 'package:cave_player/core/window_style.dart';
import 'package:cave_player/ui/mouse_gesture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Жесты мыши с правой кнопкой', () {
    test('Движение меньше порога ничего не делает', () {
      final g = MouseGesture()..start(const Offset(100, 100));
      expect(g.move(const Offset(130, 110)), isNull);
    });

    test('Четыре стороны', () {
      expect((MouseGesture()..start(Offset.zero)).move(const Offset(-70, 5)), GestureDir.left);
      expect((MouseGesture()..start(Offset.zero)).move(const Offset(70, -5)), GestureDir.right);
      expect((MouseGesture()..start(Offset.zero)).move(const Offset(5, -70)), GestureDir.up);
      expect((MouseGesture()..start(Offset.zero)).move(const Offset(-5, 70)), GestureDir.down);
    });

    test('После срабатывания отсчёт идёт от новой точки: вести дальше можно повторять', () {
      final g = MouseGesture()..start(Offset.zero);
      expect(g.move(const Offset(0, 65)), GestureDir.down);
      expect(g.move(const Offset(0, 90)), isNull);
      expect(g.move(const Offset(0, 130)), GestureDir.down);
    });

    test('Без нажатия или после отпускания жест не работает', () {
      final g = MouseGesture();
      expect(g.move(const Offset(500, 0)), isNull);
      g.start(Offset.zero);
      g.end();
      expect(g.active, isFalse);
      expect(g.move(const Offset(500, 0)), isNull);
    });
  });

  group('Автопрокрутка', () {
    test('Рядом с якорем стоит на месте, дальше быстрее, вниз и вверх симметрично, есть потолок', () {
      expect(autoScrollSpeed(0), 0);
      expect(autoScrollSpeed(10), 0);
      expect(autoScrollSpeed(60), greaterThan(0));
      expect(autoScrollSpeed(120), greaterThan(autoScrollSpeed(60)));
      expect(autoScrollSpeed(-80), -autoScrollSpeed(80));
      expect(autoScrollSpeed(100000), 3000);
    });
  });

  group('Полоса заголовка окна', () {
    test('Windows 11 — сборка 22000 и выше', () {
      expect(canTintCaption(22000), isTrue);
      expect(canTintCaption(22631), isTrue);
      expect(canTintCaption(19045), isFalse);
      expect(canTintCaption(0), isFalse);
    });

    test('Цвет переводится в формат Windows (синий, зелёный, красный)', () {
      expect(colorRef(const Color(0xFF12162A)), 0x2A1612);
      expect(colorRef(const Color(0xFFFF0000)), 0x0000FF);
    });
  });
}
