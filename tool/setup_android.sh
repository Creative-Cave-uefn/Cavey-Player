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
tree.write(manifest, encoding="utf-8", xml_declaration=True)
print("Android runner ready: app.cavey.cave_player")
PY

flutter pub get
