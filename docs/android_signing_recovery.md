# One-time migration of Android signing secrets to your Windows PC

This transfers the EXISTING Android signing material from GitHub Actions Secrets without changing its SHA-1 or OAuth registration.

NO APK is built or published by this workflow. This is one encrypted export only; later builds run on the owner's Windows computer.

## Security

- Private recovery key: generated on Windows via OpenSSL with a passphrase; NEVER sent to GitHub.
- Public certificate: sent through authenticated GitHub CLI to Actions secret CAVEY_RECOVERY_CERT_PEM. The workflow does not accept arbitrary user-submitted recipients.
- Trusted default-branch workflow: manual workflow_dispatch on main ONLY, never push or pull_request.
- Existing private signing data is read from ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, optional ANDROID_KEY_PASSWORD, ANDROID_KEY_ALIAS, GOOGLE_WEB_CLIENT_ID, and optional GOOGLE_ANDROID_CLIENT_ID.
- keytool validates the original JKS and certificate SHA-1 in an ephemeral RAM-backed /dev/shm directory on the runner.
- OpenSSL CMS envelopes the JSON using AES-256-CBC with RSA recipient encryption; the uploaded artifact contains only a .p7m encrypted envelope. Never put signing secrets into logs or artifact paths.
- Artifact retention is 1 day.
- Restore saves original JKS in the local Windows user profile, with passwords/OAuth IDs and expected SHA-1 protected using Windows DPAPI CurrentUser.
- This does not protect against intentionally malicious repository maintainers/workflows; review the workflow source before merging.

## Procedure

1. Review and merge the recovery Pull Request to the default main branch. Manual GitHub Actions workflows need to exist on the default branch.

2. On your Windows computer:

    cd $HOME\Cavey-Player
    git fetch origin
    git switch main
    git pull --ff-only origin main

    gh auth login

3. Generate an encrypted private key locally and upload its PUBLIC CERTIFICATE as a temporary GitHub Secret:

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/recover_android_signing.ps1 -Mode Init

   OpenSSL asks you to CHOOSE a strong recovery passphrase. Keep it safe.
   The private PEM file never leaves the computer.

4. Trigger the one-time encrypted export:

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/recover_android_signing.ps1 -Mode Run

   Identify the completed run ID:

    gh run list --repo Creative-Cave-uefn/Cavey-Player --workflow recover-android-signing.yml --limit 5

5. Download the encrypted artifact and decrypt locally, replacing RUN_ID:

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/recover_android_signing.ps1 -Mode Restore -RunId RUN_ID

   Enter your private recovery key passphrase from step 3.

   Files saved under %LOCALAPPDATA%\CaveyPlayer\AndroidSigning:
   cavey-release.jks (same keystore as existing Actions builds),
   signing.dpapi (password/alias/OAuth IDs/SHA-1, protected by Windows DPAPI).
   The temporary encrypted download is kept only for troubleshooting.

6. After verifying recovery, disable reuse of the export certificate:

    gh secret delete CAVEY_RECOVERY_CERT_PEM --repo Creative-Cave-uefn/Cavey-Player

   Remove the temporary recovery workflow via a small cleanup PR after transfer.

7. For the Android YouTube implementation, switch to its branch and build ENTIRELY on the Windows PC. Its local build script now automatically loads the recovered original signing data, including the expected SHA-1:

    git fetch origin
    git switch feat/android-youtube-ondevice-20261113
    powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_android_local.ps1 -Version '1.0.220' -BuildNumber 220

   Add -Install for adb install, or -Publish for uploading the locally
   compiled APK through gh. Choose a versionCode above the installed app.

## Problems

- Workflow not found: merge the reviewed recovery PR into main first.
- Missing original GitHub Secret: configure existing signing secret values,
  not a new signing key.
- Invalid JKS/alias/password: check Secrets, do not regenerate the signing key.
- Missing artifact: inspect workflow run, remember 1-day retention.
- Decrypt failed: use the exact same private PEM and passphrase as in Init.
- Signing fingerprint differs: STOP. Do not install or publish that APK.
  An SHA-1 fingerprint cannot reconstruct a private signing key.
