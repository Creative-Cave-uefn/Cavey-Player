# Публикация стабильной версии: слияние ветки в main, сборка и релиз с патч-ноутом.
#
# Запуск (в папке репозитория):
#   powershell -ExecutionPolicy Bypass -File tools\publish-release.ps1
#
# Параметры:
#   -Branch   что вливать в main (по умолчанию feature/beta-9)
#   -Version  номер версии (по умолчанию: последний стабильный релиз + 1)
#   -SkipChecks  не гонять flutter analyze и flutter test при сборке
#
# Скрипт останавливается и спрашивает перед каждым необратимым шагом: пуш в main и публикация релиза.

param(
    [string]$Branch = 'feature/beta-9',
    [string]$Version = '',
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ReleasesRepo = 'Creative-Cave-uefn/cave-player-releases'

function Say([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Fail([string]$t) { Write-Host ""; Write-Host "ОШИБКА: $t" -ForegroundColor Red; exit 1 }
function GitOk { & git @args; if ($LASTEXITCODE -ne 0) { Fail "git $($args -join ' ') завершился с ошибкой" } }
function Ask([string]$q) { (Read-Host "$q (y/n)") -match '^[yYдД]' }

Set-Location (Split-Path -Parent $PSScriptRoot)

# ---------- 1. Подготовка ----------
Say 'Проверяю репозиторий'
if (& git status --porcelain) { Fail 'В папке есть незакоммиченные изменения. Закоммитьте или уберите их и запустите снова.' }
& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'gh не авторизован. Выполните: gh auth login' }
GitOk fetch origin

# ---------- 2. Слияние ----------
Say "Вливаю $Branch в main"
GitOk checkout $Branch
GitOk pull --ff-only
GitOk checkout main
GitOk pull --ff-only
& git merge --no-ff $Branch -m "Бета 9: влита ветка $Branch"
if ($LASTEXITCODE -ne 0) {
    & git merge --abort 2>$null
    Fail 'Слияние дало конфликты, оно отменено. Пришлите вывод выше, ничего не запушено.'
}
if (-not (Test-Path 'docs\RELEASE_NOTES.txt')) { Fail 'Нет docs\RELEASE_NOTES.txt (патч-ноут).' }

# ---------- 3. Версия ----------
if (-not $Version) {
    $json = & gh release list --repo $ReleasesRepo --exclude-pre-releases --limit 30 --json tagName 2>$null | ConvertFrom-Json
    $best = $null
    foreach ($r in @($json)) {
        if ($r.tagName -match '^v(\d+)\.(\d+)\.(\d+)$') {
            $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
            if (-not $best -or $v -gt $best) { $best = $v }
        }
    }
    if (-not $best) { Fail 'Не нашёл прошлую стабильную версию. Укажите номер: -Version 0.2.500' }
    $Version = "$($best.Major).$($best.Minor).$($best.Build + 1)"
}
Write-Host "Версия: $Version"
Write-Host ""
Get-Content 'docs\RELEASE_NOTES.txt' -Encoding utf8 | Write-Host
Write-Host ""
if (-not (Ask "Запушить main и собрать релиз v$Version с этим патч-ноутом?")) {
    Write-Host 'Отменено. Слияние сделано только локально; чтобы откатить: git reset --hard origin/main'
    exit 0
}

# ---------- 4. Пуш main ----------
Say 'Пушу main'
GitOk push origin main

# ---------- 5. Сборка ----------
Say 'Собираю установщик и portable-архив (это несколько минут)'
$args2 = @('-ExecutionPolicy', 'Bypass', '-File', 'tools\local-test-build.ps1', '-NoPublish', '-Version', $Version)
if ($SkipChecks) { $args2 += '-SkipChecks' }
& powershell @args2
if ($LASTEXITCODE -ne 0) { Fail 'Сборка не удалась, релиз не создан. main уже запушен; подробности в build-log.txt' }
foreach ($f in @('dist\CavePlayer-Setup.exe', 'dist\CavePlayer-portable.zip')) {
    if (-not (Test-Path $f)) { Fail "Нет файла $f" }
}

# ---------- 6. Релиз ----------
Say "Публикую релиз v$Version"
if (-not (Ask "Создать стабильный релиз v$Version в $ReleasesRepo?")) { Write-Host 'Релиз не создан. Файлы лежат в dist.'; exit 0 }
$sha = (& git rev-parse HEAD).Trim()
& gh release create "v$Version" 'dist\CavePlayer-Setup.exe' 'dist\CavePlayer-portable.zip' `
    --repo $ReleasesRepo --title "Cavey $Version" --notes-file 'docs\RELEASE_NOTES.txt' --latest
if ($LASTEXITCODE -ne 0) {
    Fail "Релиз не создался автоматически. Создайте вручную: https://github.com/$ReleasesRepo/releases/new (tag v$Version, файлы из dist, текст из docs\RELEASE_NOTES.txt)"
}
Write-Host ""
Write-Host "Готово: v$Version ($sha) выложен." -ForegroundColor Green
