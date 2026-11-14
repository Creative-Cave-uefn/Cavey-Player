# Build a self-contained optional CPU analyzer; no Python on the listening PC.
param([string]$Destination = '', [string]$PythonVersion = '-3.11')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path $root 'build\intelligence'
if (-not $Destination) { $Destination = Join-Path $work 'package' }
$venv = Join-Path $work 'venv'
$python = Join-Path $venv 'Scripts\python.exe'
New-Item -ItemType Directory -Force $work | Out-Null
function Checked([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @arguments
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { throw "Audio Intelligence: $exe failed ($code)" }
}
if (-not (Test-Path $python)) {
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw 'Install Python 3.11: winget install --id Python.Python.3.11 -e; then open a new PowerShell window.'
    }
    Checked 'py' @($PythonVersion, '-m', 'venv', $venv)
}
Checked $python @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', (Join-Path $PSScriptRoot 'requirements.txt'))
$model = Join-Path $work 'yamnet.tflite'
$expected = '4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path $model)) {
    Invoke-WebRequest -UseBasicParsing 'https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite' -OutFile $model
}
if ((Get-FileHash $model -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'YAMNet SHA-256 mismatch. Package not created.' }
Checked $python @('-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--name', 'cave-intelligence',
    '--distpath', (Join-Path $work 'dist'), '--workpath', (Join-Path $work 'pyinstaller'), '--specpath', $work,
    '--collect-all', 'mediapipe', '--copy-metadata', 'mediapipe', '--copy-metadata', 'numpy', (Join-Path $PSScriptRoot 'worker.py'))
New-Item -ItemType Directory -Force $Destination | Out-Null
Copy-Item (Join-Path $work 'dist\cave-intelligence\*') $Destination -Recurse -Force
Copy-Item $model (Join-Path $Destination 'yamnet.tflite') -Force
Copy-Item (Join-Path $PSScriptRoot 'THIRD_PARTY.md') $Destination -Force
Invoke-WebRequest -UseBasicParsing 'https://www.apache.org/licenses/LICENSE-2.0.txt' -OutFile (Join-Path $Destination 'YAMNET-LICENSE.txt')
$check = Join-Path $work 'model-self-test.json'
Checked (Join-Path $Destination 'cave-intelligence.exe') @('--self-test', '--model', (Join-Path $Destination 'yamnet.tflite'), '--output', $check)
$result = Get-Content -Raw $check | ConvertFrom-Json
if ($result.modelSha256 -ne $expected -or $result.scores.Count -lt 1 -or $result.durationMs -ne 1000) { throw 'Packaged model self-test failed' }
$manifest = [ordered]@{ model = 'yamnet/float32/1'; sha256 = $expected; runtime = 'mediapipe:0.10.21'; license = 'Apache-2.0'; calibratedAbsence = $false; selfTest = 'passed' }
[IO.File]::WriteAllText((Join-Path $Destination 'model-manifest.json'), ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Write-Host "Audio Intelligence ready: $Destination"
