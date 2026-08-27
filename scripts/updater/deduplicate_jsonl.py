#!/usr/bin/env python3
"""Workflow 02: conservative JSONL deduplication prototype.

Identity (lens_id) and bibliographic duplicate status are deliberately kept
separate. DOI is only a supporting signal and is never sufficient by itself.
This prototype is bounded to deterministic matching; LLM adjudication will be
added only after deterministic behaviour is tested.
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
    s = re.sub(r"\s+", " ", s).strip()
    return s


def title_key(record: dict[str, Any]) -> str:
    p = record.get("lens", {}).get("raw_payload", {})
    return norm(p.get("title"))


def doi_key(record: dict[str, Any]) -> str:
    p = record.get("lens", {}).get("raw_payload", {})
    doi = p.get("doi")
    if isinstance(doi, list):
        doi = doi[0] if doi else ""
    return norm(doi).removeprefix("https://doi.org/").removeprefix("http://doi.org/")


def authors_key(record: dict[str, Any]) -> str:
    p = record.get("lens", {}).get("raw_payload", {})
    authors = p.get("authors") or []
    names = []
    for a in authors[:5]:
        if isinstance(a, dict):
            names.append(norm(a.get("last_name") or a.get("name") or a.get("given_name")))
        else:
            names.append(norm(a))
    return "|".join(x for x in names if x)


def bibliographic_signature(record: dict[str, Any]) -> str:
    p = record.get("lens", {}).get("raw_payload", {})
    parts = [title_key(record), norm(p.get("year_published")), norm(p.get("source_title")), authors_key(record)]
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

        result = dict(record)
        dedup: dict[str, Any] = {"status": "unique", "decision_source": "deterministic"}

        if lens_id in seen_lens:
            dedup = {
                "status": "identity_match",
                "duplicate_of": seen_lens[lens_id],
                "decision_source": "lens_id",
            }
        else:
            signature = bibliographic_signature(record)
            doi = doi_key(record)
            # DOI is only a candidate/supporting signal. It is deliberately
            # never sufficient to declare a duplicate on its own.
            if signature and signature in seen_strong:
                dedup = {
                    "status": "duplicate_candidate",
                    "duplicate_of": seen_strong[signature],
                    "decision_source": "bibliographic_signature",
                    "doi_supporting_signal": bool(doi),
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
