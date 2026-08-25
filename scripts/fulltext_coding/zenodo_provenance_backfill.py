#!/usr/bin/env python3
"""Backfill LivingEvidenceMap Zenodo provenance and rename published archives.

For a published Zenodo record, Zenodo requires a new version to change files.
This utility creates that version, replaces the archive with a run-linked name,
and emits a provenance CSV. It never changes the original version in place.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path
from urllib.parse import quote

import requests

API = "https://zenodo.org/api/deposit/depositions"


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Accept": "application/json"}


def get_dep(token: str, dep_id: str) -> dict:
    r = requests.get(f"{API}/{dep_id}", headers=auth(token), timeout=60)
    r.raise_for_status()
    return r.json()


def latest_version(token: str, dep_id: str) -> dict:
    data = get_dep(token, dep_id)
    latest = data.get("links", {}).get("latest_draft")
    if latest:
        r = requests.get(latest, headers=auth(token), timeout=60)
        r.raise_for_status()
        return r.json()
    return data


def create_version(token: str, dep_id: str) -> dict:
    r = requests.post(f"{API}/{dep_id}/actions/newversion", headers=auth(token), timeout=60)
    r.raise_for_status()
    return r.json()


def download_file(token: str, file_obj: dict) -> bytes:
    url = file_obj["links"]["download"]
    r = requests.get(url, headers=auth(token), timeout=300)
    r.raise_for_status()
    return r.content


def delete_file(token: str, dep_id: str, file_id: str) -> None:
    r = requests.delete(f"{API}/{dep_id}/files/{quote(str(file_id), safe='')}", headers=auth(token), timeout=60)
    r.raise_for_status()


def upload_file(token: str, dep: dict, filename: str, data: bytes) -> dict:
    bucket = dep["links"]["bucket"]
    r = requests.put(
        f"{bucket}/{quote(filename, safe='')}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/zip"},
        data=data,
        timeout=600,
    )
    r.raise_for_status()
    return r.json()


def publish(token: str, dep_id: str) -> dict:
    r = requests.post(f"{API}/{dep_id}/actions/publish", headers=auth(token), timeout=120)
    r.raise_for_status()
    return r.json()


def doi_from_xml(blob: bytes) -> str:
    text = blob.decode("utf-8", errors="ignore")
    patterns = [r"10\.\d{4,9}/[-._;()/:A-Z0-9]+"]
    for p in patterns:
        m = re.search(p, text, re.I)
        if m:
            return m.group(0).rstrip(".,;)")
    return ""


def openalex_from_name(name: str) -> str:
    m = re.search(r"W\d+", name)
    return m.group(0) if m else ""


def build_registry_from_archive(data: bytes, dep: dict, run_id: str, workflow_name: str, run_number: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            if info.is_dir() or not info.filename.lower().endswith((".xml", ".tei.xml")):
                continue
            work_id = openalex_from_name(info.filename)
            if not work_id:
                continue
            doi = doi_from_xml(z.read(info.filename))
            rows.append({
                "doi": doi,
                "openalex_id": work_id,
                "workflow_name": workflow_name,
                "workflow_run_id": run_id,
                "workflow_run_url": f"https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/{run_id}" if run_id else "",
                "run_number": run_number,
                "zenodo_record_id": str(dep.get("id", "")),
                "zenodo_record_url": f"https://zenodo.org/records/{dep.get('id', '')}",
                "zenodo_version_doi": dep.get("metadata", {}).get("prereserve_doi", {}).get("doi", "") or dep.get("doi", ""),
                "zenodo_concept_doi": dep.get("conceptdoi", ""),
                "zenodo_archive_filename": "",
                "status": "backfill",
                "notes": "Generated from Zenodo archive; DOI extracted from full text where available.",
            })
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deposition-id", required=True)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--run-number", default="")
    ap.add_argument("--workflow-name", default="Test full-text AI coding")
    ap.add_argument("--rename", action="store_true")
    ap.add_argument("--registry", default="data/reference/fulltext_batch_registry.csv")
    args = ap.parse_args()

    token = os.environ.get("ZENODO_ACCESS_TOKEN")
    if not token:
        raise SystemExit("ZENODO_ACCESS_TOKEN is required")

    current = get_dep(token, args.deposition_id)
    files = current.get("files", [])
    if not files:
        raise SystemExit(f"Zenodo deposition {args.deposition_id} has no files")
    source_file = files[0]
    archive = download_file(token, source_file)

    if args.rename:
        if not args.run_id:
            raise SystemExit("--run-id is required when --rename is used")
        new_name = f"LivingEvidenceMap_fulltext_batch_run-{args.run_id}.zip"
        version = create_version(token, args.deposition_id)
        draft_id = str(version["id"])
        # The new version inherits the previous file; replace it with the same bytes under the new name.
        draft = get_dep(token, draft_id)
        inherited = draft.get("files", [])
        for f in inherited:
            delete_file(token, draft_id, str(f["id"]))
        upload_file(token, draft, new_name, archive)
        published = publish(token, draft_id)
        current = published
        print(f"Published Zenodo version {published.get('id')} with filename {new_name}")
    else:
        new_name = source_file.get("filename", "")

    rows = build_registry_from_archive(archive, current, args.run_id, args.workflow_name, args.run_number)
    for row in rows:
        row["zenodo_archive_filename"] = new_name

    registry = Path(args.registry)
    registry.parent.mkdir(parents=True, exist_ok=True)
    fields = ["doi","openalex_id","workflow_name","workflow_run_id","workflow_run_url","run_number","zenodo_record_id","zenodo_record_url","zenodo_version_doi","zenodo_concept_doi","zenodo_archive_filename","status","notes"]
    existing: list[dict[str, str]] = []
    if registry.exists():
        with registry.open(newline="", encoding="utf-8") as fh:
            existing = list(csv.DictReader(fh))
    keys = {(r.get("workflow_run_id", ""), r.get("openalex_id", "")) for r in existing}
    for row in rows:
        if (row["workflow_run_id"], row["openalex_id"]) not in keys:
            existing.append(row)
    with registry.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(existing)
    print(f"Registry updated with {len(rows)} archive records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
