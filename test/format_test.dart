import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/ui/widgets.dart';

void main() {
  test('размер в байтах человеческим языком', () {
    expect(formatBytes(0), '0 Б');
    expect(formatBytes(900), '900 Б');
    expect(formatBytes(1536), '1,5 КБ');
    expect(formatBytes(5 * 1024 * 1024), '5,0 МБ');
    expect(formatBytes(1610612736), '1,5 ГБ');
    expect(formatBytes(250 * 1024 * 1024 * 1024), '250 ГБ');
  });
}
