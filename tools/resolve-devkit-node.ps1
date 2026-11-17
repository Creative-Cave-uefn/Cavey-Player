# Resolve Node.js 22+ without modifying the machine-wide installation.
# Uses locally cached Node.js or a checksum-verified official portable ZIP.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$version = '22.23.5'
$arch = switch ([string]$env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    'AMD64' { 'x64' }
    default { throw "Cavey DevKit requires 64-bit Windows (found: $env:PROCESSOR_ARCHITECTURE)." }
}
$folder = "node-v$version-win-$arch"
$filename = "$folder.zip"
$homePath = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cavey-devkit' }
$runtimeRoot = Join-Path $homePath 'CaveyDevKit\runtime'
$runtimeDir = Join-Path $runtimeRoot $folder
$localExe = Join-Path $runtimeDir 'node.exe'

function Test-Node([string]$path) {
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $text = (& $path --version 2>$null).Trim().TrimStart('v')
        return ([version]$text).Major -ge 22
    } catch { return $false }
}

# Prefer the user's current Node if it meets the requirement.
$system = Get-Command 'node.exe' -ErrorAction SilentlyContinue
if ($system -and (Test-Node $system.Source)) {
    Write-Output $system.Source
    return
}
if (Test-Node $localExe) {
    Write-Output $localExe
    return
}

Write-Host "Node.js 22+ не найден. Устанавливаю локальный Node.js $version ($arch)..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

# Ensure HTTPS downloads work on Windows PowerShell 5.1.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$baseUrl = "https://nodejs.org/dist/v$version"
$tempDir = Join-Path $runtimeRoot ("download-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $zipPath = Join-Path $tempDir $filename
    $checksumPath = Join-Path $tempDir 'SHASUMS256.txt'
    Invoke-WebRequest -Uri "$baseUrl/SHASUMS256.txt" -UseBasicParsing -OutFile $checksumPath -TimeoutSec 120
    Invoke-WebRequest -Uri "$baseUrl/$filename" -UseBasicParsing -OutFile $zipPath -TimeoutSec 240

    $checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object {
        $_ -match "^[a-fA-F0-9]{64}\s+\*?$([regex]::Escape($filename))\s*$"
    })
    if ($checksumLines.Count -ne 1) { throw "Контрольная сумма для $filename отсутствует или неоднозначна." }
    $expected = ($checksumLines[0].Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actual -ine $expected) { throw "SHA-256 не совпадает: скачанный архив Node.js повреждён." }

    Write-Host 'Проверка SHA-256 пройдена. Распаковка...' -ForegroundColor DarkCyan
    $extractPath = Join-Path $tempDir 'unpacked'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $unpacked = Join-Path $extractPath $folder
    $executable = Join-Path $unpacked 'node.exe'
    if (-not (Test-Node $executable)) { throw 'Распакованный Node.js не прошёл проверку версии.' }
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'node_modules\npm\bin\npm-cli.js') -PathType Leaf)) {
        throw 'Архив Node.js не содержит npm.'
    }

    if (Test-Path -LiteralPath $runtimeDir) {
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force
    }
    Move-Item -LiteralPath $unpacked -Destination $runtimeDir
    if (-not (Test-Node $localExe)) { throw 'Node.js установлен, но не запускается.' }
    Write-Host "Локальный Node.js $version готов. Системная версия не менялась." -ForegroundColor Green
    Write-Output $localExe
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
