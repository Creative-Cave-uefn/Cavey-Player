# Cavey Android APK: build, verify static SHA-1 and optionally publish locally.
# Requires Windows PowerShell 5.1, Flutter 3.27.4, original release JKS.
# Nothing builds on GitHub Actions; only "gh release create" uploads an existing APK.
param(
    [string]$ExpectedSha1 = '',
    [string]$Version = '1.0.220',
    [int]$BuildNumber = 220,
    [switch]$Install,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# One-time migration stores the ORIGINAL Actions secrets in Windows DPAPI.
# Do not require the owner to re-enter passwords/Google client IDs each build.
$protectedSettings = Join-Path $env:LOCALAPPDATA 'CaveyPlayer\AndroidSigning\signing.dpapi'
if (Test-Path $protectedSettings) {
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes($protectedSettings),
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $signing = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($signing.expected_sha1 -notmatch '^[A-Fa-f0-9]{40} -or -not (Test-Path $env:CAVEY_KEYSTORE)) {
    throw 'Specify CAVEY_KEYSTORE with the ORIGINAL release JKS. Do not create a new key: it would change the signature.'
}
if ([string]::IsNullOrWhiteSpace($env:CAVEY_KEYSTORE_PASSWORD)) {
    throw 'Set the original CAVEY_KEYSTORE_PASSWORD locally before building.'
}
if ([string]::IsNullOrWhiteSpace($env:GOOGLE_WEB_CLIENT_ID)) {
    throw 'Set GOOGLE_WEB_CLIENT_ID locally to preserve Google Sign-In.'
}
if ($BuildNumber -le 0) { throw 'BuildNumber must be positive and higher than installed app versionCode.' }

$normalizeSha1 = {
    param([string]$s)
    return ($s -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}
$expected = & $normalizeSha1 $ExpectedSha1
if ($expected.Length -ne 40) { throw 'ExpectedSha1 must be the 40-hex-character SHA-1 certificate digest from the existing signed APK.' }

$setup = Join-Path $PSScriptRoot 'setup_android_windows.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
if ($LASTEXITCODE -ne 0) { throw 'Android local setup failed.' }

& flutter analyze --no-fatal-infos --no-fatal-warnings lib/mobile_main.dart lib/mobile
if ($LASTEXITCODE -ne 0) { throw 'Flutter analyze failed.' }

& flutter test test/mobile_youtube_url_test.dart
if ($LASTEXITCODE -ne 0) { throw 'YouTube URL tests failed.' }

$args = @(
    'build','apk','--release','--target','lib/mobile_main.dart',
    '--split-per-abi','--build-name',$Version,'--build-number',("$BuildNumber"),
    ('--dart-define=GOOGLE_WEB_CLIENT_ID=' + $env:GOOGLE_WEB_CLIENT_ID),
    ('--dart-define=GOOGLE_ANDROID_CLIENT_ID=' + $env:GOOGLE_ANDROID_CLIENT_ID),
    ('--dart-define=APP_VERSION=' + $Version),
    '--dart-define=BUILD_CHANNEL=android/app'
)
& flutter @args
if ($LASTEXITCODE -ne 0) { throw 'Local Android build failed.' }

$apk = Join-Path (Get-Location).Path 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
if (-not (Test-Path $apk)) { throw "Expected APK not found at $apk" }

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
$tools = Get-ChildItem (Join-Path $sdk 'build-tools') -Recurse -File -Filter 'apksigner.bat' -ErrorAction SilentlyContinue
$apksigner = $tools | Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
if ($null -eq $apksigner) { throw 'Android SDK apksigner.bat was not found.' }

$verification = & $apksigner.FullName verify --print-certs $apk 2>&1
if ($LASTEXITCODE -ne 0) { throw ('APK signature verification failed: ' + ($verification -join '; ')) }

$actual = $null
foreach ($line in $verification) {
    if ($line -match 'SHA-1 digest:\s*([0-9A-Fa-f:]+)') {
        $actual = & $normalizeSha1 $Matches[1]
        break
    }
}
if ($null -eq $actual) { throw 'Could not read APK signing SHA-1.' }
if ($actual -ne $expected) {
    throw "Signature mismatch: expected $expected, actual $actual. STOP: do not install or publish this APK."
}
Write-Host ("Stable Cavey APK signing SHA-1 verified: " + $actual) -ForegroundColor Green

if ($Install) {
    & adb install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'ADB installation failed. Do not uninstall your existing app without a backup.' }
}

if ($Publish) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install and authenticate GitHub CLI locally with gh auth login.' }
    $output = Join-Path (Get-Location).Path 'CaveyPlayer.apk'
    Copy-Item $apk $output -Force
    & gh release create ("android-v" + $Version) $output --repo Creative-Cave-uefn/cave-player-releases --prerelease --title ("Android " + $Version) --notes 'Android YouTube M4A download MVP; locally compiled and signature-verified'
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI release upload failed.' }
    Write-Host ("Uploaded locally built APK to release android-v" + $Version) -ForegroundColor Green
}
Write-Host "Local signed APK: $apk"
) {
        throw 'DPAPI signing data has an invalid original SHA-1.'
    }
    if ($ExpectedSha1 -and (($ExpectedSha1 -replace '[^0-9A-Fa-f]','').ToUpperInvariant() -ne $signing.expected_sha1.ToUpperInvariant())) {
        throw 'Supplied SHA-1 differs from the ORIGINAL JKS recovered from GitHub.'
    }
    $ExpectedSha1 = [string]$signing.expected_sha1
    $env:CAVEY_KEYSTORE = [string]$signing.keystore
    $env:CAVEY_KEYSTORE_PASSWORD = [string]$signing.keystore_password
    $env:CAVEY_KEY_PASSWORD = [string]$signing.key_password
    $env:CAVEY_KEY_ALIAS = [string]$signing.key_alias
    $env:GOOGLE_WEB_CLIENT_ID = [string]$signing.google_web_client_id
    $env:GOOGLE_ANDROID_CLIENT_ID = [string]$signing.google_android_client_id
    Write-Host 'Using original Android release key + SHA-1 from local Windows DPAPI.' -ForegroundColor Green
}
if (-not $ExpectedSha1) {
    throw 'No original SHA-1 provided. First run tool/recover_android_signing.ps1 -Mode Restore or pass -ExpectedSha1.'
}

