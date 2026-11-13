#!/usr/bin/env python3
"""Encrypt the existing Android release signing configuration for its owner.

Runs ONLY in a manually dispatched, trusted GitHub Actions job. The recipient
certificate is read from a GitHub secret set by the owner from their own PC.
An encrypted CMS envelope is the ONLY file exported from this script.

Never log any signing secrets, decoded keystore content or unencrypted bundle.
"""
import base64
import binascii
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        raise SystemExit(f"Missing GitHub Actions secret: {name}")
    return value


def signing_sha1(data: bytes, store_password: str, alias: str) -> str:
    # Ubuntu runners provide a RAM-backed tmpfs. Leave no plaintext JKS in
    # the job's workspace or uploaded Actions artifacts.
    with tempfile.TemporaryDirectory(prefix="cavey-signing-", dir="/dev/shm") as tmp:
        keystore = Path(tmp) / "signing.jks"
        keystore.write_bytes(data)
        result = subprocess.run(
            ["keytool", "-list", "-v", "-keystore", str(keystore),
             "-storepass", store_password, "-alias", alias],
            env={**os.environ, "LC_ALL": "C"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False, timeout=30,
        )
        if result.returncode != 0:
            # Do not emit stderr: tools may echo command-line arguments.
            raise SystemExit("Cannot verify existing JKS and alias with keytool")
        match = re.search(r"(?im)^\s*SHA1:\s*([0-9A-F:]+)\s*$", result.stdout)
        if not match:
            raise SystemExit("keytool did not return the signing certificate SHA-1")
        return match.group(1).replace(":", "").upper()


def main() -> None:
    # Explicitly refuse untrusted triggers and unexpected forks.
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise SystemExit("Manual workflow_dispatch required")
    if os.environ.get("GITHUB_REPOSITORY") != "Creative-Cave-uefn/Cavey-Player":
        raise SystemExit("Unexpected repository")
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise SystemExit("Recovery must run from reviewed main")

    recipient = required("CAVEY_RECOVERY_CERT_PEM")
    original_b64 = required("ANDROID_KEYSTORE_BASE64").strip()
    store_password = required("ANDROID_KEYSTORE_PASSWORD")
    alias = os.environ.get("ANDROID_KEY_ALIAS", "").strip() or "cavey"
    key_password = os.environ.get("ANDROID_KEY_PASSWORD", "") or store_password
    web_id = required("GOOGLE_WEB_CLIENT_ID")
    android_id = os.environ.get("GOOGLE_ANDROID_CLIENT_ID", "")

    try:
        jks = base64.b64decode(original_b64, validate=True)
    except (binascii.Error, ValueError):
        raise SystemExit("ANDROID_KEYSTORE_BASE64 is not valid base64")
    if len(jks) < 32 or len(jks) > 1024 * 1024:
        raise SystemExit("Unexpected keystore size")

    sha1 = signing_sha1(jks, store_password, alias)
    payload = {
        "format": "cavey-android-signing-backup-v1",
        "app_id": "app.cavey.cave_player",
        "keystore_base64": original_b64,
        "keystore_password": store_password,
        "key_password": key_password,
        "key_alias": alias,
        "google_web_client_id": web_id,
        "google_android_client_id": android_id,
        "expected_sha1": sha1,
    }
    cleartext = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    output = Path("signing-transfer-output")
    output.mkdir(exist_ok=True)
    envelope = output / "CaveyAndroidSigning.p7m"

    with tempfile.TemporaryDirectory(prefix="cavey-public-") as tmp:
        cert_path = Path(tmp) / "owner-recipient.pem"
        cert_path.write_text(recipient, encoding="utf-8")
        verify = subprocess.run(
            ["openssl", "x509", "-in", str(cert_path), "-noout"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if verify.returncode != 0:
            raise SystemExit("Owner recovery certificate is not valid PEM")
        encrypted = subprocess.run(
            ["openssl", "cms", "-encrypt", "-binary",
             "-aes-256-cbc", "-outform", "DER", "-out", str(envelope), str(cert_path)],
            input=cleartext, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, timeout=30,
        )
        if encrypted.returncode != 0:
            envelope.unlink(missing_ok=True)
            raise SystemExit("CMS encryption failed (no plaintext artifact was published)")

    if not envelope.is_file() or envelope.stat().st_size < 100:
        raise SystemExit("Encrypted backup was not produced")
    print("Created encrypted Android signing backup for owner certificate only.")
    print("Artifact contains an encrypted CMS envelope, never plaintext keys.")


if __name__ == "__main__":
    main()
