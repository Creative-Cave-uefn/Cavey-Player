# Локальная тестовая сборка Cavey без GitHub Actions.
# Делает то же, что .github/workflows/windows.yml: проверка кода, тесты, flutter build windows,
# установщик (Inno Setup) и portable-zip, а затем выкладывает тестовый пререлиз в cave-player-releases.
#
# Запуск (в папке с репозиторием, на нужной ветке):
#   powershell -ExecutionPolicy Bypass -File tools\local-test-build.ps1
# Подробная инструкция: docs\LOCAL_BUILD.md
#
# Параметры:
#   -SkipChecks     не гонять flutter analyze и flutter test (быстрее, но ошибки вылезут уже при сборке)
#   -Stable         стабильная сборка с main (канал пустой, как в CI); сам ничего не публикует. Его вызывает tools\publish-release.ps1
#   -NoPublish      только собрать, на GitHub ничего не выкладывать (файлы будут в папке dist)
#   -Downloader     путь к cave-downloader-windows-x64.exe (по умолчанию берётся из установленной Cavey)
#   -GoogleClientId / -GoogleClientSecret   ключи Google (или переменные окружения GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET).
#                   Без них сборка работает, но при первом запуске приложение попросит ввести ключи.
#   -Version        своя версия вместо автоматической

