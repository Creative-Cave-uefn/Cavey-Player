#!/usr/bin/env python3
"""Источник для SideStore/AltStore: список приложений и ссылка на последний .ipa."""
import json, os, sys

version = os.environ["APP_VERSION"]
repo = os.environ["RELEASES_REPO"]
size = os.path.getsize(sys.argv[1])
base = f"https://github.com/{repo}/releases/download"
from datetime import datetime, timezone

source = {
    "name": "Cavey Player",
    "identifier": "app.cavey.source",
    "subtitle": "Музыка с общих Google Дисков",
    "apps": [
        {
            "name": "Cavey Player",
            "bundleIdentifier": "app.cavey.cavePlayer",
            "developerName": "Creative Cave",
            "subtitle": "Общая музыкальная библиотека",
            "localizedDescription": "Cavey Player для iPhone: общая библиотека на Google Дисках, волна, плейлисты и компания.",
            "iconURL": f"{base}/ios-source/icon.png",
            "tintColor": "F2C14E",
            "version": version,
            "versionDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "versionDescription": os.environ.get("NOTES", "")[:500],
            "downloadURL": f"{base}/ios-v{version}/CaveyPlayer.ipa",
            "size": size,
        }
    ],
    "news": [],
}
with open("apps.json", "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print("apps.json ready")
