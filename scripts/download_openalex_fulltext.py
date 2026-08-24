#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
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
USER_AGENT = "LivingEvidenceMap/OpenAlex-fulltext/2.5"
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
        if row.get("doi_exact_match") == "TRUE" and row.get("has_pdf") == "TRUE" and doi.lower() not in grobid_dois:
            pdf_only_rows.append({
                "doi": doi,
                "openalex_id": row["openalex_id"].rstrip("/").split("/")[-1],
                "url": row.get("pdf_url", ""),
                "format": "pdf",
            })
    plan = grobid_rows + pdf_only_rows
    if not plan:
        raise RuntimeError("No OpenAlex candidates found.")
    if len(plan) != len(set(r["doi"].lower() for r in plan)):
        raise RuntimeError("The download plan contains duplicate DOIs.")
    return plan


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def validate_content(path: Path, fmt: str) -> tuple[bool, str]:
    if not path.exists() or path.stat().st_size < 512:
        return False, "file missing or <512 bytes"
    with path.open("rb") as fh:
        head = fh.read(65536)
    if fmt == "pdf":
        return head.startswith(b"%PDF"), "PDF magic bytes not found"
    text = head.decode("utf-8", errors="ignore")
    lower = text.lower()
    if "<tei" in lower or "<tei:" in lower or "<teiheader" in lower:
        return True, ""
    preview = " ".join(text[:500].split())
    return False, f"no TEI marker in first 64 KiB; body preview={preview!r}"


