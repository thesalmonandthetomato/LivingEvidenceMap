#!/usr/bin/env python3
"""Workflow 02: JSON-native staged bibliographic deduplication.

Rules are ported from R/relevance_screening.R. Lens identity and bibliographic
identity remain separate. DOI is supporting evidence only and is never, by
itself, a duplicate decision. Every input record is preserved and annotated
with the deterministic match result.
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

FUZZY_THRESHOLD = 0.965
PROBABLE_THRESHOLD = 0.985
DOI_TITLE_COMPATIBILITY_THRESHOLD = 0.90


def norm(value: Any) -> str:
    if value is None:
        return ""
    s = unicodedata.normalize("NFKD", str(value)).casefold()
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
    if not isinstance(ids, list):
        return []
    out: list[str] = []
    for item in ids:
        if not isinstance(item, dict) or norm(item.get("type")) != "doi":
            continue
        value = norm(item.get("value"))
        value = re.sub(r"^https?://(?:dx\.)?doi\.org/", "", value)
        value = re.sub(r"^doi:\s*", "", value)
        if value:
            out.append(value)
    return sorted(set(out))


def title_key(record: dict[str, Any]) -> str:
    return norm(payload(record).get("title"))


def year_key(record: dict[str, Any]) -> str:
    p = payload(record)
    return norm(p.get("year_published") if p.get("year_published") is not None else p.get("date_published"))


def source_key(record: dict[str, Any]) -> str:
    source = payload(record).get("source") or {}
    return norm(source.get("title") if isinstance(source, dict) else source)


def authors_key(record: dict[str, Any]) -> str:
    authors = payload(record).get("authors") or []
    if not isinstance(authors, list):
        return ""
    names = []
    for author in authors[:5]:
        if isinstance(author, dict):
            last = norm(author.get("last_name"))
            first = norm(author.get("first_name"))
            names.append(" ".join(x for x in (last, first) if x))
        else:
            names.append(norm(author))
    return "|".join(x for x in names if x)


def first_author_key(record: dict[str, Any]) -> str:
    authors = payload(record).get("authors") or []
    if not isinstance(authors, list) or not authors:
        return ""
    author = authors[0]
    if isinstance(author, dict):
        return norm(author.get("last_name") or author.get("name") or author.get("first_name"))
    return norm(author)


def title_prefix(record: dict[str, Any]) -> str:
    return title_key(record)[:24]


def title_token_key(record: dict[str, Any]) -> str:
    tokens = [t for t in re.split(r"\s+", title_key(record)) if t]
    return " ".join(sorted(set(tokens[:8])))


def title_similarity(a: str, b: str) -> float:
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


def prepared(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "lens_id": str(record.get("identity", {}).get("lens_id") or payload(record).get("lens_id") or ""),
        "record_id": str(record.get("identity", {}).get("record_id") or record.get("record_id") or ""),
        "title": payload(record).get("title") or "",
        "title_key": title_key(record),
        "doi_keys": extract_dois(record),
        "year_key": year_key(record),
        "source_key": source_key(record),
        "first_author_key": first_author_key(record),
        "title_prefix": title_prefix(record),
        "title_token_key": title_token_key(record),
    }


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


def best_candidate(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not candidates:
        return None
    return sorted(candidates, key=lambda x: (x["priority"], -x["title_similarity"]))[0]


def match_record(inc: dict[str, Any], master: list[dict[str, Any]]) -> dict[str, Any] | None:
    # 1. Exact normalized title, identical to the legacy highest-priority rule.
    exact = [
        m for m in master
        if inc["title_key"] and m["title_key"] == inc["title_key"]
    ]
    if exact:
        m = exact[0]
        return {
            "status": "duplicate",
            "basis": "exact normalised title",
            "matched_master_record_id": m["record_id"],
            "matched_master_title": m["title"],
            "title_similarity": 1.0,
            "priority": 1,
        }

    # 2. DOI match, but only adjudicatively useful when bibliography is compatible.
    doi_candidates = []
    if inc["doi_keys"]:
        inc_title = inc["title_key"]
        for m in master:
            shared = set(inc["doi_keys"]) & set(m["doi_keys"])
            if not shared:
                continue
            sim = title_similarity(inc_title, m["title_key"])
            if sim >= DOI_TITLE_COMPATIBILITY_THRESHOLD:
                status, priority, basis = "duplicate", 2, "matching DOI plus compatible title"
            elif not inc_title or not m["title_key"]:
                status, priority, basis = "possible_duplicate", 5, "matching DOI but one title unavailable"
            else:
                status, priority, basis = "doi_conflict_review", 6, "matching DOI but discordant titles"
            doi_candidates.append({
                "status": status, "basis": basis,
                "matched_master_record_id": m["record_id"],
                "matched_master_title": m["title"],
                "title_similarity": sim, "priority": priority,
            })
    chosen = best_candidate(doi_candidates)
    if chosen and chosen["status"] != "doi_conflict_review":
        return chosen

    # 3. Fuzzy candidate generation: same year, first author, title prefix or token key.
    candidates: list[dict[str, Any]] = []
    for m in master:
        bases = []
        if inc["year_key"] and m["year_key"] and inc["year_key"] == m["year_key"]:
            bases.append("same year")
        if inc["first_author_key"] and m["first_author_key"] and inc["first_author_key"] == m["first_author_key"]:
            bases.append("same first author")
        if inc["title_prefix"] and m["title_prefix"] and inc["title_prefix"] == m["title_prefix"]:
            bases.append("same title prefix")
        if inc["title_token_key"] and m["title_token_key"] and inc["title_token_key"] == m["title_token_key"]:
            bases.append("same title-token key")
        if not bases:
            continue
        sim = title_similarity(inc["title_key"], m["title_key"])
        if sim < FUZZY_THRESHOLD:
            continue
        blocking = bases[0]
        probable = sim >= PROBABLE_THRESHOLD and blocking in {
            "same first author", "same title prefix", "same title-token key"
        }
        status = "probable_duplicate" if probable else "possible_duplicate"
        priority = 3 if probable else 4
        basis = f"{'very high' if probable else 'high'} title similarity plus {blocking}"
        candidates.append({
            "status": status, "basis": basis,
            "matched_master_record_id": m["record_id"],
            "matched_master_title": m["title"],
            "title_similarity": sim, "priority": priority,
        })
    return best_candidate(candidates) or (chosen if chosen else None)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--master", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--audit", required=True)
    args = ap.parse_args()

    incoming_records = load_records(Path(args.input))
    master_records = load_records(Path(args.master))
    incoming = [prepared(r) for r in incoming_records]
    master = [prepared(r) for r in master_records]

    seen_lens: dict[str, str] = {}
    output: list[dict[str, Any]] = []
    audit: list[dict[str, Any]] = []

    for record in incoming:
        lens_id = record["lens_id"]
        if not lens_id:
            raise RuntimeError("Incoming record has no authoritative lens_id")
        if lens_id in seen_lens:
            decision = {
                "status": "identity_match",
                "basis": "matching lens_id",
                "matched_master_record_id": "",
                "matched_master_title": "",
                "title_similarity": 1.0,
            }
        else:
            decision = match_record(record, master)
            if decision is None:
                decision = {
                    "status": "new",
                    "basis": "no deterministic bibliographic match",
                    "matched_master_record_id": "",
                    "matched_master_title": "",
                    "title_similarity": 0.0,
                }
        seen_lens[lens_id] = lens_id
        audit_row = {"lens_id": lens_id, **decision}
        audit.append(audit_row)
        output.append(audit_row)

    # The detailed candidate audit is the structured decision output.
    Path(args.output).write_text(
        "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in output),
        encoding="utf-8",
    )
    Path(args.audit).write_text(
        "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in audit),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