param(
    [switch]$SkipChecks,
    [switch]$NoPublish,
    [switch]$Stable,
    [string]$Downloader = '',
    [string]$GoogleClientId = $env:GOOGLE_CLIENT_ID,
    [string]$GoogleClientSecret = $env:GOOGLE_CLIENT_SECRET,
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
# git и gh отдают текст в UTF-8, а консоль Windows читает его как cp866: русские названия коммитов превращались в «инопланетные» символы
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch { }
$PlayerRepo = 'Creative-Cave-uefn/Cavey-Player'
$ReleasesRepo = 'Creative-Cave-uefn/cave-player-releases'

function Say([string]$text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Warn([string]$text) { Write-Host "! $text" -ForegroundColor Yellow }
function Fail([string]$text) { Write-Host ""; Write-Host "ОШИБКА: $text" -ForegroundColor Red; exit 1 }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$logFile = Join-Path $root 'build-log.txt'
Set-Content -Path $logFile -Value ("Сборка " + (Get-Date)) -Encoding UTF8

# Запуск внешней программы: весь вывод идёт и на экран, и в build-log.txt.
# Возвращает код завершения; ошибка в stderr (так пишет flutter) скрипт не обрывает.
function Run([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $logFile -Append | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return $code
}

# Вывод внешней программы в виде текста, без записи в лог (для коротких запросов)
function Capture([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $exe @arguments 2>$null | Out-String
    $ErrorActionPreference = $old
    return $out.Trim()
}

function Has([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# ---------- 1. Проверка, что всё установлено ----------
Say 'Проверяю, что нужные программы установлены'
$missing = @()
if (-not (Has 'git')) { $missing += 'Git: winget install --id Git.Git -e' }
if (-not (Has 'flutter')) { $missing += 'Flutter 3.27.4 (см. docs\LOCAL_BUILD.md, шаг 3)' }
if (-not (Has 'gh')) { $missing += 'GitHub CLI: winget install --id GitHub.cli -e' }

$iscc = $null
foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $candidate) { $iscc = $candidate; break }
}
if (-not $iscc) { $missing += 'Inno Setup: winget install --id JRSoftware.InnoSetup -e' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = ''
if (Test-Path $vswhere) {
    $vs = Capture $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
}
if (-not $vs) { $missing += 'Visual Studio 2022 (или Build Tools) с набором «Разработка классических приложений на C++» (см. docs\LOCAL_BUILD.md, шаг 2)' }

if ($missing.Count -gt 0) {
    Write-Host 'Не хватает:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host 'Установите недостающее по инструкции docs\LOCAL_BUILD.md, откройте новое окно PowerShell и запустите скрипт снова.'
    exit 1
}

$flutterVersion = Capture 'flutter' @('--version')
if ($flutterVersion -notmatch 'Flutter 3\.27\.') {
    Warn 'Проект собирается на Flutter 3.27.4. У вас другая версия, сборка может не получиться или вылетать при запуске:'
    Warn (($flutterVersion -split "`n")[0])
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    if (-not $NoPublish) { Fail 'GitHub CLI не авторизован. Выполните: gh auth login (см. docs\LOCAL_BUILD.md, шаг 4)' }
    Warn 'GitHub CLI не авторизован, но публикация не нужна — продолжаю.'
}

# ---------- 2. Ветка и версия ----------
Say 'Определяю ветку и версию'
$branch = Capture 'git' @('rev-parse', '--abbrev-ref', 'HEAD')
if (-not $branch -or $branch -eq 'HEAD') { Fail 'Не удалось определить ветку. Перейдите на нужную: git checkout feature/beta-9' }
if (($branch -eq 'main' -or $branch -eq 'beta') -and -not $Stable) {
    Fail "Ветка $branch — это обычные релизы для всех. Тестовые сборки делаются только с других веток."
}
$dirty = Capture 'git' @('status', '--porcelain', '--untracked-files=no')
if ($dirty) { Warn 'В папке есть незакоммиченные изменения — они попадут в сборку.' }
$sha = Capture 'git' @('rev-parse', '--short', 'HEAD')
$subject = Capture 'git' @('log', '-1', '--format=%s')

$slug = ($branch.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $slug) { $slug = 'branch' }

if (-not $Version) {
    # Автоматическая версия: 0.3.1.<минуты с 9.11.2026>.
    # Она новее стабильной 0.3.1 из main и старше будущей 0.3.2, поэтому после выхода 0.3.2
    # обычное автообновление заменит тестовую сборку.
    $epoch = [DateTimeOffset]::new(2026, 11, 9, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeSeconds()
    $minutes = [int](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch) / 60)
    $Version = "0.3.1.$minutes"
}
Write-Host "Ветка: $branch ($sha), версия: $Version"

# ---------- 3. Переменные репозитория (не секретные) ----------
Say 'Читаю настройки репозитория'
$vars = @{}
$json = Capture 'gh' @('api', "repos/$PlayerRepo/actions/variables", '--jq', '.variables')
if ($json) {
    try { foreach ($v in ($json | ConvertFrom-Json)) { $vars[$v.name] = $v.value } } catch { }
}
foreach ($name in @('CAVE_LIBRARY_ID', 'DISCORD_CLIENT_ID', 'SHARE_URL')) {
    if ($vars.ContainsKey($name)) { Write-Host "  $name — найдено" } else { Warn "  $name не прочитан (будет пустым)" }
}
if (-not $GoogleClientId -or -not $GoogleClientSecret) {
    Warn 'Ключи Google не заданы: при первом запуске приложение попросит их ввести (если уже вводили на этом компьютере, они сохранены).'
}

# ---------- 4. Подготовка проекта Windows (как в CI) ----------
Say 'Готовлю проект Windows'
# Папку windows/ генерирует Flutter; в git она не хранится, чтобы не мешала, исключаю её локально
$exclude = Join-Path $root '.git\info\exclude'
if ((Test-Path $exclude) -and -not (Select-String -Path $exclude -Pattern '^/windows/$' -Quiet)) { Add-Content -Path $exclude -Value '/windows/' }

if ((Run 'flutter' @('create', '--platforms=windows', '--project-name', 'cave_player', '--org', 'app.caveplayer', '.')) -ne 0) { Fail 'flutter create не отработал. Подробности в build-log.txt' }
Remove-Item 'test\widget_test.dart' -ErrorAction SilentlyContinue
Copy-Item 'assets\app_icon.ico' 'windows\runner\resources\app_icon.ico' -Force
$mainCpp = 'windows\runner\main.cpp'
$text = Get-Content $mainCpp -Raw
$text = $text.Replace('L"cave_player"', 'L"Cavey"').Replace('Win32Window::Size size(1280, 720)', 'Win32Window::Size size(1240, 800)')
[IO.File]::WriteAllText((Join-Path $root $mainCpp), $text, (New-Object Text.UTF8Encoding($false)))

if ((Run 'flutter' @('pub', 'get')) -ne 0) {
    Fail 'flutter pub get не сработал. Если в логе написано про symlink / Developer Mode — включите режим разработчика (docs\LOCAL_BUILD.md, шаг 5).'
}

# ---------- 5. Проверки ----------
if (-not $SkipChecks) {
    Say 'Проверка кода (flutter analyze)'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $analysis = & flutter analyze --no-fatal-infos --no-fatal-warnings 2>&1 | ForEach-Object { "$_" } | Out-String
    $ErrorActionPreference = $old
    Add-Content -Path $logFile -Value $analysis
    $errors = @($analysis -split "`n" | Where-Object { $_ -match '^\s*error - ' })
    if ($errors.Count -gt 0) {
        Write-Host $analysis
        Fail "flutter analyze нашёл ошибок: $($errors.Count). Пришлите мне файл build-log.txt (или текст выше) — я поправлю код."
    }
    Write-Host 'Ошибок нет.'

    Say 'Тесты (flutter test)'
    if ((Run 'flutter' @('test', '--reporter', 'expanded')) -ne 0) {
        Fail 'Тесты не прошли. Пришлите мне файл build-log.txt — я разберусь.'
    }
}

# ---------- 6. Сборка ----------
Say 'Собираю приложение (первый раз это долго, 5–15 минут)'
$defines = @(
    "--dart-define=APP_VERSION=$Version",
    "--dart-define=BUILD_CHANNEL=$(if ($Stable) { '' } else { $branch })",
    '--dart-define=BUILD_BETA=false',
    "--dart-define=CAVE_LIBRARY_ID=$($vars['CAVE_LIBRARY_ID'])",
    "--dart-define=DISCORD_CLIENT_ID=$($vars['DISCORD_CLIENT_ID'])",
    "--dart-define=SHARE_URL=$($vars['SHARE_URL'])",
    "--dart-define=GOOGLE_CLIENT_ID=$GoogleClientId",
    "--dart-define=GOOGLE_CLIENT_SECRET=$GoogleClientSecret"
)
# Flutter принимает имя сборки только из трёх чисел, поэтому четвёртое уходит в номер сборки;
# полная версия попадает в приложение через APP_VERSION
$vp = $Version.Split('.')
$buildName = ($vp | Select-Object -First 3) -join '.'
$buildNumber = if ($vp.Count -gt 3) { $vp[3] } else { '1' }
$buildArgs = @('build', 'windows', '--release', '--build-name', $buildName, '--build-number', $buildNumber) + $defines
if ((Run 'flutter' $buildArgs) -ne 0) { Fail 'Сборка не удалась. Пришлите мне файл build-log.txt — по нему видно, что не так.' }

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'cave_player.exe'))) { Fail "Не нашёл cave_player.exe в $release" }

# ---------- 7. Загрузчик музыки ----------
Say 'Добавляю Cavey-Downloader.exe'
$dlName = 'cave-downloader-windows-x64.exe'
$dlSource = $null
if ($Downloader -and (Test-Path $Downloader)) { $dlSource = $Downloader }
elseif (Test-Path "$env:LOCALAPPDATA\Programs\Cave Player\$dlName") { $dlSource = "$env:LOCALAPPDATA\Programs\Cave Player\$dlName" }
if (-not $dlSource) {
    Write-Host 'В установленной Cavey загрузчика нет, скачиваю из последнего релиза...'
    $tmp = Join-Path $env:TEMP 'cavey-dl'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmp | Out-Null
    & gh release download --repo $ReleasesRepo --pattern 'CavePlayer-portable.zip' --dir $tmp 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path "$tmp\CavePlayer-portable.zip")) {
        Expand-Archive "$tmp\CavePlayer-portable.zip" -DestinationPath "$tmp\x" -Force
        $found = Get-ChildItem "$tmp\x" -Recurse -Filter $dlName | Select-Object -First 1
        if ($found) { $dlSource = $found.FullName }
    }
}
if ($dlSource) {
    Copy-Item $dlSource (Join-Path $release $dlName) -Force
    Write-Host "Загрузчик: $dlSource"
} else {
    Warn 'Загрузчик не найден: скачивание треков в этой сборке работать не будет. Укажите путь параметром -Downloader.'
}

