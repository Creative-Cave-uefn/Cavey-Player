import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/problem_report.dart';

void main() {
  test('report names the build and keeps the end of the log', () {
    final log = List.generate(300, (i) => 'line $i').join('\n');
    final report = problemReport(
      version: '0.4.0.12034', channel: 'devkit/dj', os: 'Windows 11', errors: 2, log: log,
      now: DateTime(2026, 11, 18, 15, 30),
    );
    expect(report, contains('Версия: 0.4.0.12034'));
    expect(report, contains('Канал: devkit/dj'));
    expect(report, contains('Ошибок за этот запуск: 2'));
    expect(report, contains('2026-11-18 15:30'));
    expect(report, contains('line 299'));
    expect(report, isNot(contains('line 99\n')));
  });

  test('empty log and development build are described', () {
    final report = problemReport(version: '', channel: '', os: 'Windows', errors: 0, log: '');
    expect(report, contains('сборка для разработки'));
    expect(report, contains('(журнал пуст)'));
  });
}
