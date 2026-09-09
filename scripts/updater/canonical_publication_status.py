#!/usr/bin/env python3
"""Canonical Workflow 03: publication-status screening.

Preserves every canonical JSONL record. Records that are publication notices or
whose DOI is marked retracted by OpenAlex are annotated as downstream-ineligible;
no physical deletion occurs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

NOTICE_PATTERNS = [
    ("retraction_notice", re.compile(r"^\s*(retraction(?:\s+notice)?|retracted)\s*[:\-—.]", re.I)),
    ("withdrawal_notice", re.compile(r"^\s*(withdrawn|withdrawal)\s*[:\-—.]", re.I)),
    ("correction_notice", re.compile(r"^\s*(correction|corrigendum|erratum)\s*[:\-—.]", re.I)),
]


def normalise_doi(value):
    if value is None:
        return ""
    if isinstance(value, list):
        for item in value:
            d = normalise_doi(item)
            if d:
                return d
        return ""
    if isinstance(value, dict):
        for key in ("value", "doi", "id"):
            if key in value:
                d = normalise_doi(value[key])
                if d:
                    return d
        return ""
    s = str(value).strip().lower()
    s = re.sub(r"^https?://(dx\.)?doi\.org/", "", s)
    s = re.sub(r"^doi:\s*", "", s)
    return s.strip()


def notice_type(title):
    title = str(title or "")
    for label, rx in NOTICE_PATTERNS:
        if rx.search(title):
            return label
    return None


def record_id(rec):
    return str(((rec.get("identity") or {}).get("lens_id")) or rec.get("record_id") or "")


def canonical_field(rec, key, default=None):
    return (rec.get("canonical") or {}).get(key, default)


def openalex_batch(dois, api_key, max_tries=3):
    if not dois:
        return {}
    filter_value = "doi:" + "|".join(dois)
    params = urllib.parse.urlencode({
        "filter": filter_value,
        "api_key": api_key,
        "select": "id,doi,display_name,is_retracted",
        "per-page": str(len(dois)),
    })
    url = "https://api.openalex.org/works?" + params
    last_error = None
    for attempt in range(1, max_tries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "LivingEvidenceMap/Workflow03"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            found = {}
            for work in body.get("results") or []:
                doi = normalise_doi(work.get("doi"))
                if doi:
                    found[doi] = {
                        "openalex_id": work.get("id"),
                        "openalex_title": work.get("display_name"),
                        "openalex_is_retracted": bool(work.get("is_retracted")),
                        "openalex_lookup_status": "matched",
                        "openalex_error": None,
                    }
            return found
        except Exception as exc:
            last_error = str(exc)
            if attempt < max_tries:
                time.sleep(2 ** (attempt - 1))
    raise RuntimeError(last_error or "OpenAlex batch lookup failed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--audit", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--mode", choices=("audit", "apply"), default="audit")
    ap.add_argument("--expected-records", type=int, required=True)
    ap.add_argument("--batch-size", type=int, default=25)
    args = ap.parse_args()

    api_key = os.environ.get("OPENALEX_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("OPENALEX_API_KEY was not found")

    src = Path(args.input)
    records = [json.loads(line) for line in src.open(encoding="utf-8") if line.strip()]
    if len(records) != args.expected_records:
        raise SystemExit(f"record-count mismatch: {len(records)} != {args.expected_records}")
    ids = [record_id(r) for r in records]
    if not all(ids) or len(ids) != len(set(ids)):
        raise SystemExit("missing or duplicate Lens IDs")

    eligible = []
    audits = {}
    doi_to_ids = {}
    for rec in records:
        rid = record_id(rec)
        dedup = rec.get("deduplication") or {}
        if dedup.get("downstream_eligible") is not True:
            audits[rid] = {
                "record_id": rid,
                "title": canonical_field(rec, "title", ""),
                "doi": normalise_doi(canonical_field(rec, "doi")),
                "notice_type": None,
                "openalex_id": None,
                "openalex_title": None,
                "openalex_is_retracted": False,
                "openalex_lookup_status": "not_queried_dedup_ineligible",
                "openalex_error": None,
                "remove_publication_status": False,
                "removal_reason": None,
                "downstream_eligible": False,
            }
            continue
        eligible.append(rid)
        title = canonical_field(rec, "title", "")
        doi = normalise_doi(canonical_field(rec, "doi"))
        notice = notice_type(title)
        row = {
            "record_id": rid,
            "title": title,
            "doi": doi,
            "notice_type": notice,
            "openalex_id": None,
            "openalex_title": None,
            "openalex_is_retracted": False,
            "openalex_lookup_status": "not_queried_notice" if notice else ("pending" if doi else "not_queried_no_doi"),
            "openalex_error": None,
            "remove_publication_status": bool(notice),
            "removal_reason": notice,
            "downstream_eligible": not bool(notice),
        }
        audits[rid] = row
        if not notice and doi:
            doi_to_ids.setdefault(doi, []).append(rid)

    dois = sorted(doi_to_ids)
    failed_batches = []
    for start in range(0, len(dois), args.batch_size):
        batch = dois[start:start + args.batch_size]
        batch_no = start // args.batch_size + 1
        total_batches = (len(dois) + args.batch_size - 1) // args.batch_size
        print(f"OpenAlex publication-status check: batch {batch_no}/{total_batches} ({len(batch)} DOIs)", flush=True)
        try:
            found = openalex_batch(batch, api_key)
        except Exception as exc:
            failed_batches.append({"batch": batch_no, "dois": batch, "error": str(exc)})
            for doi in batch:
                for rid in doi_to_ids[doi]:
                    audits[rid]["openalex_lookup_status"] = "failed"
                    audits[rid]["openalex_error"] = str(exc)
            continue
        for doi in batch:
            result = found.get(doi)
            for rid in doi_to_ids[doi]:
                row = audits[rid]
                if result is None:
                    row["openalex_lookup_status"] = "not_found"
                else:
                    row.update(result)
                    if result["openalex_is_retracted"]:
                        row["remove_publication_status"] = True
                        row["removal_reason"] = "retracted_original"
                        row["downstream_eligible"] = False
        time.sleep(0.05)

    out_audit = Path(args.audit)
    out_audit.parent.mkdir(parents=True, exist_ok=True)
    with out_audit.open("w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(audits[record_id(rec)], ensure_ascii=False) + "\n")

    checked_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    eligible_rows = [audits[rid] for rid in eligible]
    summary = {
        "workflow": "fresh_rebuild_03_publication_status",
        "mode": args.mode,
        "checked_at": checked_at,
        "input_records": len(records),
        "dedup_downstream_eligible_records": len(eligible),
        "unique_dois_queried": len(dois),
        "publication_notices": sum(bool(r["notice_type"]) for r in eligible_rows),
        "openalex_retracted_originals": sum(r["removal_reason"] == "retracted_original" for r in eligible_rows),
        "publication_status_excluded": sum(r["remove_publication_status"] for r in eligible_rows),
        "openalex_not_found": sum(r["openalex_lookup_status"] == "not_found" for r in eligible_rows),
        "openalex_failed_records": sum(r["openalex_lookup_status"] == "failed" for r in eligible_rows),
        "failed_batches": failed_batches,
        "records_removed": 0,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if failed_batches:
        print(json.dumps(summary, indent=2), file=sys.stderr)
        raise SystemExit("OpenAlex technical failures detected; publication-status stage cannot be cleared")

    if args.mode == "apply":
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w", encoding="utf-8") as f:
            for rec in records:
                rid = record_id(rec)
                row = audits[rid]
                if (rec.get("deduplication") or {}).get("downstream_eligible") is True:
                    rec["publication_status"] = {
                        "status": "excluded" if row["remove_publication_status"] else "cleared",
                        "reason": row["removal_reason"],
                        "notice_type": row["notice_type"],
                        "doi_for_lookup": row["doi"],
                        "openalex_id": row["openalex_id"],
                        "openalex_is_retracted": row["openalex_is_retracted"],
                        "openalex_lookup_status": row["openalex_lookup_status"],
                        "downstream_eligible": row["downstream_eligible"],
                        "checked_at": checked_at,
                    }
                else:
                    rec["publication_status"] = {
                        "status": "not_applicable_dedup_ineligible",
                        "reason": None,
                        "downstream_eligible": False,
                        "checked_at": checked_at,
                    }
                f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    else:
        Path(args.output).write_text("", encoding="utf-8")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