def download_openalex(url: str, api_key: str, destination: Path, fmt: str) -> None:
    if not url:
        raise RuntimeError("Candidate has no OpenAlex content URL")
    request_url = url + ("&" if "?" in url else "?") + urlencode({"api_key": api_key})
    tmp = destination.with_suffix(destination.suffix + ".part")
    last_error: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = Request(request_url, headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/xml,text/xml,application/pdf,*/*",
                "Accept-Encoding": "gzip",
            })
            with urlopen(req, timeout=TIMEOUT) as response:
                status = getattr(response, "status", None)
                content_type = response.headers.get("Content-Type", "")
                content_encoding = response.headers.get("Content-Encoding", "").lower()
                body = response.read()
            if content_encoding == "gzip" or body[:2] == b"\x1f\x8b" or content_type.lower().startswith("application/gzip"):
                body = gzip.decompress(body)
            tmp.write_bytes(body)
            tmp.replace(destination)
            ok, reason = validate_content(destination, fmt)
            if not ok:
                raise RuntimeError(
                    f"Downloaded content failed {fmt} validation; HTTP {status}; Content-Type={content_type!r}; {reason}"
                )
            return
        except HTTPError as exc:
            last_error = exc
            body = exc.read().decode("utf-8", errors="replace")
            print(f"  OpenAlex HTTP {exc.code}; body preview: {' '.join(body[:300].split())}", flush=True)
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            if exc.code in (401, 403):
                raise RuntimeError(f"OpenAlex HTTP {exc.code}: authentication/access denied") from exc
            if exc.code == 429 or 500 <= exc.code < 600:
                if attempt == MAX_RETRIES:
                    break
                delay = min(120, 2 ** (attempt - 1) * 5)
                print(f"  retrying in {delay}s", flush=True)
                time.sleep(delay)
                continue
            raise RuntimeError(f"OpenAlex HTTP {exc.code}: {body[:500]}") from exc
        except (URLError, TimeoutError, OSError, RuntimeError) as exc:
            last_error = exc
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            if attempt == MAX_RETRIES:
                break
            delay = min(60, 2 ** (attempt - 1) * 2)
            print(f"  OpenAlex download/validation failed ({exc}); retrying in {delay}s", flush=True)
            time.sleep(delay)
    raise RuntimeError(f"OpenAlex download failed after {MAX_RETRIES} attempts: {url}; {last_error}")


def zenodo_request(method: str, path: str, token: str, *, body=None, data=None, content_type=None, timeout=300):
    url = path if path.startswith("http") else ZENODO_API + path
    headers = {"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT}
    if content_type:
        headers["Content-Type"] = content_type
    payload = json.dumps(body).encode("utf-8") if body is not None else data
    if body is not None:
        headers["Content-Type"] = "application/json"
    last_error = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = Request(url, data=payload, headers=headers, method=method)
            with urlopen(req, timeout=timeout) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except HTTPError as exc:
            last_error = exc
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code not in (429, 500, 502, 503, 504) or attempt == MAX_RETRIES:
                raise RuntimeError(f"Zenodo HTTP {exc.code}: {detail}") from exc
            time.sleep(min(120, 2 ** (attempt - 1) * 5))
        except (URLError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt == MAX_RETRIES:
                break
            time.sleep(min(120, 2 ** (attempt - 1) * 5))
    raise RuntimeError(f"Zenodo request failed after {MAX_RETRIES} attempts: {last_error}")


def get_or_create_zenodo_draft(token: str, part: int, total_batches: int) -> dict:
    title = f"{ZENODO_TITLE_PREFIX} — Part {part:02d} (batches {(part-1)*10+1:02d}–{min(part*10,total_batches):02d})"
    query = urlencode({"q": title, "status": "draft", "size": 100})
    _, data = zenodo_request("GET", f"/deposit/depositions?{query}", token)
    for dep in data or []:
        if dep.get("title") == title and not dep.get("submitted", False):
            return dep
    metadata = {"metadata": {"title": title, "upload_type": "dataset", "publication_date": time.strftime("%Y-%m-%d", time.gmtime()), "description": "Private draft storage for OpenAlex full-text files collected by the LivingEvidenceMap reproducible download pathway.", "creators": [{"name": "LivingEvidenceMap"}], "access_right": "closed"}}
    status, dep = zenodo_request("POST", "/deposit/depositions", token, body=metadata)
    if status != 201:
        raise RuntimeError(f"Unexpected Zenodo deposition creation status: {status}")
    return dep


def zenodo_existing_files(token: str, deposition_id: int) -> dict[str, dict]:
    _, dep = zenodo_request("GET", f"/deposit/depositions/{deposition_id}", token)
    return {f.get("key", f.get("filename", f.get("name", ""))): f for f in dep.get("files", [])}


def make_batch_zip(batch_dir: Path, batch_number: int) -> tuple[Path, str, int]:
    zip_path = batch_dir / f"openalex_fulltext_batch_{batch_number:03d}.zip"
    tmp = zip_path.with_suffix(".zip.part")
    files = [
        p for p in batch_dir.iterdir()
        if p.is_file() and p.name != zip_path.name and not p.name.endswith(".part") and not p.name.endswith(".zip")
    ]
    if not files:
        raise RuntimeError("Cannot create batch ZIP: no downloaded files are present.")
    if any(p.stat().st_size == 0 for p in files):
        raise RuntimeError("Cannot create batch ZIP: at least one downloaded file is empty.")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(files):
            zf.write(path, arcname=path.name)
    if not tmp.exists() or tmp.stat().st_size < 512:
        raise RuntimeError("Batch ZIP creation failed or produced an empty ZIP.")
    tmp.replace(zip_path)
    return zip_path, sha256_file(zip_path), zip_path.stat().st_size


def upload_batch_to_zenodo(token: str, deposition: dict, zip_path: Path) -> str:
    deposition_id = deposition["id"]
    filename = zip_path.name
    existing = zenodo_existing_files(token, deposition_id)
    if filename in existing:
        remote_size = int(existing[filename].get("size", 0) or 0)
        if remote_size == zip_path.stat().st_size:
            return "already_present"
        raise RuntimeError(f"Zenodo already contains {filename} with different size")
    bucket = deposition.get("links", {}).get("bucket")
    if not bucket:
        raise RuntimeError("Zenodo deposition has no upload bucket URL")
    target = bucket.rstrip("/") + "/" + quote(filename)
    payload = zip_path.read_bytes()
    if not payload:
        raise RuntimeError("Refusing to upload empty batch ZIP.")
    status, response = zenodo_request("PUT", target, token, data=payload, content_type="application/octet-stream", timeout=1800)
    if status not in (200, 201):
        raise RuntimeError(f"Unexpected Zenodo upload status: {status}")
    remote_size = int((response or {}).get("size", 0) or 0)
    if remote_size and remote_size != zip_path.stat().st_size:
        raise RuntimeError("Zenodo reported a different file size")
    return "uploaded"


def write_manifest(batch_dir: Path, rows: list[dict]) -> None:
    manifest_path = batch_dir / "download_manifest.csv"
    fields = ["batch", "batch_position", "doi", "openalex_id", "format", "url", "status", "bytes", "sha256", "file"]
    with manifest_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def batch_context(plan: list[dict[str, str]], batch_number: int):
    total_batches = (len(plan) + BATCH_SIZE - 1) // BATCH_SIZE
    if batch_number < 1 or batch_number > total_batches:
        raise RuntimeError(f"Batch must be between 1 and {total_batches}; got {batch_number}")
    start = (batch_number - 1) * BATCH_SIZE
    end = min(start + BATCH_SIZE, len(plan))
    return total_batches, start, end, plan[start:end], (batch_number - 1) // BATCHES_PER_ZENODO_DEPOSITION + 1


def download_batch(plan, batch_number: int, batch_dir: Path) -> int:
    _, start, _, batch, _ = batch_context(plan, batch_number)
    manifest_rows = []
    failures = []
    for i, row in enumerate(batch, start=start + 1):
        ext = ".tei.xml" if row["format"] == "grobid_xml" else ".pdf"
        destination = batch_dir / f"{row['openalex_id']}{ext}"
        existing_valid, _ = validate_content(destination, row["format"])
        if existing_valid:
            status = "already_present"
            print(f"[{i}/{len(plan)}] SKIP {row['openalex_id']} ({row['format']})", flush=True)
        else:
            print(f"[{i}/{len(plan)}] DOWNLOAD {row['openalex_id']} ({row['format']})", flush=True)
            try:
                download_openalex(row["url"], os.environ["OPENALEX_API_KEY"], destination, row["format"])
                status = "downloaded"
            except Exception as exc:
                status = "failed"
                failures.append((row, str(exc)))
                print(f"  FAILED: {exc}", flush=True)
        size = destination.stat().st_size if destination.exists() else 0
        checksum = sha256_file(destination) if status != "failed" and destination.exists() else ""
        manifest_rows.append({"batch": batch_number, "batch_position": i, "doi": row["doi"], "openalex_id": row["openalex_id"], "format": row["format"], "url": row["url"], "status": status, "bytes": size, "sha256": checksum, "file": destination.name if destination.exists() else ""})
        write_manifest(batch_dir, manifest_rows)
    if failures:
        print(f"{len(failures)} OpenAlex downloads failed; checkpoint this partial batch and do not contact Zenodo.", flush=True)
        return 1
    return 0


def zenodo_batch(plan, batch_number: int, batch_dir: Path) -> int:
    total_batches, _, _, batch, part = batch_context(plan, batch_number)
    for row in batch:
        ext = ".tei.xml" if row["format"] == "grobid_xml" else ".pdf"
        destination = batch_dir / f"{row['openalex_id']}{ext}"
        ok, reason = validate_content(destination, row["format"])
        if not ok:
            raise RuntimeError(f"Checkpoint incomplete: {destination.name}: {reason}")
    zip_path, zip_sha256, zip_bytes = make_batch_zip(batch_dir, batch_number)
    print(f"Batch ZIP created: {zip_path.name} ({zip_bytes:,} bytes; SHA-256 {zip_sha256})", flush=True)
    deposition = get_or_create_zenodo_draft(os.environ["ZENODO_ACCESS_TOKEN"], part, total_batches)
    upload_status = upload_batch_to_zenodo(os.environ["ZENODO_ACCESS_TOKEN"], deposition, zip_path)
    receipt = {"deposition_id": deposition["id"], "deposition_title": deposition.get("title"), "batch": batch_number, "zip": zip_path.name, "zip_bytes": zip_bytes, "zip_sha256": zip_sha256, "upload_status": upload_status, "uploaded_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "published": False}
    (batch_dir / "zenodo_receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("Batch completed and durably staged in private Zenodo storage.", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "openalex_fulltext")
    parser.add_argument("--mode", choices=["download", "zenodo"], default="download")
    args = parser.parse_args()
    if not os.environ.get("OPENALEX_API_KEY", "").strip():
        raise RuntimeError("OPENALEX_API_KEY is not set")
    if not os.environ.get("ZENODO_ACCESS_TOKEN", "").strip():
        raise RuntimeError("ZENODO_ACCESS_TOKEN is not set")
    plan = build_plan()
    total_batches, start, end, _, part = batch_context(plan, args.batch)
    batch_dir = args.output / f"batch_{args.batch}"
    batch_dir.mkdir(parents=True, exist_ok=True)
    print(f"OpenAlex full-text plan: {len(plan)} files in {total_batches} batches", flush=True)
    print(f"Batch {args.batch}/{total_batches}: files {start + 1}-{end}", flush=True)
    print("GROBID-first; PDF-only fallback; maximum 100 OpenAlex content downloads", flush=True)
    print(f"Zenodo storage: private draft part {part}", flush=True)
    if args.mode == "download":
        return download_batch(plan, args.batch, batch_dir)
    return zenodo_batch(plan, args.batch, batch_dir)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
