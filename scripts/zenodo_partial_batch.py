#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path

import download_openalex_fulltext as oa


def read_manifest(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def main() -> int:
    parser = argparse.ArgumentParser(description="Deposit all successfully downloaded files from a partial OpenAlex batch.")
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    plan = oa.build_plan()
    total_batches, start, end, batch, part = oa.batch_context(plan, args.batch)
    batch_dir = args.output / f"batch_{args.batch}"
    manifest_path = batch_dir / "download_manifest.csv"
    if not manifest_path.exists():
        raise RuntimeError(f"No checkpoint manifest found: {manifest_path}")

    manifest = read_manifest(manifest_path)
    successful = [r for r in manifest if r.get("status") in {"downloaded", "already_present"} and r.get("file")]
    failed = [r for r in manifest if r.get("status") == "failed"]
    if not successful:
        raise RuntimeError("No successfully downloaded files are available to deposit.")

    # Validate every file that will enter the partial-batch ZIP. Failed/missing
    # records are deliberately excluded and remain in the manifest for later recovery.
    valid_files = []
    for row in successful:
        fmt = row["format"]
        path = batch_dir / row["file"]
        ok, reason = oa.validate_content(path, fmt)
        if not ok:
            raise RuntimeError(f"Checkpoint file failed validation: {path.name}: {reason}")
        valid_files.append(path)

    # make_batch_zip includes the manifest plus every valid downloaded content
    # file in the batch directory. It never moves or deletes the source files.
    zip_path, zip_sha256, zip_bytes = oa.make_batch_zip(batch_dir, args.batch)
    token = os.environ["ZENODO_ACCESS_TOKEN"]
    deposition = oa.get_or_create_zenodo_draft(token, part, total_batches)
    upload_status = oa.upload_batch_to_zenodo(token, deposition, zip_path)

    receipt = {
        "batch": args.batch,
        "total_batches": total_batches,
        "plan_range": [start + 1, end],
        "successful_files": len(valid_files),
        "failed_files": len(failed),
        "failed_records": [
            {"doi": r.get("doi", ""), "openalex_id": r.get("openalex_id", ""), "format": r.get("format", ""), "url": r.get("url", "")}
            for r in failed
        ],
        "deposition_id": deposition["id"],
        "deposition_url": deposition.get("links", {}).get("html", ""),
        "upload_status": upload_status,
        "zip_file": zip_path.name,
        "zip_bytes": zip_bytes,
        "zip_sha256": zip_sha256,
    }
    (batch_dir / "zenodo_receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")

    print(f"Zenodo partial-batch deposit complete: {len(valid_files)} files uploaded; {len(failed)} records flagged for later recovery.", flush=True)
    print(json.dumps(receipt, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    main()
