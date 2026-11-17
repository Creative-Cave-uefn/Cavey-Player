# Cavey DevKit launcher. The legacy PowerShell TUI was removed.
# Interactive UI is React + claude-code-kit. Build engine runs separately.
$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch {}
$repoRoot = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $PSScriptRoot 'cavey-devkit-engine.ps1'
$appDir = Join-Path $PSScriptRoot 'devkit'
$package = Join-Path $appDir 'package.json'
$tsx = Join-Path $appDir 'node_modules\tsx\dist\cli.mjs'
$entry = Join-Path $appDir 'src\main.tsx'
$stamp = Join-Path $appDir '.dependency-stamp'
$workspace = $repoRoot
$config = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CaveyDevKit\config.json' } else { Join-Path $HOME '.cavey-devkit\config.json' }
if (Test-Path -LiteralPath $config) {
    try {
        $saved = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).projectRoot
        if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) {
            $workspace = $saved
        }
    } catch {}
}
if ($args.Count -gt 0) {
    $cmd = [string]$args[0]
    if ($cmd.TrimStart('/').ToLowerInvariant() -eq 'terminal') {
        Set-Location -LiteralPath $workspace
        & powershell.exe -NoLogo -NoProfile -NoExit
        exit $LASTEXITCODE
    }
    if (-not (Test-Path -LiteralPath $engine)) { throw "Не найден движок DevKit: $engine" }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $engine @args
    exit $LASTEXITCODE
}
if (-not (Test-Path -LiteralPath $package) -or -not (Test-Path -LiteralPath $entry)) {
    throw "Отсутствует React DevKit: $appDir"
}
$resolver = Join-Path $PSScriptRoot 'resolve-devkit-node.ps1'
if (-not (Test-Path -LiteralPath $resolver)) { throw "Не найден установщик Node.js: $resolver" }
$nodePaths = @(& $resolver)
$nodePath = if ($nodePaths.Count -gt 0) { [string]$nodePaths[-1] } else { '' }
if (-not $nodePath -or -not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    throw 'Node.js 22+ недоступен: установка не завершилась.'
}
$nodeDirectory = Split-Path -Parent $nodePath
$npmCli = Join-Path $nodeDirectory 'node_modules\npm\bin\npm-cli.js'
# A globally installed Node can be placed next to npm.cmd, or npm can be elsewhere.
if (-not (Test-Path -LiteralPath $npmCli)) {
    $npmCmd = Get-Command 'npm.cmd' -ErrorAction SilentlyContinue
    if ($npmCmd) {
        $npmCli = Join-Path (Split-Path -Parent $npmCmd.Source) 'node_modules\npm\bin\npm-cli.js'
    }
}
if (-not (Test-Path -LiteralPath $npmCli)) {
    throw 'Не найден npm. Переустановите Node.js с npm или удалите повреждённую локальную копию Node.'
}
$packageHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
$installedHash = if (Test-Path -LiteralPath $stamp) { (Get-Content -LiteralPath $stamp -Raw).Trim() } else { '' }
$previousPath = $env:PATH
$env:PATH = "$nodeDirectory;$previousPath"
try {
    if (-not (Test-Path -LiteralPath $tsx) -or $installedHash -ne $packageHash) {
        Write-Host 'Установка зависимостей нового Cavey DevKit (первый запуск)...' -ForegroundColor Cyan
        & $nodePath $npmCli install --prefix $appDir --no-audit --no-fund
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tsx)) {
            throw 'Не удалось установить React DevKit. Проверьте сеть и повторите запуск.'
        }
        Set-Content -LiteralPath $stamp -Value $packageHash -Encoding Ascii
    }
    Push-Location $workspace
    try {
        & $nodePath $tsx $entry
        if ($LASTEXITCODE -ne 0) { throw "DevKit завершился с кодом $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
} finally {
    $env:PATH = $previousPath
}
