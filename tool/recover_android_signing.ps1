# One-time recovery of the EXISTING Cavey Android release-signing key.
# Windows PowerShell 5.1; requires local GitHub CLI (gh) and OpenSSL.
#
# Init    : create an encrypted private key on THIS computer and upload only
#           its public certificate as a GitHub Actions secret.
# Run     : trigger one manual GitHub Actions job that encrypts existing secrets.
# Restore : download the encrypted artifact and decrypt it on THIS computer.
#
# GitHub Actions NEVER compiles an APK; only encrypts the existing signing secrets.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init','Run','Restore')]
    [string]$Mode,
    [long]$RunId = 0
)
$ErrorActionPreference = 'Stop'
$repo = 'Creative-Cave-uefn/Cavey-Player'
$folder = Join-Path $env:LOCALAPPDATA 'CaveyPlayer\AndroidSigning'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$privateKey = Join-Path $folder 'recovery-private.pem'
$recipientCert = Join-Path $folder 'recovery-recipient.pem'
$keystore = Join-Path $folder 'cavey-release.jks'
$secretBlob = Join-Path $folder 'signing.dpapi'
$envelope = Join-Path $folder 'CaveyAndroidSigning.p7m'

function Get-OpenSsl {
    $cmd = Get-Command 'openssl.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($path in @(
        (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe')
    )) {
        if (Test-Path $path) { return $path }
    }
    throw 'OpenSSL was not found. Install OpenSSL locally or use the OpenSSL shipped with Git for Windows.'
}
function Assert-Gh {
    if (-not (Get-Command 'gh.exe' -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI is missing. Install with: winget install --id GitHub.cli'
    }
}
function Require-Keys {
    if (-not ((Test-Path $privateKey) -and (Test-Path $recipientCert))) {
        throw 'No local recovery keys. Run: .\tool\recover_android_signing.ps1 -Mode Init'
    }
}

$openssl = Get-OpenSsl

switch ($Mode) {
    'Init' {
        Assert-Gh
        if ((Test-Path $privateKey) -xor (Test-Path $recipientCert)) {
            throw 'Only one recovery key file exists. Do not overwrite the existing private key.'
        }
        if (-not (Test-Path $privateKey)) {
            Write-Host 'Creating a new recovery certificate. Choose a strong private-key passphrase.'
            Write-Host 'The private key stays on this PC. Keep it and its passphrase until recovery is complete.'
            & $openssl req -x509 -newkey rsa:3072 -sha256 -days 14 -keyout $privateKey -out $recipientCert -subj '/CN=Cavey Android Signing Recovery'
            if ($LASTEXITCODE -ne 0) { throw 'OpenSSL private key/certificate generation failed.' }
        } else {
            Write-Host 'Existing recovery key detected. It will NOT be regenerated.'
        }
        # Only the public certificate is sent to GitHub; the private key NEVER leaves the PC.
        Get-Content -Raw -Encoding Ascii $recipientCert | & gh secret set CAVEY_RECOVERY_CERT_PEM --repo $repo
        if ($LASTEXITCODE -ne 0) { throw 'Could not upload the public certificate to GitHub Secrets.' }
        Write-Host 'Owner public certificate is configured in GitHub Secrets.' -ForegroundColor Green
        Write-Host 'After merging the recovery workflow PR to main, run:'
        Write-Host '  .\tool\recover_android_signing.ps1 -Mode Run'
    }
    'Run' {
        Assert-Gh
        Require-Keys
        & gh workflow run recover-android-signing.yml --repo $repo --ref main
        if ($LASTEXITCODE -ne 0) {
            throw 'Cannot start recovery. First merge the reviewed workflow PR to main.'
        }
        Write-Host 'One-time encrypted export requested. No APK is built on GitHub.'
        Write-Host 'Find the completed run number via:'
        Write-Host '  gh run list --repo Creative-Cave-uefn/Cavey-Player --workflow recover-android-signing.yml --limit 5'
        Write-Host 'Then run: .\tool\recover_android_signing.ps1 -Mode Restore -RunId <number>'
    }
    'Restore' {
        Assert-Gh
        Require-Keys
        if ($RunId -le 0) { throw 'Provide -RunId from gh run list.' }
        & gh run download "$RunId" --repo $repo --name cavey-android-encrypted-signing --dir $folder
        if ($LASTEXITCODE -ne 0) { throw 'Encrypted artifact not available. Check run result and one-day retention.' }
        if (-not (Test-Path $envelope)) { throw 'Encrypted CMS file was not downloaded.' }

        Write-Host 'Decrypting with the private key on your PC. Enter the passphrase chosen in Init.'
        # Python used ensure_ascii=True: the decrypted JSON is ASCII, avoiding
        # locale-sensitive decoding differences in Windows PowerShell 5.1.
        $clearLines = & $openssl cms -decrypt -binary -inform DER -in $envelope -recip $recipientCert -inkey $privateKey
        if ($LASTEXITCODE -ne 0) {
            throw 'Decryption failed. Confirm that the recipient certificate matches this private key.'
        }
        $payload = (($clearLines -join [Environment]::NewLine) | ConvertFrom-Json)
        if ($payload.format -ne 'cavey-android-signing-backup-v1' -or
            $payload.app_id -ne 'app.cavey.cave_player') {
            throw 'Unexpected encrypted-backup payload.'
        }
        if ($payload.expected_sha1 -notmatch '^[A-Fa-f0-9]{40}$') {
            throw 'Backup does not contain a valid expected certificate SHA-1.'
        }

        # Store JKS locally and save all passwords/IDs using Windows DPAPI
        # (only this Windows user profile on this PC can decrypt them).
        $jksBytes = [Convert]::FromBase64String([string]$payload.keystore_base64)
        if ($jksBytes.Length -lt 32) { throw 'Invalid keystore in encrypted backup.' }
        if (Test-Path $keystore) {
            $oldHash = (Get-FileHash -Algorithm SHA256 $keystore).Hash
            $newHash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($jksBytes)).Replace('-', '')
            if ($oldHash -ne $newHash) {
                throw 'A DIFFERENT local JKS already exists. Refusing to overwrite a signing key.'
            }
        } else {
            [IO.File]::WriteAllBytes($keystore, $jksBytes)
        }

        $config = [ordered]@{
            keystore = $keystore
            keystore_password = [string]$payload.keystore_password
            key_password = [string]$payload.key_password
            key_alias = [string]$payload.key_alias
            google_web_client_id = [string]$payload.google_web_client_id
            google_android_client_id = [string]$payload.google_android_client_id
            expected_sha1 = ([string]$payload.expected_sha1).ToUpperInvariant()
        }
        $plaintext = [Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Compress))
        Add-Type -AssemblyName System.Security
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plaintext, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($secretBlob, $protected)

        # The encrypted artifact remains available; no plaintext JSON is
        # ever written to disk. Remove the temporary recipient secret afterward.
        Write-Host 'Original release JKS saved locally; passwords and OAuth IDs saved via Windows DPAPI.' -ForegroundColor Green
        Write-Host ('Certificate SHA-1 (from original JKS): ' + $config.expected_sha1)
        Write-Host ('Signing data folder: ' + $folder)
        Write-Host 'Now revoke the temporary public recipient from GitHub:'
        Write-Host '  gh secret delete CAVEY_RECOVERY_CERT_PEM --repo Creative-Cave-uefn/Cavey-Player'
        Write-Host 'Do not lose your original key or the DPAPI-protected Windows profile.'
    }
}
