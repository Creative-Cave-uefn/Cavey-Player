# Validate DevKit launcher, backend and shortcut installer. PowerShell 5.1.
[CmdletBinding()]
param([switch]$SkipNpm)
$ErrorActionPreference = 'Stop'
$files = @(
    'cavey-devkit.ps1',
    'cavey-devkit-engine.ps1',
    'install-devkit-shortcuts.ps1',
    'test-cavey-devkit.ps1'
)
foreach ($filename in $files) {
    $path = Join-Path $PSScriptRoot $filename
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $filename" }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Parse error in filename: $filename : $(($errors | Out-String).Trim())"
    }
    Write-Host "PASS PowerShell syntax: $filename" -ForegroundColor Green
}
if (Test-Path (Join-Path $PSScriptRoot 'cavey-devkit-tui.ps1')) {
    throw 'Old PowerShell TUI must be removed.'
}
$entry = Join-Path $PSScriptRoot 'cavey-devkit-engine.ps1'
$output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $output -notmatch '/build') {
    throw "Build engine help failed: $output"
}
Write-Host 'PASS build engine help' -ForegroundColor Green
if (-not $SkipNpm) {
    Push-Location (Join-Path $PSScriptRoot 'devkit')
    try {
        & npm.cmd run typecheck
        if ($LASTEXITCODE -ne 0) { throw 'DevKit typecheck failed.' }
        & npm.cmd test
        if ($LASTEXITCODE -ne 0) { throw 'DevKit tests failed.' }
    } finally { Pop-Location }
}
Write-Host 'PASS Cavey DevKit checks' -ForegroundColor Green
