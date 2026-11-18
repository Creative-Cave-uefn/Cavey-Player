# Validate DevKit launcher, backend and shortcut installer. PowerShell 5.1.
[CmdletBinding()]
param([switch]$SkipNpm)
$ErrorActionPreference = 'Stop'
$files = @(
    'cavey-devkit.ps1',
    'cavey-devkit-engine.ps1',
    'resolve-devkit-node.ps1',
    'install-devkit-shortcuts.ps1',
    'test-cavey-devkit.ps1',
    'local-test-build.ps1'
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

# Verify both adversarial ref-name fixtures and actual local Git refs without fetching.
$branchOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-branches 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $branchOutput -notmatch 'PASS malformed branch refs are skipped' -or
    $branchOutput -notmatch 'PASS local Git refs parsed') {
    throw "Branch parser smoke test failed: $branchOutput"
}
Write-Host 'PASS branch parser and real local Git refs' -ForegroundColor Green

# Reproduce empty arrays, build flags and publication-channel selection offline.
$selectionOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-selection 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $selectionOutput -notmatch 'PASS build arguments and release-channel guards' -or
    $selectionOutput -notmatch 'PASS explicit branch validation') {
    throw "Build selection smoke test failed: $selectionOutput"
}
Write-Host 'PASS build wizard and release selection guards' -ForegroundColor Green

# Ensure releases can be versioned even without a stable release in the CLI response.
$versionOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'PASS stable and test channel version selection') {
    throw "Release version selection smoke test failed: $versionOutput"
}
Write-Host 'PASS release base version selection' -ForegroundColor Green

# New releases must get a fresh channel; an existing channel is for --mode update.
$newChannelOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-new-channel 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $newChannelOutput -notmatch 'PASS new build channel is distinct from existing channels') {
    throw "New release channel smoke test failed: $newChannelOutput"
}
Write-Host 'PASS new release channel collision guard' -ForegroundColor Green

# Test build/run manifest and SHA-256 recovery guards without GitHub or Flutter.
$workflowOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-workflow 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $workflowOutput -notmatch 'PASS build numbering, artifact verification and corruption detection') {
    throw "Workflow smoke test failed: $workflowOutput"
}
Write-Host 'PASS build persistence and recovery guards' -ForegroundColor Green

# Retention rules, DevKit channel namespace and interrupted-upload reconciliation.
$retentionOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-retention 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $retentionOutput -notmatch 'PASS interrupted publication reconciliation') {
    throw "Retention smoke test failed: $retentionOutput"
}
Write-Host 'PASS retention and publication reconciliation' -ForegroundColor Green

$smokeOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-smoke 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $smokeOutput -notmatch 'PASS smoke test report validation') {
    throw "Smoke report test failed: $smokeOutput"
}
Write-Host 'PASS smoke test report validation' -ForegroundColor Green

$notesOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-notes 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $notesOutput -notmatch 'PASS settings merge') {
    throw "Release notes test failed: $notesOutput"
}
Write-Host 'PASS release notes, Discord message and settings' -ForegroundColor Green

# Two windows must not build or change releases at the same time.
$lockOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry selftest-lock 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $lockOutput -notmatch 'PASS build lock') {
    throw "Build lock test failed: $lockOutput"
}
Write-Host 'PASS build lock' -ForegroundColor Green
if (-not $SkipNpm) {
    Push-Location (Join-Path $PSScriptRoot 'devkit')
    try {
        & npm.cmd ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
        & npm.cmd run typecheck
        if ($LASTEXITCODE -ne 0) { throw 'DevKit typecheck failed.' }
        & npm.cmd test
        if ($LASTEXITCODE -ne 0) { throw 'DevKit tests failed.' }
    } finally { Pop-Location }
}
Write-Host 'PASS Cavey DevKit checks' -ForegroundColor Green
