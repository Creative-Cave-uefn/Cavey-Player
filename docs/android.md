# Cavey Player for Android — MVP

This is a separate Android entry point into the existing Flutter project.
The Windows app continues using lib/main.dart. Android uses lib/mobile_main.dart.

## First iteration

- Android Google Sign-In using Google Play Services and Drive scope.
- Connect to the existing shared Cave Player folder, automatically or by link.
- Recently added tracks, albums, full library, favorites, playlists and search.
- Album covers, streaming through the existing Google Drive proxy, seek and queue.
- Shares the same library.json formats and Drive API as Windows.
- Mobile reads the existing index without costly recursive auto-scans.

Not yet implemented: reliable background audio and notification controls, Android
Auto, file upload, offline downloads, Deezer downloader and multiple simultaneous
Android accounts. This is a prototype, not a verified public APK.

## Required Google OAuth configuration

1. Use the SAME Google Cloud project as your Windows Cavey application.
2. Create an Android OAuth 2.0 client:
   - Package name: app.cavey.cave_player
   - SHA-1: certificate fingerprint of the exact APK signing key.
3. Create a Web application OAuth 2.0 client in that project (if absent).
   Its Client ID (ends with apps.googleusercontent.com) is the value of
   GOOGLE_WEB_CLIENT_ID. This is NOT the desktop client ID. Do not embed
   your desktop client secret in an APK.
4. Ensure Google Drive API is enabled and Drive scope is authorized. In Testing
   mode, add each tester's Google email to the Test users list.

Local debug certificate fingerprint, after your first debug build:

    keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android -keypass android

GitHub Actions prints the SHA-1 for the APK it generated. Each ephemeral CI
runner may use a different debug signing key. For stable public distribution,
use a persistent private release signing key and register its SHA-1 in Google
Cloud. Do not commit signing keys or client secrets to GitHub.

## Build locally

Requirements: Flutter stable, Android SDK, JDK 17 or later and a device or
emulator with Google Play Services.

From the repository root:

    bash tool/setup_android.sh
    flutter build apk --debug --target lib/mobile_main.dart --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID

To run on your phone while developing:

    flutter run --target lib/mobile_main.dart --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID

The script generates the Android runner (this repository started on Windows)
and adds INTERNET permission plus localhost HTTP support because the existing
streaming proxy listens on 127.0.0.1. Google Drive traffic remains HTTPS.

## Build via GitHub Actions

1. Add Actions repository secret GOOGLE_WEB_CLIENT_ID with the Web OAuth client ID.
2. A push to feature/android-mvp triggers the workflow automatically. The
   manual Run workflow button may not appear until the workflow also exists on
   the default branch.
3. Download the private cavey-android-mvp artifact after a successful build.
4. Register the SHA-1 shown in that job output in your Android OAuth client.

The workflow does NOT publish a GitHub Release, so Android test builds do not
appear in the Windows app updater.

## Architecture

- lib/mobile/mobile_auth.dart: separate native Android authentication. Tokens
  remain managed by Google Play Services; only account metadata is saved.
- lib/mobile_main.dart: starts the existing Store, Library, Drive, Covers,
  AudioCache and Player services.
- lib/mobile/mobile_home.dart: touch-oriented screens and media controls.
- lib/core/library.dart: opt-in mobileReadOnlyIndex mode prevents battery-heavy
  scans, while preserving the default Windows behavior.

Compilation and playback have not been verified on a physical Android device
in this environment. Treat the GitHub Actions build and on-device login/playback
checks as required before distributing the APK.
