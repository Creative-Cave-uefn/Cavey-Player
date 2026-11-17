# Cavey DevKit

**Cavey DevKit** — интерактивная локальная консоль разработки Cavey Player в духе Claude Code.
Это отдельная CLI-программа для Windows PowerShell 5.1. Она не запускает GitHub Actions и не собирает код на серверах GitHub: исходники считываются из веток GitHub, а Flutter, тесты, установщик и архив собираются **на этом компьютере**.

## Запуск

Требования: Git, GitHub CLI (`gh`), Flutter 3.27.4, Visual Studio 2022 с C++ Build Tools, Inno Setup 6. Проверьте среду по [LOCAL_BUILD.md](LOCAL_BUILD.md).

Однократная авторизация в GitHub:

```powershell
gh auth login
```

Находясь в локальном репозитории Cavey-Player, в котором присутствует файл `tools/cavey-devkit.ps1`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\cavey-devkit.ps1
```

Откроется постоянная интерактивная консоль `CAVEY / DevKit` с приглашением `❯`.
Введите `/help`, затем `/branches` или `/build`.
Команда `/agent` передаёт управление установленному Claude Code CLI, если он есть; собственный API-ключ нейросети DevKit не требует.

## Ветки и сборки

```text
/branches
/build
/build --branch latest --mode new --yes
/build --branch claude/dj-v2-review-fixes --mode update --channel claude/dj-v2-review-fixes
/build --branch feat/audio-intelligence-20261111 --local --yes
/releases
/clean --dry-run
/clean
/history
/logs
/run
/doctor
/status
```

Без интерактивного интерфейса команды также доступны из PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\cavey-devkit.ps1 branches
powershell -NoProfile -ExecutionPolicy Bypass -File tools\cavey-devkit.ps1 build --branch latest --mode new --yes
powershell -NoProfile -ExecutionPolicy Bypass -File tools\cavey-devkit.ps1 clean --dry-run
```

- **Свежесть ветки** определяется по дате последнего коммита GitHub после `git fetch origin --prune`; `latest` исключает `main`, `beta` и ветку разработки DevKit. DevKit показывает SHA коммита.
- **Безопасное исходное состояние:** временный каталог создаётся через `git worktree add --detach` на точном SHA `origin/<ветка>`. Основная рабочая ветка, незакоммиченные файлы и существующая инсталляция Cavey не перезаписываются.
- **Локальная сборка:** вызывается существующий `tools/local-test-build.ps1` с параметрами `-NoPublish -ProjectRoot <worktree> -SourceBranch <ветка> -BuildChannel <канал>`. Программа ждёт проверки Flutter, сборки и упаковки двух артефактов, вычисляет SHA-256 и сохраняет их отдельно.
- **Новая сборка (`new`):** получает отдельный канал `devkit/<исходная-ветка>/<дата>`, который отображается в списке тестовых сборок. Изолирован от существующих линий обновлений.
- **Обновить (`update`):** выбирает уже опубликованный тестовый канал (при этом исходную ветку можно выбрать отдельно), собирает новую версию и публикует её в тот же канал. Старые релизы канала удаляются только **после успешного опубликования нового**.
- **`--local`:** собирает без публикации. Результат остаётся на компьютере. Для публикации используются `gh release create` и права GitHub CLI, без GitHub Actions.
- **История:** локально в `%LOCALAPPDATA%\CaveyDevKit\history.jsonl`, сборки — в `%LOCALAPPDATA%\CaveyDevKit\builds`; сохранены исходная ветка, SHA, канал, версия и статус. Токены не сохраняются DevKit.

Команда `--yes` разрешает подтверждение для скриптов; в интерактивном режиме публикация и удаление спрашивают разрешение. Для полного тестирования оставьте включёнными `flutter analyze` и `flutter test`; `--skip-checks` отключает их сознательно.

## Очистка тестовых сборок

```text
/clean --dry-run
/clean --keep 2
/clean --channel claude/dj-v2-review-fixes
```

По умолчанию остаётся **одна самая новая сборка на каждый тестовый канал**. Удаляются только GitHub prerelease с тегом вида `test-…-v…`. Прежде чем удалить каждый тег, DevKit отдельно проверяет, что это именно prerelease. Стабильные `v…`, беты `beta-v…`, Android и iOS релизы не затрагиваются. Полной очистки всех релизов нет.

В самой Cavey: **Настройки → Отладка → Тестовые сборки** — кнопка **Очистить старые** и значок удаления рядом с конкретной сборкой. Удаление требует установленного `gh` и доступа пользователя к GitHub через `gh auth login`; остальным пользователям это право не предоставляется. При массовой очистке защищаются последняя версия каждого канала и установленная тестовая версия.

## Ограничения

- На данном этапе DevKit собирает **Windows**, потому что использует уже готовую и проверяемую систему сборки проекта. Android и iOS потребуют отдельных локальных профилей и инструментов.
- Работа со списком веток, GitHub Releases и авторизацией требует интернет; локальный запуск ранее собранного плеера и просмотр логов доступны без него.
- DevKit не изменяет и не отправляет исходники, не сливает ветки в `main`, не создаёт GitHub Actions workflow run.
- Сборка содержит выбранный Git-коммит плюс имеющиеся внешние зависимости, подгружаемые штатным локальным скриптом. Проверяйте доступность Cavey-Downloader перед публикацией.
- При неудачной публикации предыдущий тестовый релиз сохраняется. Итоговый статус не считается опубликованным при ошибке `gh`.
