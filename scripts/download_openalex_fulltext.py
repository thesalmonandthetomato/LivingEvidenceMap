#!/usr/bin/env python3
"""Download OpenAlex full text and durably stage each batch in private Zenodo.

Strategy
--------
* GROBID TEI XML is preferred whenever OpenAlex has it.
* PDF is downloaded only for the 230 PDF-only records.
* At most 100 OpenAlex content files are requested per workflow run.
* The downloaded files are retained in a GitHub Actions cache/artifact and
  packaged into one ZIP for durable Zenodo storage.
* Zenodo uploads are idempotent: a completed batch ZIP already present in the
  corresponding private draft is not uploaded again.

Zenodo storage is split into four private draft depositions (10 batches each).
This stays well inside Zenodo's per-record 100-file limit and reduces the risk
that a single large deposition becomes a bottleneck. The drafts are never
published by this workflow.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import time
import zipfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
GROBID_CSV = ROOT / "data" / "openalex_grobid_candidates.csv"
PDF_CSV = ROOT / "data" / "openalex_pdf_candidates.csv"

BATCH_SIZE = 100
BATCHES_PER_ZENODO_DEPOSITION = 10
MAX_RETRIES = 5
TIMEOUT = 120
USER_AGENT = "LivingEvidenceMap/OpenAlex-fulltext/2.0"
ZENODO_API = "https://zenodo.org/api"
ZENODO_TITLE_PREFIX = "LivingEvidenceMap OpenAlex Full Text"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def build_plan() -> list[dict[str, str]]:
    grobid = read_csv(GROBID_CSV)
    pdf = read_csv(PDF_CSV)

    grobid_rows = []
    for row in grobid:
        if row.get("doi_exact_match") != "TRUE" or row.get("has_grobid_xml") != "TRUE":
            continue
        grobid_rows.append({
            "doi": row["input_doi"],
            "openalex_id": row["openalex_id"].rstrip("/").split("/")[-1],
            "url": row.get("grobid_xml_url", ""),
            "format": "grobid_xml",
        })

    grobid_dois = {r["doi"].lower() for r in grobid_rows}
    pdf_only_rows = []
    for row in pdf:
        doi = row.get("input_doi", "")
        if (
            row.get("doi_exact_match") == "TRUE"
            and row.get("has_pdf") == "TRUE"
            and doi.lower() not in grobid_dois
        ):
            pdf_only_rows.append({
                "doi": doi,
                "openalex_id": row["openalex_id"].rstrip("/").split("/")[-1],
                "url": row.get("pdf_url", ""),
                "format": "pdf",
            })

    if not grobid_rows:
        raise RuntimeError("No GROBID candidates were found.")

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
    text = head.decode("utf-8", errors="ignore").lower()
    return "<tei" in text or "<tei:" in text or "<teiheader" in text


def download_openalex(url: str, api_key: str, destination: Path) -> None:
    if not url:
        raise RuntimeError("Candidate has no OpenAlex content URL")
    request_url = url + ("&" if "?" in url else "?") + urlencode({"api_key": api_key})
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
            print(f"  OpenAlex download failed ({exc}); retrying in {delay}s", flush=True)
            time.sleep(delay)

    raise RuntimeError(f"OpenAlex download failed after {MAX_RETRIES} attempts: {url}; {last_error}")


def zenodo_request(method: str, path: str, token: str, *, body=None, data=None,
                   content_type: str | None = None, timeout: int = 300):
    url = path if path.startswith("http") else ZENODO_API + path
    headers = {"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT}
    if content_type:
        headers["Content-Type"] = content_type

    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif data is not None:
        payload = data

    last_error: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = Request(url, data=payload, headers=headers, method=method)
            with urlopen(req, timeout=timeout) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except HTTPError as exc:
            last_error = exc
            if exc.code not in (429, 500, 502, 503, 504) or attempt == MAX_RETRIES:
                detail = exc.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"Zenodo HTTP {exc.code}: {detail}") from exc
            delay = min(120, 2 ** (attempt - 1) * 5)
            print(f"  Zenodo HTTP {exc.code}; retrying in {delay}s", flush=True)
            time.sleep(delay)
        except (URLError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt == MAX_RETRIES:
                break
            delay = min(120, 2 ** (attempt - 1) * 5)
            print(f"  Zenodo request failed ({exc}); retrying in {delay}s", flush=True)
            time.sleep(delay)
    raise RuntimeError(f"Zenodo request failed after {MAX_RETRIES} attempts: {last_error}")


def get_or_create_zenodo_draft(token: str, part: int, total_batches: int) -> dict:
    title = f"{ZENODO_TITLE_PREFIX} — Part {part:02d} (batches {(part-1)*10+1:02d}–{min(part*10,total_batches):02d})"
    query = urlencode({"q": title, "status": "draft", "size": 100})
    _, data = zenodo_request("GET", f"/deposit/depositions?{query}", token)
    for dep in data or []:
        if dep.get("title") == title and not dep.get("submitted", False):
            return dep

    metadata = {
        "metadata": {
            "title": title,
            "upload_type": "dataset",
            "publication_date": time.strftime("%Y-%m-%d", time.gmtime()),
            "description": (
                "Private draft storage for OpenAlex full-text files collected by "
                "the LivingEvidenceMap reproducible download pathway. Files are "
                "stored as per-batch ZIP archives and are not published by the workflow."
            ),
            "creators": [{"name": "LivingEvidenceMap"}],
            "access_right": "closed",
        }
    }
    status, dep = zenodo_request("POST", "/deposit/depositions", token, body=metadata)
    if status != 201:
        raise RuntimeError(f"Unexpected Zenodo deposition creation status: {status}")
    print(f"Created private Zenodo draft {dep['id']}: {title}", flush=True)
    return dep


def zenodo_existing_files(token: str, deposition_id: int) -> dict[str, dict]:
    _, dep = zenodo_request("GET", f"/deposit/depositions/{deposition_id}", token)
    return {f.get("key", f.get("filename", f.get("name", ""))): f for f in dep.get("files", [])}


def make_batch_zip(batch_dir: Path, batch_number: int) -> tuple[Path, str, int]:
    zip_path = batch_dir / f"openalex_fulltext_batch_{batch_number:03d}.zip"
    if not zip_path.exists() or zip_path.stat().st_size < 512:
        tmp = zip_path.with_suffix(".zip.part")
        files = sorted(
            p for p in batch_dir.iterdir()
            if p.is_file() and p.name != zip_path.name and not p.name.endswith(".part")
        )
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for path in files:
                zf.write(path, arcname=path.name)
        tmp.replace(zip_path)
    return zip_path, sha256_file(zip_path), zip_path.stat().st_size


def upload_batch_to_zenodo(token: str, deposition: dict, zip_path: Path) -> str:
    deposition_id = deposition["id"]
    filename = zip_path.name
    existing = zenodo_existing_files(token, deposition_id)
    if filename in existing:
        remote_size = int(existing[filename].get("size", 0) or 0)
        if remote_size == zip_path.stat().st_size:
            print(f"Zenodo already contains {filename}; skipping upload.", flush=True)
            return "already_present"
        raise RuntimeError(
            f"Zenodo already contains {filename} but its size ({remote_size}) differs from local "
            f"({zip_path.stat().st_size}). Refusing to overwrite automatically."
        )

    bucket = deposition.get("links", {}).get("bucket")
    if not bucket:
        raise RuntimeError("Zenodo deposition has no upload bucket URL")

    target = bucket.rstrip("/") + "/" + quote(filename)
    # urllib requires the request body to be bytes. The ZIP is bounded by one
    # 100-file OpenAlex batch and is therefore safe to stage in memory for the
    # upload; the on-disk ZIP remains the durable local checkpoint.
    with zip_path.open("rb") as fh:
        payload = fh.read()

    status, response = zenodo_request(
        "PUT", target, token, data=payload, content_type="application/zip", timeout=1800
    )
    if status not in (200, 201):
        raise RuntimeError(f"Unexpected Zenodo upload status: {status}")
    remote_size = int((response or {}).get("size", 0) or 0)
    if remote_size and remote_size != zip_path.stat().st_size:
        raise RuntimeError("Zenodo accepted the upload but reported a different file size.")
    print(f"Uploaded {filename} to Zenodo draft {deposition_id}.", flush=True)
    return "uploaded"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "openalex_fulltext")
    args = parser.parse_args()

    openalex_key = os.environ.get("OPENALEX_API_KEY", "").strip()
    zenodo_token = os.environ.get("ZENODO_ACCESS_TOKEN", "").strip()
    if not openalex_key:
        raise RuntimeError("OPENALEX_API_KEY is not set")
    if not zenodo_token:
        raise RuntimeError("ZENODO_ACCESS_TOKEN is not set")

    plan = build_plan()
    total_batches = (len(plan) + BATCH_SIZE - 1) // BATCH_SIZE
    if args.batch < 1 or args.batch > total_batches:
        raise RuntimeError(f"Batch must be between 1 and {total_batches}; got {args.batch}")

    start = (args.batch - 1) * BATCH_SIZE
    end = min(start + BATCH_SIZE, len(plan))
    batch = plan[start:end]
    part = (args.batch - 1) // BATCHES_PER_ZENODO_DEPOSITION + 1

    print(f"OpenAlex full-text plan: {len(plan)} files in {total_batches} batches", flush=True)
    print(f"Batch {args.batch}/{total_batches}: files {start + 1}-{end}", flush=True)
    print("GROBID-first; PDF-only fallback; maximum 100 OpenAlex content downloads", flush=True)
    print(f"Zenodo storage: private draft part {part}", flush=True)

    batch_dir = args.output / f"batch_{args.batch:03d}"
    batch_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = batch_dir / "download_manifest.csv"
    manifest_rows: list[dict[str, object]] = []
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
                download_openalex(row["url"], openalex_key, destination)
                if not valid_file(destination, row["format"]):
                    raise RuntimeError("Downloaded file failed format validation")
                status = "downloaded"
            except Exception as exc:
                status = "failed"
                failures.append((row, str(exc)))
                print(f"  FAILED: {exc}", flush=True)

        size = destination.stat().st_size if destination.exists() else 0
        checksum = sha256_file(destination) if status != "failed" and destination.exists() else ""
        manifest_rows.append({
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
        })
        with manifest_path.open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=manifest_rows[0].keys())
            writer.writeheader()
            writer.writerows(manifest_rows)

    if failures:
        print(f"{len(failures)} OpenAlex downloads failed; NOT uploading an incomplete batch to Zenodo.", flush=True)
        return 1

    zip_path, zip_sha256, zip_bytes = make_batch_zip(batch_dir, args.batch)
    print(f"Batch ZIP: {zip_path.name} ({zip_bytes:,} bytes; SHA-256 {zip_sha256})", flush=True)

    deposition = get_or_create_zenodo_draft(zenodo_token, part, total_batches)
    upload_status = upload_batch_to_zenodo(zenodo_token, deposition, zip_path)

    receipt = batch_dir / "zenodo_receipt.json"
    receipt.write_text(json.dumps({
        "deposition_id": deposition["id"],
        "deposition_title": deposition.get("title"),
        "batch": args.batch,
        "zip": zip_path.name,
        "zip_bytes": zip_bytes,
        "zip_sha256": zip_sha256,
        "upload_status": upload_status,
        "uploaded_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "published": False,
    }, indent=2) + "\n", encoding="utf-8")

    print("Batch completed and durably staged in private Zenodo storage.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
