#!/usr/bin/env python3
"""Download the OpenAlex full-text corpus in deterministic <=100-file batches.

Strategy:
  1. Download GROBID TEI XML for all works where it is available.
  2. Download PDFs only for works that have PDF but no GROBID XML.

The combined plan is deliberately ordered GROBID-first. With the current audit
(3,705 GROBID + 230 PDF-only), this produces exactly 40 batches of <=100 files.

The script is intentionally idempotent within a GitHub Actions cache: if a
previous attempt already produced a valid file in the batch output directory,
it is not downloaded again. The workflow caches each batch separately so a
failed run can be re-run without unnecessarily re-downloading successful files.

OpenAlex content downloads cost $0.01 per file. A free API key supplies $1/day,
so the workflow never requests more than 100 content files in one batch.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
GROBID_CSV = ROOT / "data" / "openalex_grobid_candidates.csv"
PDF_CSV = ROOT / "data" / "openalex_pdf_candidates.csv"

BATCH_SIZE = 100
MAX_RETRIES = 5
TIMEOUT = 120
USER_AGENT = "LivingEvidenceMap/OpenAlex-fulltext/1.0"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def build_plan() -> list[dict[str, str]]:
    """Return one-file-per-work plan, GROBID first and PDF-only second."""
    grobid = read_csv(GROBID_CSV)
    pdf = read_csv(PDF_CSV)

    grobid_rows = []
    for row in grobid:
        if row.get("doi_exact_match") != "TRUE" or row.get("has_grobid_xml") != "TRUE":
            continue
        grobid_rows.append(
            {
                "doi": row["input_doi"],
                "openalex_id": row["openalex_id"].rstrip("/").split("/")[-1],
                "url": row.get("grobid_xml_url", ""),
                "format": "grobid_xml",
            }
        )

    # Only PDF-only records are included here. Works with both PDF and GROBID
    # are already represented by the GROBID entry and must not be downloaded twice.
    grobid_dois = {r["doi"].lower() for r in grobid_rows}
    pdf_only_rows = []
    for row in pdf:
        doi = row.get("input_doi", "")
        if (
            row.get("doi_exact_match") == "TRUE"
            and row.get("has_pdf") == "TRUE"
            and doi.lower() not in grobid_dois
        ):
            pdf_only_rows.append(
                {
                    "doi": doi,
                    "openalex_id": row["openalex_id"].rstrip("/").split("/")[-1],
                    "url": row.get("pdf_url", ""),
                    "format": "pdf",
                }
            )

    if not grobid_rows:
        raise RuntimeError("No GROBID candidates were found in data/openalex_grobid_candidates.csv")

    plan = grobid_rows + pdf_only_rows

    if len(plan) != len(set(r["doi"].lower() for r in plan)):
        raise RuntimeError("The download plan contains duplicate DOIs.")

    return plan


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def valid_file(path: Path, fmt: str) -> bool:
    if not path.exists() or path.stat().st_size < 512:
        return False
    with path.open("rb") as fh:
        head = fh.read(4096)
    if fmt == "pdf":
        return head.startswith(b"%PDF")
    # OpenAlex returns GROBID TEI XML from the .grobid-xml endpoint.
    text = head.decode("utf-8", errors="ignore").lower()
    return "<tei" in text or "<tei:" in text or "<teiheader" in text


def download(url: str, api_key: str, destination: Path) -> None:
    if not url:
        raise RuntimeError("Candidate has no OpenAlex content URL")

    request_url = url + ("&" if "?" in url else "?") + "api_key=" + api_key
    tmp = destination.with_suffix(destination.suffix + ".part")

    last_error: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = Request(request_url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=TIMEOUT) as response, tmp.open("wb") as out:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
            tmp.replace(destination)
            return
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            last_error = exc
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            if attempt == MAX_RETRIES:
                break
            delay = min(60, 2 ** (attempt - 1) * 2)
            print(f"  download failed ({exc}); retrying in {delay}s", flush=True)
            time.sleep(delay)

    raise RuntimeError(f"Download failed after {MAX_RETRIES} attempts: {url}; {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "openalex_fulltext")
    args = parser.parse_args()

    api_key = os.environ.get("OPENALEX_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENALEX_API_KEY is not set")

    plan = build_plan()
    total_batches = (len(plan) + BATCH_SIZE - 1) // BATCH_SIZE
    if args.batch < 1 or args.batch > total_batches:
        raise RuntimeError(f"Batch must be between 1 and {total_batches}; got {args.batch}")

    start = (args.batch - 1) * BATCH_SIZE
    end = min(start + BATCH_SIZE, len(plan))
    batch = plan[start:end]

    print(f"OpenAlex full-text plan: {len(plan)} files in {total_batches} batches", flush=True)
    print(f"Batch {args.batch}/{total_batches}: files {start + 1}-{end}", flush=True)
    print("GROBID-first; PDF-only fallback; maximum 100 content downloads", flush=True)

    batch_dir = args.output / f"batch_{args.batch:03d}"
    batch_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = batch_dir / "download_manifest.csv"

    manifest_rows = []
    failures = []

    for i, row in enumerate(batch, start=start + 1):
        ext = ".tei.xml" if row["format"] == "grobid_xml" else ".pdf"
        destination = batch_dir / f"{row['openalex_id']}{ext}"

        if valid_file(destination, row["format"]):
            status = "already_present"
            print(f"[{i}/{len(plan)}] SKIP {row['openalex_id']} ({row['format']})", flush=True)
        else:
            print(f"[{i}/{len(plan)}] DOWNLOAD {row['openalex_id']} ({row['format']})", flush=True)
            try:
                download(row["url"], api_key, destination)
                if not valid_file(destination, row["format"]):
                    raise RuntimeError("Downloaded file failed format validation")
                status = "downloaded"
            except Exception as exc:
                status = "failed"
                failures.append((row, str(exc)))
                print(f"  FAILED: {exc}", flush=True)

        size = destination.stat().st_size if destination.exists() else 0
        checksum = sha256_file(destination) if status != "failed" and destination.exists() else ""
        manifest_rows.append(
            {
                "batch": args.batch,
                "batch_position": i,
                "doi": row["doi"],
                "openalex_id": row["openalex_id"],
                "format": row["format"],
                "url": row["url"],
                "status": status,
                "bytes": size,
                "sha256": checksum,
                "file": destination.name if destination.exists() else "",
            }
        )

        # Flush the manifest after every file so an interrupted runner retains
        # a useful record of what completed; the cache preserves the files.
        with manifest_path.open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=manifest_rows[0].keys())
            writer.writeheader()
            writer.writerows(manifest_rows)

    downloaded = sum(r["status"] in {"downloaded", "already_present"} for r in manifest_rows)
    print(f"Completed/available: {downloaded}/{len(batch)}", flush=True)

    if failures:
        print(f"{len(failures)} downloads failed; the batch is marked failed.", flush=True)
        return 1

    print("Batch completed successfully.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
