# Static syntax and non-interactive command smoke tests. Run with Windows PowerShell 5.1.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$files = @(
    'cavey-devkit.ps1',
    'cavey-devkit-tui.ps1',
    'install-devkit-shortcuts.ps1',
    'test-cavey-devkit.ps1'
)
foreach ($name in $files) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Отсутствует $path" }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {
        $detail = ($errors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "PowerShell syntax error in $name : $detail"
    }
    Write-Host "PASS parse: $name" -ForegroundColor Green
}
$main = Get-Content -LiteralPath (Join-Path $root 'cavey-devkit.ps1') -Raw
if (([regex]::Matches($main,'(?m)^function Dispatch\b')).Count -ne 1) {
    throw 'Dispatch must only be defined once.'
}
if (([regex]::Matches($main,'(?m)^function Check-Repo\b')).Count -ne 1) {
    throw 'Check-Repo must only be defined once.'
}
$cli = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$output = & $cli -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'cavey-devkit.ps1') help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "CLI help command failed: $output" }
if ($output -notmatch '/terminal' -or $output -notmatch '/build') {
    throw "CLI help output is missing commands: $output"
}
Write-Host 'PASS non-interactive help and command catalog' -ForegroundColor Green
