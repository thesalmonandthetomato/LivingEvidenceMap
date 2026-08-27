#!/usr/bin/env python3
"""Workflow 01: lossless Lens ingestion prototype.

This is intentionally independent of the existing production updater.
It resolves an explicit search window, retrieves full Lens records, writes
immutable raw response batches plus canonical JSONL records, and records a
run manifest. The production search state is never modified by this script.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

PAGE_SIZE = 500
SCROLL = "1m"
DEFAULT_BASE_URL = "https://api.lens.org/scholarly/search"


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--start-date", required=True)
    p.add_argument("--end-date", required=True)
    p.add_argument("--max-records", type=int, default=100)
    p.add_argument("--output-dir", default="outputs/updater/lens_ingestion_test")
    p.add_argument("--query-file", default="config/lens_search.json")
    return p.parse_args()


def load_query(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def build_query(template: dict[str, Any], start: str, end: str) -> dict[str, Any]:
    query = json.loads(json.dumps(template))
    query["query"]["bool"]["must"][0]["range"]["created"]["gte"] = start
    query["query"]["bool"]["must"][0]["range"]["created"]["lte"] = end
    return query


def request_with_retry(session: requests.Session, url: str, headers: dict[str, str], payload: dict[str, Any]) -> dict[str, Any]:
    for attempt in range(5):
        r = session.post(url, headers=headers, json=payload, timeout=120)
        if r.status_code == 200:
            return r.json()
        if r.status_code == 429 or 500 <= r.status_code < 600:
            retry_after = r.headers.get("Retry-After")
            delay = float(retry_after) if retry_after and retry_after.replace('.', '', 1).isdigit() else min(60, 2 ** attempt)
            time.sleep(delay)
            continue
        raise RuntimeError(f"Lens API HTTP {r.status_code}: {r.text[:1000]}")
    raise RuntimeError("Lens API failed after retries")


def main() -> int:
    args = parse_args()
    token = os.environ.get("LENS_API_TOKEN")
    if not token:
        raise RuntimeError("LENS_API_TOKEN is required")

    root = Path(args.output_dir)
    raw_dir = root / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    canonical_path = root / "records.jsonl"
    manifest_path = root / "manifest.json"

    template = load_query(Path(args.query_file))
    payload = build_query(template, args.start_date, args.end_date)
    payload["size"] = min(PAGE_SIZE, args.max_records)
    payload.pop("include", None)
    payload.pop("exclude", None)

    url = os.environ.get("LENS_API_URL", DEFAULT_BASE_URL)
    headers = {"Authorization": token, "Content-Type": "application/json"}
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    manifest: dict[str, Any] = {
        "workflow": "01_lens_ingestion",
        "status": "running",
        "run_id": run_id,
        "started_at": iso_now(),
        "search_window": {"start": args.start_date, "end": args.end_date},
        "max_records": args.max_records,
        "page_size": payload["size"],
        "scroll": SCROLL,
        "source": "lens",
        "full_record_request": True,
        "records_retrieved": 0,
        "batches": 0,
    }

    session = requests.Session()
    first = request_with_retry(session, url, headers, {**payload, "scroll_id": None})
    total = first.get("total", first.get("totalHits"))
    manifest["lens_reported_total"] = total

    records: list[dict[str, Any]] = first.get("data", first.get("results", [])) or []
    scroll_id = first.get("scroll_id")
    batch = 1
    seen: set[str] = set()

    with canonical_path.open("w", encoding="utf-8") as out:
        while records and manifest["records_retrieved"] < args.max_records:
            records = records[: args.max_records - manifest["records_retrieved"]]
            raw_path = raw_dir / f"response_{batch:06d}.json"
            raw_path.write_text(json.dumps({"data": records, "scroll_id": scroll_id}, ensure_ascii=False, indent=2), encoding="utf-8")

            for record in records:
                lens_id = record.get("lens_id")
                if not lens_id or lens_id in seen:
                    continue
                seen.add(lens_id)
                canonical = {
                    "identity": {"lens_id": lens_id, "record_id": lens_id, "record_id_type": "lens_id"},
                    "lens": {"raw_payload": record},
                    "provenance": {
                        "source": "lens",
                        "ingestion_run_id": run_id,
                        "retrieved_at": iso_now(),
                        "batch": batch,
                    },
                }
                out.write(json.dumps(canonical, ensure_ascii=False, separators=(",", ":")) + "\n")

            manifest["records_retrieved"] += len(records)
            manifest["batches"] = batch
            if not scroll_id or len(records) < payload["size"] or manifest["records_retrieved"] >= args.max_records:
                break
            response = request_with_retry(session, url, headers, {"scroll_id": scroll_id, "scroll": SCROLL})
            records = response.get("data", response.get("results", [])) or []
            scroll_id = response.get("scroll_id", scroll_id)
            batch += 1

    manifest["records_unique"] = len(seen)
    manifest["completed_at"] = iso_now()
    manifest["status"] = "success"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
