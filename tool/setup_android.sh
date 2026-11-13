#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Generate Android runner for a Flutter project that was originally Windows-only.
if [ ! -f android/app/src/main/AndroidManifest.xml ]; then
  flutter create --platforms=android --org app.cavey --project-name cave_player .
fi

python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

manifest = Path("android/app/src/main/AndroidManifest.xml")
ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID)
tree = ET.parse(manifest)
root = tree.getroot()
permissions = {p.get(f"{{{ANDROID}}}name") for p in root.findall("uses-permission")}
if "android.permission.INTERNET" not in permissions:
    root.insert(0, ET.Element("uses-permission", {f"{{{ANDROID}}}name": "android.permission.INTERNET"}))
application = root.find("application")
if application is None:
    raise RuntimeError("AndroidManifest.xml has no application")
application.set(f"{{{ANDROID}}}label", "Cavey Player")
# The shared media engine uses HTTP only for its local 127.0.0.1 stream proxy.
application.set(f"{{{ANDROID}}}usesCleartextTraffic", "true")
# Native embedded CPython libraries must remain loadable on Android.
application.set(f"{{{ANDROID}}}extractNativeLibs", "true")
application.set(f"{{{ANDROID}}}icon", "@mipmap/ic_launcher")
# Установка обновлений из приложения
for perm in ("android.permission.REQUEST_INSTALL_PACKAGES", "android.permission.WAKE_LOCK",
             "android.permission.FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
             "android.permission.POST_NOTIFICATIONS"):
    if perm not in permissions:
        root.insert(0, ET.Element("uses-permission", {f"{{{ANDROID}}}name": perm}))
if not any(p.get(f"{{{ANDROID}}}name") == "androidx.core.content.FileProvider" for p in application.findall("provider")):
    prov = ET.SubElement(application, "provider", {
        f"{{{ANDROID}}}name": "androidx.core.content.FileProvider",
        f"{{{ANDROID}}}authorities": "${applicationId}.fileprovider",
        f"{{{ANDROID}}}exported": "false",
        f"{{{ANDROID}}}grantUriPermissions": "true",
    })
    ET.SubElement(prov, "meta-data", {
        f"{{{ANDROID}}}name": "android.support.FILE_PROVIDER_PATHS",
        f"{{{ANDROID}}}resource": "@xml/file_paths",
    })
# Управление плеером из системы: служба воспроизведения и приёмник кнопок наушников (audio_service)
if not any(x.get(f"{{{ANDROID}}}name") == "com.ryanheise.audioservice.AudioService" for x in application.findall("service")):
    svc = ET.SubElement(application, "service", {
        f"{{{ANDROID}}}name": "com.ryanheise.audioservice.AudioService",
        f"{{{ANDROID}}}foregroundServiceType": "mediaPlayback",
        f"{{{ANDROID}}}exported": "true",
    })
    f = ET.SubElement(svc, "intent-filter")
    ET.SubElement(f, "action", {f"{{{ANDROID}}}name": "android.media.browse.MediaBrowserService"})
    rcv = ET.SubElement(application, "receiver", {
        f"{{{ANDROID}}}name": "com.ryanheise.audioservice.MediaButtonReceiver",
        f"{{{ANDROID}}}exported": "true",
    })
    f = ET.SubElement(rcv, "intent-filter")
    ET.SubElement(f, "action", {f"{{{ANDROID}}}name": "android.intent.action.MEDIA_BUTTON"})
# Вход через браузер: возврат в приложение по схеме из Android Client ID (если он задан)
import os
cid = os.environ.get("GOOGLE_ANDROID_CLIENT_ID", "").strip()
if cid:
    scheme = "com.googleusercontent.apps." + cid.replace(".apps.googleusercontent.com", "")
    activity = application.find("activity")
    has = any(d.get(f"{{{ANDROID}}}scheme") == scheme for d in activity.iter("data"))
    if not has:
        f = ET.SubElement(activity, "intent-filter")
        ET.SubElement(f, "action", {f"{{{ANDROID}}}name": "android.intent.action.VIEW"})
        ET.SubElement(f, "category", {f"{{{ANDROID}}}name": "android.intent.category.DEFAULT"})
        ET.SubElement(f, "category", {f"{{{ANDROID}}}name": "android.intent.category.BROWSABLE"})
        ET.SubElement(f, "data", {f"{{{ANDROID}}}scheme": scheme})
        # Ссылка входа не должна уходить в навигацию Flutter как маршрут
        ET.SubElement(activity, "meta-data", {f"{{{ANDROID}}}name": "flutter_deeply_linking_enabled", f"{{{ANDROID}}}value": "false"})
tree.write(manifest, encoding="utf-8", xml_declaration=True)
print("Android runner ready: app.cavey.cave_player")
PY

# Иконка приложения из assets/icon.png
python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null || python3 -m pip install --quiet pillow
python3 - <<'PY'
from pathlib import Path
from PIL import Image
src = Image.open("assets/icon.png").convert("RGBA")
for name, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
    d = Path(f"android/app/src/main/res/mipmap-{name}")
    d.mkdir(parents=True, exist_ok=True)
    src.resize((px, px), Image.LANCZOS).save(d / "ic_launcher.png")
PY

# Нативная часть: установщик обновлений, FileProvider, подпись постоянным ключом
mkdir -p android/app/src/main/res/xml
cp tool/android/file_paths.xml android/app/src/main/res/xml/file_paths.xml
for f in android/app/src/main/kotlin/app/cavey/cave_player/MainActivity.kt \
         android/app/src/main/java/app/cavey/cave_player/MainActivity.java; do
  [ -f "$f" ] && rm -f "$f"
done
mkdir -p android/app/src/main/kotlin/app/cavey/cave_player
cp tool/android/MainActivity.kt android/app/src/main/kotlin/app/cavey/cave_player/MainActivity.kt
mkdir -p "$HOME/.gradle/init.d"
cp tool/android/signing.init.gradle "$HOME/.gradle/init.d/cavey-signing.gradle"

# Install the MIT-licensed Android on-device extractor into the generated
# Flutter Android runner. Only Android gets this dependency; Windows is unchanged.
python3 - <<'PY'
from pathlib import Path

base = Path("android/app")
gradle = next((p for p in (base / "build.gradle.kts", base / "build.gradle") if p.exists()), None)
if gradle is None:
    raise RuntimeError("Android Gradle project has not been generated")
text = gradle.read_text(encoding="utf-8")
artifact = "dev.ffmpegkit-maintained:yt-dlp-android:2.0.2"
if artifact not in text:
    if gradle.suffix == ".kts":
        text += '\n// Cavey Android: on-device YouTube audio extractor.\ndependencies {\n    implementation("' + artifact + '")\n}\n'
    else:
        text += "\n// Cavey Android: on-device YouTube audio extractor.\ndependencies {\n    implementation '" + artifact + "'\n}\n"
    gradle.write_text(text, encoding="utf-8")
print("Android yt-dlp dependency installed")
PY

flutter pub get
