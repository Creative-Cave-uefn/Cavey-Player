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
#   -Publish        после успешных проверок опубликовать тестовую сборку и отчёт без дополнительного вопроса
#   -Downloader     путь к cave-downloader-windows-x64.exe (по умолчанию берётся из установленной Cavey)
#   -GoogleClientId / -GoogleClientSecret   ключи Google (или переменные окружения GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET).
#                   Без них сборка работает, но при первом запуске приложение попросит ввести ключи.
#   -Version        своя версия вместо автоматической

param(
    [switch]$SkipChecks,
    [switch]$NoPublish,
    [switch]$Publish,
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
function Fail([string]$text) {
    if ($script:verification) { Write-Verification }
    Write-Host ""; Write-Host "ОШИБКА: $text" -ForegroundColor Red; exit 1
}

if ($Publish -and ($NoPublish -or $Stable -or $SkipChecks)) {
    Fail '-Publish нельзя сочетать с -NoPublish, -Stable или -SkipChecks.'
}
if ($SkipChecks -and -not ($NoPublish -or $Stable)) {
    Fail 'Тестовая публикация требует проверок. Для локальной сборки без проверок используйте -SkipChecks -NoPublish.'
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$logFile = Join-Path $root 'build-log.txt'
Set-Content -Path $logFile -Value ("Сборка " + (Get-Date)) -Encoding UTF8

# Запуск внешней программы: весь вывод идёт и на экран, и в build-log.txt.
# Возвращает код завершения; ошибка в stderr (так пишет flutter) скрипт не обрывает.
function Run([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 1
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
$sourceSha = Capture 'git' @('rev-parse', 'HEAD')
$subject = Capture 'git' @('log', '-1', '--format=%s')
if ($Publish -and $dirty) { Fail 'Перед публикацией закоммитьте изменения: сборка должна соответствовать SHA коммита.' }

$slug = ($branch.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $slug) { $slug = 'branch' }

if (-not $Version) {
    # Автоматическая версия: 0.4.0.<минуты с 9.11.2026>.
    # Она новее стабильной 0.4.0 из main и старше будущей 0.4.1, поэтому после выхода 0.4.1
    # обычное автообновление заменит тестовую сборку.
    $epoch = [DateTimeOffset]::new(2026, 11, 9, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeSeconds()
    $minutes = [int](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch) / 60)
    $Version = "0.4.0.$minutes"
}
Write-Host "Ветка: $branch ($sha), версия: $Version"

# Публикуем только итоги проверок и хеши артефактов. Полный build-log.txt остаётся локально.
# Playback/прослушивание не подменяем результатами unit-тестов или успешной компиляцией.
$verification = [ordered]@{
    branch = $branch
    commit = $sourceSha
    version = $Version
    dirtyWorktree = [bool]$dirty
    flutter = ($flutterVersion -split "`n")[0].Trim()
    platform = 'Windows'
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    checks = [ordered]@{ analyze = 'not_run'; tests = 'not_run'; windowsRelease = 'not_run'; packaging = 'not_run' }
    exitCodes = [ordered]@{}
    listening = 'not_run'
    playbackRegression = 'not_run'
    downloaderIncluded = $false
    artifacts = @()
}
function Write-Verification {
    $verification['updatedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Force (Join-Path $root 'dist') | Out-Null
    $encoding = New-Object Text.UTF8Encoding($false)
    $json = $verification | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $root 'dist\verification.json'), $json, $encoding)
    $lines = @(
        '# Проверки тестовой Windows-сборки', '',
        "Ветка: $branch", "Коммит: $sourceSha", "Версия: $Version",
        "Flutter: $($verification.flutter)", "Локальные изменения: $($verification.dirtyWorktree)", '',
        '| Проверка | Результат |', '|---|---|',
        "| flutter analyze --no-fatal-infos --no-fatal-warnings | $($verification.checks.analyze) |",
        "| flutter test --reporter expanded | $($verification.checks.tests) |",
        "| flutter build windows --release | $($verification.checks.windowsRelease) |",
        "| Установщик и portable ZIP | $($verification.checks.packaging) |", '',
        'Прослушивание и проверка регрессий воспроизведения: ещё не выполнены.', '',
        "Загрузчик включён в пакет: $($verification.downloaderIncluded)", '',
        '## SHA-256 файлов', ''
    )
    foreach ($artifact in $verification.artifacts) { $lines += "- $($artifact.name): $($artifact.sha256)" }
    [IO.File]::WriteAllText((Join-Path $root 'dist\verification.md'), ($lines -join "`n"), $encoding)
}
Write-Verification

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
    $global:LASTEXITCODE = 1
    $analysis = & flutter analyze --no-fatal-infos --no-fatal-warnings 2>&1 | ForEach-Object { "$_" } | Out-String
    $analysisCode = $LASTEXITCODE
    $ErrorActionPreference = $old
    Add-Content -Path $logFile -Value $analysis
    $errors = @($analysis -split "`n" | Where-Object { $_ -match '^\s*error - ' })
    $verification.exitCodes['analyze'] = $analysisCode
    $verification.checks['analyze'] = if ($analysisCode -eq 0 -and $errors.Count -eq 0) { 'passed' } else { 'failed' }
    Write-Verification
    if ($analysisCode -ne 0 -or $errors.Count -gt 0) {
        Write-Host $analysis
        Fail "flutter analyze завершился с кодом $analysisCode; ошибок в выводе: $($errors.Count). Подробности в build-log.txt."
    }
    Write-Host 'Ошибок нет.'

    Say 'Тесты (flutter test)'
    $testCode = Run 'flutter' @('test', '--reporter', 'expanded')
    $verification.exitCodes['tests'] = $testCode
    $verification.checks['tests'] = if ($testCode -eq 0) { 'passed' } else { 'failed' }
    Write-Verification
    if ($testCode -ne 0) {
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
$buildCode = Run 'flutter' $buildArgs
$verification.exitCodes['windowsRelease'] = $buildCode
$verification.checks['windowsRelease'] = if ($buildCode -eq 0) { 'passed' } else { 'failed' }
Write-Verification
if ($buildCode -ne 0) { Fail 'Сборка не удалась. Пришлите мне файл build-log.txt — по нему видно, что не так.' }

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
    $verification.downloaderIncluded = $true
    Write-Host "Загрузчик: $dlSource"
} else {
    Warn 'Загрузчик не найден: скачивание треков в этой сборке работать не будет. Укажите путь параметром -Downloader.'
}

# ---------- 8. Установщик и portable ----------
Say 'Собираю установщик и portable-архив'
New-Item -ItemType Directory -Force 'dist' | Out-Null
Remove-Item 'dist\CavePlayer-Setup.exe', 'dist\CavePlayer-portable.zip' -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $release '*') -DestinationPath 'dist\CavePlayer-portable.zip' -Force
$packageCode = Run $iscc @("/DMyVersion=$Version", 'installer\cave_player.iss')
$verification.exitCodes['packaging'] = $packageCode
if ($packageCode -ne 0) {
    $verification.checks['packaging'] = 'failed'
    Fail 'Inno Setup не собрал установщик. Подробности в build-log.txt'
}
foreach ($file in @('dist\CavePlayer-Setup.exe', 'dist\CavePlayer-portable.zip')) {
    if (-not (Test-Path $file) -or (Get-Item $file).Length -le 0) { Fail "Не создан файл $file" }
    $verification.artifacts += [ordered]@{ name = (Split-Path -Leaf $file); sha256 = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$verification.checks['packaging'] = 'passed'
Write-Verification
Write-Host ""
Write-Host "Готово. Файлы лежат в: $(Join-Path $root 'dist')" -ForegroundColor Green

# ---------- 9. Публикация ----------
if ($NoPublish -or $Stable) {
    Write-Host 'Публикация пропущена (-NoPublish). Можно запустить dist\CavePlayer-Setup.exe прямо так.'
    exit 0
}

Say 'Публикую тестовую сборку'
if ($dirty) { Fail 'Сборка содержит незакоммиченные изменения. Перед публикацией закоммитьте их и соберите заново.' }
foreach ($result in $verification.checks.Values) {
    if ($result -ne 'passed') { Fail 'Публикация запрещена: не все проверки прошли.' }
}
$prefix = "test-$slug-v"
$tag = "$prefix$Version"
Write-Host "Будет создан пререлиз $tag в $ReleasesRepo со сборкой и отчётом проверок."
if (-not $Publish) {
    $answer = Read-Host 'Продолжить? (y/n)'
    if ($answer -notmatch '^[yYдД]') { Write-Host 'Отменено. Файлы остались в dist.'; exit 0 }
}
$notesFile = Join-Path $root 'dist\test-release-notes.md'
$notes = "Локальная тестовая сборка ветки $branch ($sha)`n$subject`n`n" + [IO.File]::ReadAllText((Join-Path $root 'dist\verification.md'))
[IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))
$title = "Тест: $branch · $Version"
& gh release create $tag 'dist\CavePlayer-Setup.exe' 'dist\CavePlayer-portable.zip' 'dist\verification.md' 'dist\verification.json' --repo $ReleasesRepo --prerelease --latest=false --title $title --notes-file $notesFile
if ($LASTEXITCODE -ne 0) {
    Warn 'Не получилось выложить автоматически. Выложите вручную: https://github.com/Creative-Cave-uefn/cave-player-releases/releases/new'
    Warn "  Tag: $tag; Title: $title; галочка «Set as a pre-release»; прикрепите установщик, ZIP и verification.md/verification.json из dist."
    exit 1
}
Write-Host "Выложено: $tag" -ForegroundColor Green
Write-Host 'В Cavey: Настройки → Обновления → Тестовые сборки.'
