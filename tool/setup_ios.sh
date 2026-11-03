#!/usr/bin/env bash
# Готовит iOS-проект для телефонной точки входа (lib/mobile_main.dart): создаёт runner Flutter,
# включает фоновое аудио, схему возврата из браузера для входа в Google и иконки.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f ios/Runner/Info.plist ]; then
  flutter create --platforms=ios --org app.cavey --project-name cave_player .
fi

python3 - <<'PY'
import os, plistlib, re
from pathlib import Path

plist_path = Path("ios/Runner/Info.plist")
with plist_path.open("rb") as f:
    info = plistlib.load(f)

info["CFBundleDisplayName"] = "Cavey Player"
info["CFBundleName"] = "Cavey Player"
# Музыка продолжает играть при заблокированном экране
info["UIBackgroundModes"] = ["audio"]
# Медиа-движок раздаёт треки через локальный адрес 127.0.0.1 по HTTP
info["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
# Ссылка входа не должна уходить в навигацию Flutter как маршрут
info["FlutterDeepLinkingEnabled"] = False
info["ITSAppUsesNonExemptEncryption"] = False

cid = os.environ.get("GOOGLE_IOS_CLIENT_ID", "").strip()
if cid:
    scheme = "com.googleusercontent.apps." + cid.replace(".apps.googleusercontent.com", "")
    types = info.get("CFBundleURLTypes", [])
    if not any(scheme in t.get("CFBundleURLSchemes", []) for t in types):
        types.append({"CFBundleURLName": "google-oauth", "CFBundleURLSchemes": [scheme]})
    info["CFBundleURLTypes"] = types

with plist_path.open("wb") as f:
    plistlib.dump(info, f)

# media_kit требует iOS 13+
pbx = Path("ios/Runner.xcodeproj/project.pbxproj")
text = pbx.read_text(encoding="utf-8")
text = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 13.0;", text)
pbx.write_text(text, encoding="utf-8")

podfile = Path("ios/Podfile")
if podfile.exists():
    p = podfile.read_text(encoding="utf-8")
    if re.search(r"^\s*#?\s*platform :ios", p, flags=re.M):
        p = re.sub(r"^\s*#?\s*platform :ios.*$", "platform :ios, '13.0'", p, count=1, flags=re.M)
    else:
        p = "platform :ios, '13.0'\n" + p
    podfile.write_text(p, encoding="utf-8")
print("iOS runner ready")
PY

# Нативная часть: приём ссылки возврата из браузера
cp tool/ios/AppDelegate.swift ios/Runner/AppDelegate.swift

# Иконка приложения из assets/icon.png (без прозрачности, как требует iOS)
python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null || python3 -m pip install --quiet pillow
python3 - <<'PY'
import json
from pathlib import Path
from PIL import Image
src = Image.open("assets/icon.png").convert("RGBA")
bg = Image.new("RGBA", src.size, (14, 17, 34, 255))
bg.alpha_composite(src)
flat = bg.convert("RGB")
d = Path("ios/Runner/Assets.xcassets/AppIcon.appiconset")
contents = json.loads((d / "Contents.json").read_text(encoding="utf-8"))
for img in contents["images"]:
    name = img.get("filename")
    if not name:
        continue
    base = float(img["size"].split("x")[0])
    scale = int(img["scale"].replace("x", ""))
    px = int(round(base * scale))
    flat.resize((px, px), Image.LANCZOS).save(d / name)
print("icons ok")
PY

flutter pub get
