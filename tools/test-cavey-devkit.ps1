# Validate DevKit launcher, backend and shortcut installer. PowerShell 5.1.
[CmdletBinding()]
param([switch]$SkipNpm)
$ErrorActionPreference = 'Stop'
$files = @(
    'cavey-devkit.ps1',
    'cavey-devkit-engine.ps1',
    'resolve-devkit-node.ps1',
    'install-devkit-shortcuts.ps1',
    'test-cavey-devkit.ps1'
)
foreach ($filename in $files) {
    $path = Join-Path $PSScriptRoot $filename
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $filename" }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
        throw "Missing UTF-8 BOM in $filename. Windows PowerShell 5.1 will misread Unicode source text."
    }
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

# Catch PowerShell's case-insensitive command lookup recursion: a Git helper may
# shadow git.exe, and a Gh helper may shadow gh.exe. This test invokes both
# wrappers through the engine without network access or authentication.
$nativeOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-native 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $nativeOutput -notmatch 'PASS native Git executable: git version') {
    throw "Native CLI smoke test failed (check Git/Gh recursion): $nativeOutput"
}
Write-Host 'PASS native Git/Gh command resolution' -ForegroundColor Green
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
