#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

FIELDS = [
    "doi", "openalex_id", "workflow_name", "workflow_run_id", "workflow_run_url",
    "run_number", "zenodo_record_id", "zenodo_record_url", "zenodo_version_doi",
    "zenodo_concept_doi", "zenodo_archive_filename", "status", "notes"
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--receipt", required=True)
    ap.add_argument("--registry", required=True)
    args = ap.parse_args()

    manifest = list(csv.DictReader(Path(args.manifest).open(encoding="utf-8-sig", newline="")))
    receipt = json.loads(Path(args.receipt).read_text(encoding="utf-8"))
    registry = Path(args.registry)
    registry.parent.mkdir(parents=True, exist_ok=True)

    existing = []
    if registry.exists():
        with registry.open(encoding="utf-8", newline="") as fh:
            existing = list(csv.DictReader(fh))

    run_id = str(receipt.get("github_run_id", ""))
    run_url = receipt.get("github_run_url", "")
    zenodo_id = str(receipt.get("deposition_id", ""))
    zenodo_url = receipt.get("deposition_url", f"https://zenodo.org/records/{zenodo_id}")
    archive = receipt.get("zip_file", "")
    run_number = ""

    # A rerun of the same paper in a different workflow run is intentionally a
    # separate provenance row.  Key on run + OpenAlex ID, not DOI alone.
    existing_keys = {(r.get("workflow_run_id", ""), r.get("openalex_id", "")) for r in existing}
    for row in manifest:
        if row.get("status") not in {"downloaded", "already_present"}:
            continue
        key = (run_id, row.get("openalex_id", ""))
        if key in existing_keys:
            continue
        existing.append({
            "doi": row.get("doi", ""),
            "openalex_id": row.get("openalex_id", ""),
            "workflow_name": "OpenAlex full-text download",
            "workflow_run_id": run_id,
            "workflow_run_url": run_url,
            "run_number": run_number,
            "zenodo_record_id": zenodo_id,
            "zenodo_record_url": zenodo_url,
            "zenodo_version_doi": "",
            "zenodo_concept_doi": "",
            "zenodo_archive_filename": archive,
            "status": "deposited",
            "notes": f"OpenAlex batch {row.get('batch', '')}; {row.get('format', '')}; source file {row.get('file', '')}",
        })
        existing_keys.add(key)

    with registry.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(existing)
    print(f"Registry contains {len(existing)} provenance rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
