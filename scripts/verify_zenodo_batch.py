#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET

import requests

ZENODO_API = "https://zenodo.org/api"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Download a Zenodo draft batch back and verify its contents.")
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    token = os.environ["ZENODO_ACCESS_TOKEN"]
    batch_dir = args.output / f"batch_{args.batch}"
    receipt_path = batch_dir / "zenodo_receipt.json"
    if not receipt_path.exists():
        raise RuntimeError(f"No Zenodo receipt found: {receipt_path}")

    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    deposition_id = receipt["deposition_id"]
    expected_zip_sha256 = receipt["zip_sha256"]
    expected_zip_bytes = int(receipt["zip_bytes"])
    expected_files = int(receipt["successful_files"])

    headers = {"Authorization": f"Bearer {token}"}
    session = requests.Session()
    meta_url = f"{ZENODO_API}/deposit/depositions/{deposition_id}"
    response = session.get(meta_url, headers=headers, timeout=60)
    response.raise_for_status()
    deposition = response.json()

    files = deposition.get("files", [])
    if len(files) != 1:
        raise RuntimeError(f"Expected exactly one Zenodo batch ZIP, found {len(files)} files")

    remote = files[0]
    remote_name = remote.get("filename", "")
    remote_size = int(remote.get("filesize", 0))
    if remote_name != receipt["zip_file"]:
        raise RuntimeError(f"Zenodo filename mismatch: expected {receipt['zip_file']!r}, got {remote_name!r}")
    if remote_size != expected_zip_bytes:
        raise RuntimeError(f"Zenodo size mismatch: expected {expected_zip_bytes}, got {remote_size}")

    download_url = remote.get("links", {}).get("download")
    if not download_url:
        raise RuntimeError("Zenodo file has no download URL")

    with tempfile.TemporaryDirectory(prefix="zenodo_verify_") as tmp:
        zip_path = Path(tmp) / remote_name
        with session.get(download_url, headers=headers, stream=True, timeout=120) as r:
            r.raise_for_status()
            with zip_path.open("wb") as fh:
                for chunk in r.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        fh.write(chunk)

        actual_size = zip_path.stat().st_size
        actual_sha256 = sha256_file(zip_path)
        if actual_size != expected_zip_bytes:
            raise RuntimeError(f"Downloaded Zenodo ZIP size mismatch: expected {expected_zip_bytes}, got {actual_size}")
        if actual_sha256 != expected_zip_sha256:
            raise RuntimeError(f"Downloaded Zenodo ZIP SHA-256 mismatch: expected {expected_zip_sha256}, got {actual_sha256}")

        with zipfile.ZipFile(zip_path, "r") as zf:
            bad = zf.testzip()
            if bad is not None:
                raise RuntimeError(f"Zenodo ZIP CRC test failed for {bad}")
            names = zf.namelist()
            xml_names = [n for n in names if n.lower().endswith(".tei.xml")]
            manifest_names = [n for n in names if n.endswith("download_manifest.csv")]
            if len(xml_names) != expected_files:
                raise RuntimeError(f"Zenodo XML count mismatch: expected {expected_files}, got {len(xml_names)}")
            if len(manifest_names) != 1:
                raise RuntimeError(f"Expected one manifest in Zenodo ZIP, found {len(manifest_names)}")

            invalid_xml = []
            nonempty_xml = 0
            for name in xml_names:
                data = zf.read(name)
                if not data.strip():
                    invalid_xml.append((name, "empty"))
                    continue
                try:
                    ET.fromstring(data)
                except ET.ParseError as exc:
                    invalid_xml.append((name, str(exc)))
                    continue
                nonempty_xml += 1
            if invalid_xml:
                raise RuntimeError(f"Zenodo round-trip XML validation failed for {len(invalid_xml)} files: {invalid_xml[:3]}")

    verification = {
        "batch": args.batch,
        "deposition_id": deposition_id,
        "deposition_url": deposition.get("links", {}).get("html", receipt.get("deposition_url", "")),
        "remote_filename": remote_name,
        "remote_filesize": remote_size,
        "downloaded_filesize": actual_size,
        "sha256": actual_sha256,
        "sha256_matches_local": actual_sha256 == expected_zip_sha256,
        "xml_files_verified": nonempty_xml,
        "manifest_files_found": len(manifest_names),
        "round_trip_verified": True,
    }
    out = batch_dir / "zenodo_verification.json"
    out.write_text(json.dumps(verification, indent=2), encoding="utf-8")
    print("ZENODO ROUND-TRIP VERIFIED", flush=True)
    print(json.dumps(verification, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    main()
