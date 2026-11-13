# Cavey Android: on-device YouTube audio MVP

Branch: feat/android-youtube-ondevice-20261113 (based on android/app).

## Functionality and limitations

In Android choose **Скачано** and the link-plus icon at top right.
Paste an HTTPS YouTube link to a single watch, live, shorts or youtu.be video.
Download the M4A audio stream directly on the phone. No PC, server or
Cavey-Downloader.exe required. Optionally upload the downloaded M4A to a
selected writable Google Drive music folder.

The local file lives in the app's private external Music/YouTube directory.
Android file managers may hide Android/data on recent OS versions.
Audio added to Google Drive appears in the shared library; local-only
downloads are not yet indexed as separate playable library tracks.

First release intentionally supports one video at a time, M4A only,
no playlist extraction, no in-app free-text YouTube search, no streaming
from the downloaded local file in the main player, no Android foreground
download service and no robust continuation if Android kills the process.
Some videos may not provide M4A or may return 403.

Download only material for which you have the necessary permission.
The downloader does not handle DRM or private account cookies.

## Dependency license review

Android dependency: dev.ffmpegkit-maintained:yt-dlp-android:2.0.2
https://github.com/ffmpegkit-maintained/yt-dlp-android

Project states MIT (yt-dlp Unlicense, Chaquopy MIT, CPython PSF).
See THIRD-PARTY-NOTICES.txt upstream. Check the actual packaged AAR,
transitive licenses and attribution before public distribution.
Do not substitute yausername/youtubedl-android (GPLv3), or the Flutter
plugin ytdlp_flutter which wraps that GPL dependency.

## Local build — Windows PowerShell 5.1

From the project folder:

    git fetch origin
    git switch feat/android-youtube-ondevice-20261113

    powershell -NoProfile -ExecutionPolicy Bypass -File tool/setup_android_windows.ps1
    flutter analyze --no-fatal-infos --no-fatal-warnings lib/mobile_main.dart lib/mobile
    flutter test test/mobile_youtube_url_test.dart
    flutter test

For a release build use the same keystore/certificate as your installed
Android version. Set environment variables locally (never send passwords
or OAuth secrets to a chat or commit them):

    $env:CAVEY_KEYSTORE = 'C:\private\cavey-release.jks'
    $env:CAVEY_KEYSTORE_PASSWORD = 'your-local-password'
    $env:CAVEY_KEY_PASSWORD = $env:CAVEY_KEYSTORE_PASSWORD
    $env:CAVEY_KEY_ALIAS = 'cavey'
    $env:GOOGLE_WEB_CLIENT_ID = 'your-web-oauth-client-id'
    $env:GOOGLE_ANDROID_CLIENT_ID = 'your-android-oauth-client-id'

Run the local setup command again after setting GOOGLE_ANDROID_CLIENT_ID
so the Android OAuth redirect scheme is included. Then choose a version
and versionCode HIGHER than the installed APK:

    $version = '1.0.220'
    $buildNumber = '220'
    flutter build apk --release --target lib/mobile_main.dart --split-per-abi --build-name $version --build-number $buildNumber --dart-define=GOOGLE_WEB_CLIENT_ID=$env:GOOGLE_WEB_CLIENT_ID --dart-define=GOOGLE_ANDROID_CLIENT_ID=$env:GOOGLE_ANDROID_CLIENT_ID --dart-define=APP_VERSION=$version --dart-define=BUILD_CHANNEL=android/app

For a normal ARM64 phone, APK path:
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

    adb devices
    adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

If installation reports INSTALL_FAILED_UPDATE_INCOMPATIBLE, check
signing certificate first. Do not uninstall before backing up local data.

Publish via GitHub CLI after verifying the APK on device:

    gh auth login
    Copy-Item build/app/outputs/flutter-apk/app-arm64-v8a-release.apk CaveyPlayer.apk
    gh release create "android-v$version" CaveyPlayer.apk --repo Creative-Cave-uefn/cave-player-releases --prerelease --title "Android $version" --notes "YouTube audio MVP for Android"

This uploads a local APK without GitHub Actions. The existing Android
updater expects an android-v* release with CaveyPlayer.apk.

This branch does NOT disable CI elsewhere until the user explicitly
chooses to stop automated Android builds.

## Manual tests before merge

- Authorized downloadable YouTube M4A test video succeeds, progress moves.
- File is nonempty, playable as M4A, stored under Music/YouTube.
- Two consecutive downloads do not overwrite each other.
- Disallowed http, malicious host and playlist-only links are rejected.
- Local only works without Drive; with Drive writes result appears in library.
- Failed Drive upload preserves the local audio file and reports a failure.
- YouTube 403, no M4A, offline state, app backgrounding do not crash UI.
- Existing media playback, login, cache and shared library still work.
- Confirm no Windows downloader or DJ changes were introduced.

Flutter, Gradle and real-device download were not executed through the
GitHub connector. This is experimental code awaiting local validation.
