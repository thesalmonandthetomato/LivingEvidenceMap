#!/usr/bin/env python3
"""Workflow 02: JSON-native staged bibliographic deduplication.

Incoming Lens records remain rich JSON. The historical master may be supplied
through the lossless legacy_master_adapter JSONL view. Matching is performed
on a small canonical bibliographic projection while the complete incoming
record is retained unchanged and annotated with the deterministic decision.

Rules are ported from R/relevance_screening.R. Lens identity and bibliographic
identity remain separate. DOI is supporting evidence only and is never, by
itself, a duplicate decision.
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
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


def lens_payload(record: dict[str, Any]) -> dict[str, Any]:
    p = record.get("lens", {}).get("raw_payload", {})
    if not isinstance(p, dict):
        raise RuntimeError("Lens record lens.raw_payload is not an object")
    return p


def canonical(record: dict[str, Any]) -> dict[str, Any]:
    c = record.get("canonical")
    if isinstance(c, dict):
        return c
    p = lens_payload(record)
    return {
        "record_id": record.get("identity", {}).get("record_id") or record.get("record_id"),
        "lens_id": record.get("identity", {}).get("lens_id") or p.get("lens_id"),
        "title": p.get("title"),
        "authors": p.get("authors"),
        "year": p.get("year_published") if p.get("year_published") is not None else p.get("date_published"),
        "source": (p.get("source") or {}).get("title") if isinstance(p.get("source"), dict) else p.get("source"),
        "doi": None,
        "abstract": p.get("abstract"),
    }


def extract_dois(record: dict[str, Any]) -> list[str]:
    c = canonical(record)
    if c.get("doi"):
        value = norm(c.get("doi"))
        value = re.sub(r"^https?://(?:dx\.)?doi\.org/", "", value)
        value = re.sub(r"^doi:\s*", "", value)
        return [value] if value else []
    try:
        ids = lens_payload(record).get("external_ids") or []
    except RuntimeError:
        ids = []
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
    return norm(canonical(record).get("title"))


def year_key(record: dict[str, Any]) -> str:
    return norm(canonical(record).get("year"))


def source_key(record: dict[str, Any]) -> str:
    return norm(canonical(record).get("source"))


def author_values(record: dict[str, Any]) -> list[str]:
    authors = canonical(record).get("authors") or []
    if isinstance(authors, str):
        return [x.strip() for x in re.split(r"\s*\|\s*|\s*;\s*", authors) if x.strip()]
    if not isinstance(authors, list):
        return []
    names = []
    for author in authors[:5]:
        if isinstance(author, dict):
            last = norm(author.get("last_name"))
            first = norm(author.get("first_name"))
            name = " ".join(x for x in (last, first) if x)
            if not name:
                name = norm(author.get("name"))
            names.append(name)
        else:
            names.append(norm(author))
    return [x for x in names if x]


def authors_key(record: dict[str, Any]) -> str:
    return "|".join(author_values(record))


def first_author_key(record: dict[str, Any]) -> str:
    values = author_values(record)
    return norm(values[0]) if values else ""


def title_prefix(record: dict[str, Any]) -> str:
    return title_key(record)[:24]


def title_token_key(record: dict[str, Any]) -> str:
    tokens = [t for t in re.split(r"\s+", title_key(record)) if t]
    return " ".join(sorted(set(tokens[:8])))


def jaro_similarity(a: str, b: str) -> float:
    """Exact Jaro similarity, matching the legacy R stringdist metric."""
    if a == b:
        return 1.0 if a else 0.0
    if not a or not b:
        return 0.0
    if len(a) > len(b):
        a, b = b, a
    match_distance = max(len(b) // 2 - 1, 0)
    a_match = [False] * len(a)
    b_match = [False] * len(b)
    matches = 0
    for i, char in enumerate(a):
        start = max(0, i - match_distance)
        end = min(i + match_distance + 1, len(b))
        for j in range(start, end):
            if b_match[j] or char != b[j]:
                continue
            a_match[i] = True
            b_match[j] = True
            matches += 1
            break
    if matches == 0:
        return 0.0
    a_seq = [a[i] for i in range(len(a)) if a_match[i]]
    b_seq = [b[j] for j in range(len(b)) if b_match[j]]
    transpositions = sum(x != y for x, y in zip(a_seq, b_seq)) / 2.0
    return (matches / len(a) + matches / len(b) + (matches - transpositions) / matches) / 3.0


def title_similarity(a: str, b: str) -> float:
    """Jaro-Winkler title similarity used by the legacy matcher."""
    if not a or not b:
        return 0.0
    j = jaro_similarity(a, b)
    prefix = 0
    for x, y in zip(a, b):
        if x != y or prefix == 4:
            break
        prefix += 1
    return j + prefix * 0.1 * (1.0 - j)


def prepared(record: dict[str, Any]) -> dict[str, Any]:
    c = canonical(record)
    return {
        "lens_id": str(c.get("lens_id") or ""),
        "record_id": str(c.get("record_id") or ""),
        "title": c.get("title") or "",
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
    exact = [m for m in master if inc["title_key"] and m["title_key"] == inc["title_key"]]
    if exact:
        m = exact[0]
        return {"status": "duplicate", "basis": "exact normalised title", "matched_master_record_id": m["record_id"], "matched_master_title": m["title"], "title_similarity": 1.0, "priority": 1}

    doi_candidates = []
    if inc["doi_keys"]:
        for m in master:
            if not (set(inc["doi_keys"]) & set(m["doi_keys"])):
                continue
            sim = title_similarity(inc["title_key"], m["title_key"])
            if sim >= DOI_TITLE_COMPATIBILITY_THRESHOLD:
                status, priority, basis = "duplicate", 2, "matching DOI plus compatible title"
            elif not inc["title_key"] or not m["title_key"]:
                status, priority, basis = "possible_duplicate", 5, "matching DOI but one title unavailable"
            else:
                status, priority, basis = "doi_conflict_review", 6, "matching DOI but discordant titles"
            doi_candidates.append({"status": status, "basis": basis, "matched_master_record_id": m["record_id"], "matched_master_title": m["title"], "title_similarity": sim, "priority": priority})
    chosen = best_candidate(doi_candidates)
    if chosen and chosen["status"] != "doi_conflict_review":
        return chosen

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
        probable = sim >= PROBABLE_THRESHOLD and blocking in {"same first author", "same title prefix", "same title-token key"}
        candidates.append({"status": "probable_duplicate" if probable else "possible_duplicate", "basis": f"{'very high' if probable else 'high'} title similarity plus {blocking}", "matched_master_record_id": m["record_id"], "matched_master_title": m["title"], "title_similarity": sim, "priority": 3 if probable else 4})
    return best_candidate(candidates) or chosen


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

    seen_lens: set[str] = set()
    output: list[dict[str, Any]] = []
    audit: list[dict[str, Any]] = []

    for original, record in zip(incoming_records, incoming):
        lens_id = record["lens_id"]
        if not lens_id:
            raise RuntimeError("Incoming record has no authoritative lens_id")
        if lens_id in seen_lens:
            decision = {"status": "identity_match", "basis": "matching lens_id", "matched_master_record_id": "", "matched_master_title": "", "title_similarity": 1.0}
        else:
            decision = match_record(record, master) or {"status": "new", "basis": "no deterministic bibliographic match", "matched_master_record_id": "", "matched_master_title": "", "title_similarity": 0.0}
        seen_lens.add(lens_id)

        enriched = dict(original)
        enriched["deduplication"] = {k: v for k, v in decision.items() if k != "priority"}
        output.append(enriched)
        audit.append({"lens_id": lens_id, **{k: v for k, v in decision.items() if k != "priority"}})

    Path(args.output).write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in output), encoding="utf-8")
    Path(args.audit).write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in audit), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
