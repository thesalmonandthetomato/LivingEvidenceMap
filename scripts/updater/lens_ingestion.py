#!/usr/bin/env python3
"""Workflow 01: lossless, checkpointed Lens ingestion.

This remains independent of the existing production updater.  A run writes
immutable raw response batches, canonical JSONL records, and a checkpoint.
The successful-search state is deliberately not modified here.
"""
from __future__ import annotations

import argparse
import copy
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
CHECKPOINT_VERSION = 1


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--start-date", required=True)
    p.add_argument("--end-date", required=True)
    p.add_argument("--max-records", type=int, default=100)
    p.add_argument("--output-dir", default="outputs/updater/lens_ingestion_test")
    p.add_argument("--query-file", default="config/lens_search.json")
    p.add_argument("--resume", action="store_true")
    p.add_argument("--fail-after-batch", type=int, default=0, help="Test hook: fail after writing this batch.")
    return p.parse_args()


def load_query(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def build_query(template: dict[str, Any], start: str, end: str) -> dict[str, Any]:
    api_cfg = template.get("api_query", {})
    base_query = copy.deepcopy(api_cfg.get("query"))
    if not isinstance(base_query, dict):
        raise ValueError("config/lens_search.json must contain api_query.query")
    bool_query = base_query.setdefault("bool", {})
    filters = bool_query.setdefault("filter", [])
    filters.append({"range": {"created": {"gte": start, "lte": end}}})
    configured_size = api_cfg.get("size", PAGE_SIZE)
    try:
        configured_size = int(configured_size)
    except (TypeError, ValueError):
        configured_size = PAGE_SIZE
    return {"query": base_query, "size": min(PAGE_SIZE, max(1, configured_size)), "scroll": SCROLL}


def request_with_retry(session: requests.Session, url: str, headers: dict[str, str], payload: dict[str, Any]) -> dict[str, Any]:
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            response = session.post(url, headers=headers, json=payload, timeout=120)
        except requests.RequestException as exc:
            last_error = exc
            if attempt == 4:
                break
            time.sleep(min(60, 2 ** attempt))
            continue
        if response.status_code == 200:
            return response.json()
        if response.status_code == 429 or 500 <= response.status_code < 600:
            last_error = RuntimeError(f"Lens API HTTP {response.status_code}: {response.text[:1000]}")
            if attempt < 4:
                retry_after = response.headers.get("Retry-After")
                try:
                    delay = float(retry_after) if retry_after else min(60, 2 ** attempt)
                except ValueError:
                    delay = min(60, 2 ** attempt)
                time.sleep(delay)
                continue
            break
        raise RuntimeError(f"Lens API HTTP {response.status_code}: {response.text[:1000]}")
    raise RuntimeError(f"Lens API request failed after retries: {last_error}")


def write_jsonl_record(handle: Any, record: dict[str, Any]) -> None:
    handle.write(json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n")


def save_checkpoint(path: Path, state: dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_checkpoint(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise RuntimeError(f"Cannot resume: checkpoint not found at {path}")
    state = json.loads(path.read_text(encoding="utf-8"))
    if state.get("checkpoint_version") != CHECKPOINT_VERSION:
        raise RuntimeError("Unsupported checkpoint version")
    return state


def main() -> int:
    args = parse_args()
    if args.max_records < 1:
        raise ValueError("--max-records must be at least 1")
    if args.fail_after_batch < 0:
        raise ValueError("--fail-after-batch cannot be negative")

    token = os.environ.get("LENS_API_TOKEN")
    if not token:
        raise RuntimeError("LENS_API_TOKEN is required")

    root = Path(args.output_dir)
    raw_dir = root / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    canonical_path = root / "records.jsonl"
    manifest_path = root / "manifest.json"
    checkpoint_path = root / "checkpoint.json"

    template = load_query(Path(args.query_file))
    payload = build_query(template, args.start_date, args.end_date)
    payload["size"] = min(payload["size"], args.max_records)

    url = os.environ.get("LENS_API_URL", DEFAULT_BASE_URL)
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json"}

    if args.resume:
        checkpoint = load_checkpoint(checkpoint_path)
        if checkpoint["search_window"] != {"start": args.start_date, "end": args.end_date} or checkpoint["max_records"] != args.max_records:
            raise RuntimeError("Resume parameters do not match checkpoint")
        run_id = checkpoint["run_id"]
        total = checkpoint.get("lens_reported_total")
        records_retrieved = checkpoint["records_retrieved"]
        batches = checkpoint["batches"]
        seen = set(checkpoint.get("seen_lens_ids", []))
        scroll_id = checkpoint.get("scroll_id")
        if not scroll_id:
            raise RuntimeError("Checkpoint has no scroll_id; cannot resume")
        next_batch = batches + 1
        mode = "resume"
    else:
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        total = None
        records_retrieved = 0
        batches = 0
        seen: set[str] = set()
        scroll_id = None
        next_batch = 1
        mode = "initial"
        if canonical_path.exists():
            canonical_path.unlink()
        if checkpoint_path.exists():
            checkpoint_path.unlink()

    manifest: dict[str, Any] = {
        "workflow": "01_lens_ingestion",
        "status": "running",
        "mode": mode,
        "run_id": run_id,
        "started_at": iso_now(),
        "search_window": {"start": args.start_date, "end": args.end_date},
        "max_records": args.max_records,
        "page_size": payload["size"],
        "scroll": SCROLL,
        "source": "lens",
        "full_record_request": True,
        "records_retrieved": records_retrieved,
        "batches": batches,
        "records_without_lens_id": 0,
    }

    session = requests.Session()
    if mode == "initial":
        first = request_with_retry(session, url, headers, payload)
        total = first.get("total")
        records = first.get("data", []) or []
        scroll_id = first.get("scroll_id")
        manifest["lens_reported_total"] = total
    else:
        response = request_with_retry(session, url, headers, {"scroll_id": scroll_id, "scroll": SCROLL})
        records = response.get("data", []) or []
        scroll_id = response.get("scroll_id", scroll_id)
        manifest["lens_reported_total"] = total

    append_mode = "a" if args.resume else "w"
    with canonical_path.open(append_mode, encoding="utf-8", newline="") as out:
        batch = next_batch
        while records and records_retrieved < args.max_records:
            records = records[: args.max_records - records_retrieved]
            raw_path = raw_dir / f"response_{batch:06d}.json"
            raw_path.write_text(json.dumps({"data": records, "scroll_id": scroll_id}, ensure_ascii=False, indent=2), encoding="utf-8")

            for record in records:
                lens_id = record.get("lens_id")
                if not lens_id:
                    manifest["records_without_lens_id"] += 1
                    continue
                if lens_id in seen:
                    continue
                seen.add(lens_id)
                write_jsonl_record(out, {
                    "identity": {"lens_id": lens_id, "record_id": lens_id, "record_id_type": "lens_id"},
                    "source": {"provider": "lens", "source_format": "lens_api_json"},
                    "lens": {"raw_payload": record},
                    "provenance": {"ingestion_run_id": run_id, "retrieved_at": iso_now(), "batch": batch},
                })

            out.flush()
            records_retrieved += len(records)
            batches = batch
            checkpoint = {
                "checkpoint_version": CHECKPOINT_VERSION,
                "run_id": run_id,
                "search_window": {"start": args.start_date, "end": args.end_date},
                "max_records": args.max_records,
                "records_retrieved": records_retrieved,
                "batches": batches,
                "seen_lens_ids": sorted(seen),
                "scroll_id": scroll_id,
                "lens_reported_total": total,
                "updated_at": iso_now(),
            }
            save_checkpoint(checkpoint_path, checkpoint)

            if args.fail_after_batch and batch == args.fail_after_batch:
                manifest.update({"status": "failed_test", "records_retrieved": records_retrieved, "batches": batches})
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
                raise RuntimeError(f"Intentional test failure after batch {batch}; checkpoint saved")

            if not scroll_id or len(records) < payload["size"] or records_retrieved >= args.max_records:
                break

            response = request_with_retry(session, url, headers, {"scroll_id": scroll_id, "scroll": SCROLL})
            records = response.get("data", []) or []
            scroll_id = response.get("scroll_id", scroll_id)
            batch += 1

    manifest.update({
        "records_retrieved": records_retrieved,
        "records_unique": len(seen),
        "batches": batches,
        "completed_at": iso_now(),
        "status": "success",
    })
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
