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
$lockFile = Join-Path $appDir 'package-lock.json'
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
    if (-not (Test-Path -LiteralPath $engine)) { throw "DevKit engine not found: $engine" }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $engine @args
    exit $LASTEXITCODE
}
if (-not (Test-Path -LiteralPath $package) -or -not (Test-Path -LiteralPath $entry)) {
    throw "React DevKit is missing: $appDir"
}
$resolver = Join-Path $PSScriptRoot 'resolve-devkit-node.ps1'
if (-not (Test-Path -LiteralPath $resolver)) { throw "Node.js resolver not found: $resolver" }
$nodePaths = @(& $resolver)
$nodePath = if ($nodePaths.Count -gt 0) { [string]$nodePaths[-1] } else { '' }
if (-not $nodePath -or -not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    throw 'Node.js 22+ is unavailable: installation did not complete.'
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
    throw 'npm not found. Reinstall Node.js with npm or remove the damaged local runtime.'
}
$previousPath = $env:PATH
$env:PATH = "$nodeDirectory;$previousPath"
try {
    Push-Location $workspace
    try {
        $completed = $false
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            # Recalculate dependencies after self-update: package.json or the lockfile may change.
            $stampFiles = @($package) + @(if (Test-Path -LiteralPath $lockFile) { $lockFile })
            $packageHash = (@($stampFiles | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '')
            $installedHash = if (Test-Path -LiteralPath $stamp) {
                (Get-Content -LiteralPath $stamp -Raw).Trim()
            } else { '' }
            if (-not (Test-Path -LiteralPath $tsx) -or $installedHash -ne $packageHash) {
                Write-Host 'Installing Cavey DevKit dependencies...' -ForegroundColor Cyan
                # npm ci installs exactly the committed lockfile: same packages on every machine.
                $npmCommand = if (Test-Path -LiteralPath $lockFile) { 'ci' } else { 'install' }
                & $nodePath $npmCli $npmCommand --prefix $appDir --no-audit --no-fund
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tsx)) {
                    throw 'Failed to install React DevKit. Check your internet connection.'
                }
                Set-Content -LiteralPath $stamp -Value $packageHash -Encoding Ascii
            }
            & $nodePath $tsx $entry
            $code = $LASTEXITCODE
            if ($code -eq 42) {
                Write-Host 'DevKit updated. Restarting terminal UI...' -ForegroundColor Cyan
                continue
            }
            if ($code -ne 0) { throw "DevKit exited with code $code" }
            $completed = $true
            break
        }
        if (-not $completed) { throw 'DevKit restart limit reached. Relaunch from the desktop shortcut.' }
    } finally {
        Pop-Location
    }

} finally {
    $env:PATH = $previousPath
}
