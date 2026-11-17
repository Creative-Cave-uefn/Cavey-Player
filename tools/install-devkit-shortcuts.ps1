# Create Desktop and Start Menu shortcuts for the local Cavey DevKit.
# PowerShell 5.1. Run once from the checked-out Cavey-Player repository.
[CmdletBinding()]
param([switch]$DesktopOnly)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows .lnk shortcuts are only supported on Windows.' }

$repository = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $PSScriptRoot 'cavey-devkit.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "Missing: $entry" }

$config = Join-Path (Join-Path $env:LOCALAPPDATA 'CaveyDevKit') 'config.json'
$workspace = $repository
if (Test-Path -LiteralPath $config) {
    try {
        $saved = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).projectRoot
        if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) { $workspace = $saved }
    } catch {}
}
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if (-not $desktop) { throw 'Could not determine Desktop location.' }
$locations = @($desktop)
if (-not $DesktopOnly) {
    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) { $locations += $programs }
}
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { throw "Missing: Windows PowerShell: $powershell" }
$icon = Join-Path $repository 'assets\app_icon.ico'
$wsh = New-Object -ComObject WScript.Shell

foreach ($location in $locations) {
    New-Item -Path $location -ItemType Directory -Force | Out-Null
    foreach ($item in @(
        @{ name='Cavey DevKit';          args='';         description='Cavey DevKit: commands, builds and terminal' },
        @{ name='Cavey DevKit Terminal'; args=' terminal'; description='Interactive PowerShell in Cavey Player project' }
    )) {
        $path = Join-Path $location ($item.name + '.lnk')
        $shortcut = $wsh.CreateShortcut($path)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $entry + '"' + $item.args
        $shortcut.WorkingDirectory = $workspace
        $shortcut.Description = $item.description
        $shortcut.WindowStyle = 1
        if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = $icon + ',0' }
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $path)) { throw "Could not create shortcut: $path" }
        Write-Host ('Created shortcut: ' + $path) -ForegroundColor Green
    }
}
Write-Host 'Done: Cavey DevKit can be launched from the Desktop and Start menu.' -ForegroundColor Cyan
