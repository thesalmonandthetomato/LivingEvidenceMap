#!/usr/bin/env python3
"""Store one large LivingEvidenceMap pipeline artifact on Zenodo.

This intentionally mirrors the proven upload mechanism in
thesalmonandthetomato/fulltexttest/scripts/openalex_daily_retrieve.py:
requests.post() -> deposition bucket -> streamed requests.put().
By default the deposition remains a draft.
"""
import argparse, hashlib, json, os, time
from pathlib import Path
from urllib.parse import quote

import requests

API = "https://zenodo.org/api/deposit/depositions"

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--file", required=True)
    p.add_argument("--title", default="Living Evidence Map pipeline snapshot")
    p.add_argument("--description", default="Large pipeline snapshot for the Living Evidence Map.")
    p.add_argument("--snapshot-type", default="pipeline_snapshot")
    p.add_argument("--source-run-id", default="")
    p.add_argument("--source-commit", default="")
    p.add_argument("--output-manifest", default="zenodo_snapshot_manifest.json")
    p.add_argument("--publish", action="store_true")
    a = p.parse_args()

    path = Path(a.file)
    if not path.is_file():
        raise SystemExit(f"Missing file: {path}")

    token = os.environ.get("ZENODO_ACCESS_TOKEN", "")
    if not token:
        raise SystemExit("ZENODO_ACCESS_TOKEN is required")

    headers = {"Authorization": f"Bearer {token}"}

    # Match the proven fulltexttest pattern exactly for deposition creation.
    print("ZENODO CREATE", flush=True)
    r = requests.post(
        API,
        json={},
        headers={**headers, "Content-Type": "application/json"},
        timeout=(10, 60),
    )
    r.raise_for_status()
    dep = r.json()
    dep_id = str(dep["id"])
    bucket = dep["links"]["bucket"]
    print(f"ZENODO DRAFT id={dep_id}", flush=True)

    notes = "Pipeline storage snapshot."
    if a.source_run_id:
        notes += f" Source GitHub Actions run: {a.source_run_id}."
    if a.source_commit:
        notes += f" Source commit: {a.source_commit}."

    meta = {
        "metadata": {
            "title": a.title,
            "upload_type": "dataset",
            "description": a.description,
            "creators": [{"name": "thesalmonandthetomato/LivingEvidenceMap"}],
            "keywords": [
                "Living Evidence Map",
                "salmon aquaculture",
                "evidence synthesis",
                a.snapshot_type,
            ],
            "notes": notes,
        }
    }

    r = requests.put(
        f"{API}/{dep_id}",
        json=meta,
        headers={**headers, "Content-Type": "application/json"},
        timeout=(10, 60),
    )
    r.raise_for_status()
    dep = r.json()

    print(f"ZENODO UPLOAD {path.name} bytes={path.stat().st_size}", flush=True)
    with path.open("rb") as fh:
        r = requests.put(
            f"{bucket}/{quote(path.name, safe='')}",
            data=fh,
            headers=headers,
            timeout=(30, 600),
        )
    r.raise_for_status()
    uploaded = r.json()
    print("ZENODO UPLOAD COMPLETE", flush=True)

    published = None
    if a.publish:
        r = requests.post(
            f"{API}/{dep_id}/actions/publish",
            headers=headers,
            timeout=(10, 60),
        )
        r.raise_for_status()
        published = r.json()
        print(f"ZENODO PUBLISHED id={dep_id}", flush=True)

    obj = published or dep
    manifest = {
        "storage": "zenodo",
        "api": "legacy_deposition_requests_fulltexttest_pattern",
        "status": "published" if a.publish else "draft",
        "snapshot_type": a.snapshot_type,
        "deposition_id": dep_id,
        "record_id": dep_id,
        "record_url": obj.get("links", {}).get("html", f"https://zenodo.org/deposit/{dep_id}"),
        "doi": obj.get("doi"),
        "filename": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": sha256_file(path),
        "zenodo_checksum": uploaded.get("checksum"),
        "source_run_id": a.source_run_id or None,
        "source_commit": a.source_commit or None,
        "uploaded_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "authoritative_storage": True,
        "git_lfs_required": False,
    }

    out = Path(a.output_manifest)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: uploaded {path.name} to Zenodo draft {dep_id}", flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