# ---------- 8. Установщик и portable ----------
Say 'Собираю установщик и portable-архив'
New-Item -ItemType Directory -Force 'dist' | Out-Null
Remove-Item 'dist\CavePlayer-Setup.exe', 'dist\CavePlayer-portable.zip' -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $release '*') -DestinationPath 'dist\CavePlayer-portable.zip' -Force
if ((Run $iscc @("/DMyVersion=$Version", 'installer\cave_player.iss')) -ne 0) { Fail 'Inno Setup не собрал установщик. Подробности в build-log.txt' }
foreach ($file in @('dist\CavePlayer-Setup.exe', 'dist\CavePlayer-portable.zip')) {
    if (-not (Test-Path $file) -or (Get-Item $file).Length -le 0) { Fail "Не создан файл $file" }
}
Write-Host ""
Write-Host "Готово. Файлы лежат в: $(Join-Path $root 'dist')" -ForegroundColor Green

# ---------- 9. Публикация ----------
if ($NoPublish -or $Stable) {
    Write-Host 'Публикация пропущена (-NoPublish). Можно запустить dist\CavePlayer-Setup.exe прямо так.'
    exit 0
}

Say 'Публикую тестовую сборку'
$prefix = "test-$slug-v"
$tag = "$prefix$Version"
Write-Host "Будет создан пререлиз $tag в $ReleasesRepo; прежние тестовые сборки этой ветки удалятся (как это делает CI)."
$answer = Read-Host 'Продолжить? (y/n)'
if ($answer -notmatch '^[yYдД]') { Write-Host 'Отменено. Файлы остались в dist.'; exit 0 }

$old = & gh release list --repo $ReleasesRepo --limit 200 --json tagName --jq '.[].tagName' 2>$null
foreach ($t in @($old)) {
    if ($t -and $t.StartsWith($prefix)) { & gh release delete $t --repo $ReleasesRepo --cleanup-tag --yes | Out-Null }
}
$notesFile = Join-Path $env:TEMP 'cavey-notes.txt'
[IO.File]::WriteAllText($notesFile, "Локальная тестовая сборка ветки $branch ($sha)`n$subject", (New-Object Text.UTF8Encoding($false)))
$title = "Тест: $branch · $Version"
& gh release create $tag 'dist\CavePlayer-Setup.exe' 'dist\CavePlayer-portable.zip' --repo $ReleasesRepo --prerelease --title $title --notes-file $notesFile
if ($LASTEXITCODE -ne 0) {
    Warn 'Не получилось выложить автоматически. Выложите вручную: https://github.com/Creative-Cave-uefn/cave-player-releases/releases/new'
    Warn "  Tag: $tag; Title: $title; галочка «Set as a pre-release»; прикрепите оба файла из папки dist."
    exit 1
}
Write-Host "Выложено: $tag" -ForegroundColor Green
Write-Host 'В Cavey: Настройки → Обновления → Тестовые сборки.'
