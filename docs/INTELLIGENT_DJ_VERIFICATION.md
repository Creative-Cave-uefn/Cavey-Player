# Инженерная проверка Intelligent DJ — 14 ноября 2026

Код: `9f15408c2a12d3381ec54eb4ec83bee2306738d7`, ветка `int/intelligent-dj-v2`.
База main: `5fda1fb18aa47c1b4c08f7f3aefc312df89fa7b6`. Среда: Linux x64,
Flutter 3.27.4 / Dart 3.6.2. PR остаётся draft, в main не сливался.

| Проверка | Результат |
|---|---|
| flutter analyze --no-fatal-infos --no-fatal-warnings | exit 0, No issues found |
| flutter test --reporter expanded | exit 0, 589 passed / 1 skipped |
| Причина skip | У существующего BetterLyrics live-probe не задан BETTER_LYRICS_LIVE_JSON. Это не пропуск нового DJ/FFmpeg теста. |
| Новые Dart-сценарии | 20: локальный ритм/groove, структура, временной конфликт голосов, EQ lifecycle, PCM preflight/нормализация, legacy и default-off cut |
| Python/FFmpeg A/B | 4 теста; настоящий рендер float PCM, EQ, метрики, создание слепого набора |
| Python voice worker | 3 теста; настоящий CPU inference, source time/provenance, отказ при неверном SHA |
| Упакованный worker | PyInstaller 6.11.1 / Python 3.12 Linux: сборка и self-test прошли, 1000 мс / 3 окна. Windows exe этим не проверяется. |
| PowerShell scripts | Parser PowerShell 7.4.6 Linux: 2 файла, 0 ошибок. Это синтаксическая проверка, не исполнение Windows build script. |
| Совпадение опубликованного кода | Git blob SHA всех 31 файлов кодовых коммитов совпал с проверенной рабочей копией |
| flutter build windows --release | exit 1: build windows only supported on Windows hosts; Windows-бинарник не создан |
| Windows-прослушивание / Drive, cache, streaming, Wave, queue, manual decks | Не выполнены на реальной Windows-сборке |
| Тестовый Windows-релиз | Здесь не опубликован; локальная команда с -WithAudioModels -Publish готова |

YAMNet SHA-256: `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`.
Низкий score не является калиброванным доказательством отсутствия вокала.
Синтетические тесты не оценивают качество музыкального сведения.

Команды Windows-сборки/публикации и второго прогона:
[INTELLIGENT_DJ_STAGE3.md](INTELLIGENT_DJ_STAGE3.md).
Машиночитаемый отчёт: [intelligent-dj-verification.json](intelligent-dj-verification.json).

Новые коммиты содержат [skip ci]. Workflow не изменялся и вручную не запускался.
Публикация через локальный скрипт остаётся gated на analyze/test/Windows build,
упаковку и self-test модели. Прослушивание не помечается пройденным автоматически.
