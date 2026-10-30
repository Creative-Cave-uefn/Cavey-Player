import 'package:cave_player/core/tray_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Курсор проводится по середине панели с заданным шагом', () {
    final p = sweepPoints(40, 24, step: 8);
    expect(p, [(0, 12), (8, 12), (16, 12), (24, 12), (32, 12)]);
  });

  test('Пустая панель — ничего не делаем', () {
    expect(sweepPoints(0, 24), isEmpty);
    expect(sweepPoints(40, 0), isEmpty);
  });
}