if ([string]::IsNullOrWhiteSpace($env:CAVEY_KEYSTORE) -or -not (Test-Path $env:CAVEY_KEYSTORE)) {
    throw 'Specify CAVEY_KEYSTORE with the ORIGINAL release JKS. Do not create a new key: it would change the signature.'
}
if ([string]::IsNullOrWhiteSpace($env:CAVEY_KEYSTORE_PASSWORD)) {
    throw 'Set the original CAVEY_KEYSTORE_PASSWORD locally before building.'
}
if ([string]::IsNullOrWhiteSpace($env:GOOGLE_WEB_CLIENT_ID)) {
    throw 'Set GOOGLE_WEB_CLIENT_ID locally to preserve Google Sign-In.'
}
if ($BuildNumber -le 0) { throw 'BuildNumber must be positive and higher than installed app versionCode.' }

$normalizeSha1 = {
    param([string]$s)
    return ($s -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}
$expected = & $normalizeSha1 $ExpectedSha1
if ($expected.Length -ne 40) { throw 'ExpectedSha1 must be the 40-hex-character SHA-1 certificate digest from the existing signed APK.' }

$setup = Join-Path $PSScriptRoot 'setup_android_windows.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
if ($LASTEXITCODE -ne 0) { throw 'Android local setup failed.' }

& flutter analyze --no-fatal-infos --no-fatal-warnings lib/mobile_main.dart lib/mobile
if ($LASTEXITCODE -ne 0) { throw 'Flutter analyze failed.' }

& flutter test test/mobile_youtube_url_test.dart
if ($LASTEXITCODE -ne 0) { throw 'YouTube URL tests failed.' }

$args = @(
    'build','apk','--release','--target','lib/mobile_main.dart',
    '--split-per-abi','--build-name',$Version,'--build-number',("$BuildNumber"),
    ('--dart-define=GOOGLE_WEB_CLIENT_ID=' + $env:GOOGLE_WEB_CLIENT_ID),
    ('--dart-define=GOOGLE_ANDROID_CLIENT_ID=' + $env:GOOGLE_ANDROID_CLIENT_ID),
    ('--dart-define=APP_VERSION=' + $Version),
    '--dart-define=BUILD_CHANNEL=android/app'
)
& flutter @args
if ($LASTEXITCODE -ne 0) { throw 'Local Android build failed.' }

$apk = Join-Path (Get-Location).Path 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
if (-not (Test-Path $apk)) { throw "Expected APK not found at $apk" }

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
$tools = Get-ChildItem (Join-Path $sdk 'build-tools') -Recurse -File -Filter 'apksigner.bat' -ErrorAction SilentlyContinue
$apksigner = $tools | Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
if ($null -eq $apksigner) { throw 'Android SDK apksigner.bat was not found.' }

$verification = & $apksigner.FullName verify --print-certs $apk 2>&1
if ($LASTEXITCODE -ne 0) { throw ('APK signature verification failed: ' + ($verification -join '; ')) }

$actual = $null
foreach ($line in $verification) {
    if ($line -match 'SHA-1 digest:\s*([0-9A-Fa-f:]+)') {
        $actual = & $normalizeSha1 $Matches[1]
        break
    }
}
if ($null -eq $actual) { throw 'Could not read APK signing SHA-1.' }
if ($actual -ne $expected) {
    throw "Signature mismatch: expected $expected, actual $actual. STOP: do not install or publish this APK."
}
Write-Host ("Stable Cavey APK signing SHA-1 verified: " + $actual) -ForegroundColor Green

if ($Install) {
    & adb install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'ADB installation failed. Do not uninstall your existing app without a backup.' }
}

if ($Publish) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install and authenticate GitHub CLI locally with gh auth login.' }
    $output = Join-Path (Get-Location).Path 'CaveyPlayer.apk'
    Copy-Item $apk $output -Force
    & gh release create ("android-v" + $Version) $output --repo Creative-Cave-uefn/cave-player-releases --prerelease --title ("Android " + $Version) --notes 'Android YouTube M4A download MVP; locally compiled and signature-verified'
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI release upload failed.' }
    Write-Host ("Uploaded locally built APK to release android-v" + $Version) -ForegroundColor Green
}
Write-Host "Local signed APK: $apk"
