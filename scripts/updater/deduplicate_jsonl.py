#!/usr/bin/env python3
"""Workflow 02: conservative JSONL deduplication prototype.

`lens_id` identifies the Lens record and is not itself a bibliographic
duplicate decision. DOI is only supporting evidence and can never by itself
cause a duplicate decision. The implementation preserves every input record
and adds a deduplication decision/audit object rather than deleting records.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path
from typing import Any


def norm(value: Any) -> str:
    if value is None:
        return ""
    s = unicodedata.normalize("NFKC", str(value)).casefold()
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def payload(record: dict[str, Any]) -> dict[str, Any]:
    p = record.get("lens", {}).get("raw_payload", {})
    if not isinstance(p, dict):
        raise RuntimeError("Record lens.raw_payload is not an object")
    return p


def extract_dois(record: dict[str, Any]) -> list[str]:
    ids = payload(record).get("external_ids") or []
    values: list[str] = []
    if not isinstance(ids, list):
        return values
    for item in ids:
        if not isinstance(item, dict):
            continue
        if norm(item.get("type")) != "doi":
            continue
        value = norm(item.get("value"))
        value = re.sub(r"^https?://doi\.org/", "", value)
        if value:
            values.append(value)
    return sorted(set(values))


def title_key(record: dict[str, Any]) -> str:
    return norm(payload(record).get("title"))


def year_key(record: dict[str, Any]) -> str:
    p = payload(record)
    value = p.get("year_published")
    if value is None:
        value = p.get("date_published")
    return norm(value)


def source_key(record: dict[str, Any]) -> str:
    source = payload(record).get("source") or {}
    if isinstance(source, dict):
        return norm(source.get("title"))
    return norm(source)


def authors_key(record: dict[str, Any]) -> str:
    authors = payload(record).get("authors") or []
    if not isinstance(authors, list):
        return ""
    names = []
    for author in authors[:5]:
        if not isinstance(author, dict):
            names.append(norm(author))
            continue
        last = norm(author.get("last_name"))
        first = norm(author.get("first_name"))
        names.append(" ".join(x for x in (last, first) if x))
    return "|".join(x for x in names if x)


def bibliographic_signature(record: dict[str, Any]) -> str | None:
    parts = [title_key(record), year_key(record), source_key(record), authors_key(record)]
    if not all(parts):
        return None
    return hashlib.sha256("\x1f".join(parts).encode()).hexdigest()


def load_records(path: Path) -> list[dict[str, Any]]:
    records = []
    with path.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"Invalid JSONL at line {line_no}: {exc}") from exc
    return records


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--audit", required=True)
    args = ap.parse_args()

    records = load_records(Path(args.input))
    seen_lens: dict[str, str] = {}
    seen_strong: dict[str, str] = {}
    output = []
    audit = []

    for record in records:
        identity = record.setdefault("identity", {})
        lens_id = identity.get("lens_id")
        if not lens_id:
            raise RuntimeError("Record has no lens_id; Workflow 02 requires authoritative Lens identity")

        result = json.loads(json.dumps(record, ensure_ascii=False))
        dois = extract_dois(result)
        signature = bibliographic_signature(result)
        dedup: dict[str, Any] = {
            "status": "unique",
            "decision_source": "deterministic",
            "doi_supporting": bool(dois),
        }

        if lens_id in seen_lens:
            dedup = {
                "status": "identity_match",
                "duplicate_of": seen_lens[lens_id],
                "decision_source": "lens_id",
                "doi_supporting": bool(dois),
            }
        elif signature and signature in seen_strong:
            dedup = {
                "status": "duplicate_candidate",
                "duplicate_of": seen_strong[signature],
                "decision_source": "bibliographic_signature",
                "doi_supporting": bool(dois),
            }
        elif signature:
            seen_strong[signature] = lens_id

        result["deduplication"] = dedup
        output.append(result)
        audit.append({"lens_id": lens_id, **dedup})
        seen_lens.setdefault(lens_id, lens_id)

    Path(args.output).write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in output), encoding="utf-8")
    Path(args.audit).write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in audit), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
