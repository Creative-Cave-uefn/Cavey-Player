/// Text a tester pastes into Discord when a test build misbehaves: what the
/// build is, where it runs and the end of the log.
String problemReport({
  required String version,
  required String channel,
  required String os,
  required int errors,
  required String log,
  DateTime? now,
}) {
  final at = (now ?? DateTime.now()).toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  final lines = log.trimRight().split('\n');
  final tail = lines.skip(lines.length > 200 ? lines.length - 200 : 0).join('\n');
  return [
    '**Проблема в тестовой сборке Cavey**',
    'Версия: ${version.isEmpty ? 'сборка для разработки' : version}',
    'Канал: ${channel.isEmpty ? 'обычный' : channel}',
    'Система: $os',
    'Ошибок за этот запуск: $errors',
    'Время: $at',
    '',
    'Что случилось: <опишите здесь>',
    '',
    '```',
    tail.isEmpty ? '(журнал пуст)' : tail,
    '```',
  ].join('\n');
}
