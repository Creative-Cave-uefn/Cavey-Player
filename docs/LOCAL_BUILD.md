# Локальная тестовая сборка Cavey (без GitHub Actions)

Скрипт `tools/local-test-build.ps1` делает на вашем компьютере то же, что CI: проверяет код, гоняет тесты, собирает приложение, упаковывает установщик и выкладывает тестовый пререлиз `test-<ветка>-v…` в `cave-player-releases`. Дальше сборка ставится из плеера: Настройки → Обновления → Тестовые сборки.

Всё ниже делается один раз. Потом сборка запускается одной командой.

Команды вводятся в **PowerShell**: меню «Пуск» → набрать `PowerShell` → открыть. После установки программ окно PowerShell нужно закрыть и открыть заново, иначе новые программы не найдутся.

## 1. Режим разработчика

Нужен Flutter, чтобы собирать плагины. Откройте окно настроек командой:

```
start ms-settings:developers
```

Включите «Режим разработчика» («Developer Mode»).

## 2. Visual Studio Build Tools (компилятор C++)

Самая тяжёлая часть: скачается около 6–8 ГБ, установка 10–20 минут.

```
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

Если Visual Studio 2022 у вас уже стоит, откройте «Visual Studio Installer» → «Изменить» и убедитесь, что отмечен набор **«Разработка классических приложений на C++»**.

## 3. Git, GitHub CLI, Inno Setup и Flutter

```
winget install --id Git.Git -e
winget install --id GitHub.cli -e
winget install --id JRSoftware.InnoSetup -e
```

Закройте и откройте PowerShell заново. Затем Flutter нужной версии 3.27.4 (другие версии не подойдут: на новых плеер вылетает):

```
git clone https://github.com/flutter/flutter.git -b 3.27.4 C:\src\flutter
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\src\flutter\bin', 'User')
```

Снова закройте и откройте PowerShell, проверьте:

```
flutter --version
flutter doctor -v
```

Первая команда должна показать `Flutter 3.27.4`. В `flutter doctor` важны строки про «Windows Version» и «Visual Studio» (галочки). Android, Chrome и прочее не нужны, красные крестики там можно игнорировать.

## 4. Вход в GitHub

```
gh auth login
```

Отвечайте: `GitHub.com` → `HTTPS` → `Yes` (авторизовать git) → `Login with a web browser`. Откроется браузер, введите показанный код. Войти надо под аккаунтом, у которого есть доступ к `Cavey-Player` и запись в `cave-player-releases`.

## 5. Скачать код

```
gh repo clone Creative-Cave-uefn/Cavey-Player C:\src\cavey
cd C:\src\cavey
git checkout feature/beta-9
```

Путь `C:\src\cavey` лучше не менять на длинный: в Windows бывают проблемы с очень длинными путями.

## 6. Ключи Google (по желанию)

Если ключи (`GOOGLE_CLIENT_ID` и `GOOGLE_CLIENT_SECRET`) у вас есть, задайте их один раз, чтобы вход в Google работал сразу:

```
[Environment]::SetEnvironmentVariable('GOOGLE_CLIENT_ID', 'вставьте-сюда', 'User')
[Environment]::SetEnvironmentVariable('GOOGLE_CLIENT_SECRET', 'вставьте-сюда', 'User')
```

Откройте PowerShell заново. Взять их можно в Google Cloud Console: APIs & Services → Credentials. Если пропустить этот шаг, приложение при первом запуске само попросит ввести ключи.

## 7. Запуск сборки

```
cd C:\src\cavey
powershell -ExecutionPolicy Bypass -File tools\local-test-build.ps1
```

Что будет происходить: проверка программ → проверка кода → тесты → сборка (первый раз 5–15 минут) → установщик → вопрос «Продолжить? (y/n)» → публикация. Нажмите `y`.

Режимы:

- без публикации, только собрать и посмотреть у себя: добавьте `-NoPublish`; готовый `CavePlayer-Setup.exe` будет в `C:\src\cavey\dist`;
- пропустить проверки и тесты (быстрее): добавьте `-SkipChecks`.

## 8. Если что-то пошло не так

Весь вывод сохраняется в файл `C:\src\cavey\build-log.txt`. Пришлите мне его целиком или последние 50 строк, и я поправлю код. Первая сборка этой ветки как раз может показать ошибки компиляции: это нормально, их ни разу не проверяли компилятором.

Частые случаи:

- «Developer Mode» / symlink в логе — не сделан шаг 1;
- «Unable to find suitable Visual Studio toolchain» — не поставлен набор C++ из шага 2;
- команда `flutter` не найдена — не открыли PowerShell заново после установки;
- не получилось выложить релиз — скрипт покажет, как загрузить `dist\CavePlayer-Setup.exe` и `dist\CavePlayer-portable.zip` вручную на странице релизов.

## Как обновлять после правок

Я пушу исправления в ветку, а вы выполняете:

```
cd C:\src\cavey
git pull
powershell -ExecutionPolicy Bypass -File tools\local-test-build.ps1
```

Повторные сборки быстрее, потому что кэш остаётся.

## Что делает скрипт (если интересно)

- версия `0.2.<номер последней сборки в GitHub>.<минуты>`: она новее версий из `main`, но старше следующих сборок из CI;
- переменные репозитория (`CAVE_LIBRARY_ID`, `DISCORD_CLIENT_ID`, `SHARE_URL`) читает через `gh` сам, секретов не трогает;
- `Cavey-Downloader.exe` берёт из установленной у вас Cavey (или из последнего релиза);
- перед публикацией удаляет прежние тестовые сборки этой же ветки, как CI.
