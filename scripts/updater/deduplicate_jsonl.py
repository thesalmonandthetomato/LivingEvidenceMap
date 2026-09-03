#!/usr/bin/env python3
"""Workflow 02: JSON-native staged bibliographic deduplication with checkpoints."""
from __future__ import annotations

import argparse
import json
import math
import re
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

FUZZY_THRESHOLD = 0.965
PROBABLE_THRESHOLD = 0.985
DOI_TITLE_COMPATIBILITY_THRESHOLD = 0.90
ABSTRACT_PROBABLE_THRESHOLD = 0.88
ABSTRACT_HIGH_THRESHOLD = 0.94
ABSTRACT_POSSIBLE_THRESHOLD = 0.82
MAX_PREPRINT_YEAR_GAP = 2
CHECKPOINT_VERSION = 2
PREPRINT_SOURCE_TERMS = {
    "biorxiv", "medrxiv", "arxiv", "preprint", "research square",
    "repository", "institutional repository", "thesis", "dissertation",
}


def now():
    return datetime.now(timezone.utc).isoformat()


def norm(value):
    if value is None:
        return ""
    s = unicodedata.normalize("NFKD", str(value)).casefold()
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def lens_payload(record):
    p = record.get("lens", {}).get("raw_payload", {})
    if not isinstance(p, dict):
        raise RuntimeError("Lens record lens.raw_payload is not an object")
    return p


def canonical(record):
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


def extract_dois(record):
    c = canonical(record)
    if c.get("doi"):
        v = norm(c.get("doi"))
        v = re.sub(r"^https?://(?:dx\.)?doi\.org/", "", v)
        v = re.sub(r"^doi:\s*", "", v)
        return [v] if v else []
    try:
        ids = lens_payload(record).get("external_ids") or []
    except RuntimeError:
        ids = []
    if not isinstance(ids, list):
        return []
    out = []
    for item in ids:
        if not isinstance(item, dict) or norm(item.get("type")) != "doi":
            continue
        v = norm(item.get("value"))
        v = re.sub(r"^https?://(?:dx\.)?doi\.org/", "", v)
        v = re.sub(r"^doi:\s*", "", v)
        if v:
            out.append(v)
    return sorted(set(out))


def title_key(r):
    return norm(canonical(r).get("title"))


def abstract_key(r):
    return norm(canonical(r).get("abstract"))


def year_key(r):
    return norm(canonical(r).get("year"))


def year_int(value):
    m = re.search(r"(?:19|20)\d{2}", str(value or ""))
    return int(m.group(0)) if m else None


def source_key(r):
    return norm(canonical(r).get("source"))


def author_values(r):
    a = canonical(r).get("authors") or []
    if isinstance(a, str):
        return [norm(x) for x in re.split(r"\s*\|\s*|\s*;\s*", a) if x.strip()]
    if not isinstance(a, list):
        return []
    names = []
    for x in a[:10]:
        if isinstance(x, dict):
            name = " ".join(y for y in (norm(x.get("last_name")), norm(x.get("first_name"))) if y) or norm(x.get("name"))
            names.append(name)
        else:
            names.append(norm(x))
    return [x for x in names if x]


def first_author_key(r):
    v = author_values(r)
    return norm(v[0]) if v else ""


def title_prefix(r):
    return title_key(r)[:24]


def title_token_key(r):
    tokens = [t for t in re.split(r"\s+", title_key(r)) if t]
    return " ".join(sorted(set(tokens[:8])))


def jaro_similarity(a, b):
    if a == b:
        return 1.0 if a else 0.0
    if not a or not b:
        return 0.0
    if len(a) > len(b):
        a, b = b, a
    d = max(len(b) // 2 - 1, 0)
    am = [False] * len(a)
    bm = [False] * len(b)
    matches = 0
    for i, ch in enumerate(a):
        for j in range(max(0, i - d), min(i + d + 1, len(b))):
            if bm[j] or ch != b[j]:
                continue
            am[i] = True
            bm[j] = True
            matches += 1
            break
    if matches == 0:
        return 0.0
    aa = [a[i] for i in range(len(a)) if am[i]]
    bb = [b[j] for j in range(len(b)) if bm[j]]
    trans = sum(x != y for x, y in zip(aa, bb)) / 2.0
    return (matches / len(a) + matches / len(b) + (matches - trans) / matches) / 3.0


def title_similarity(a, b):
    if not a or not b:
        return 0.0
    j = jaro_similarity(a, b)
    prefix = 0
    for x, y in zip(a, b):
        if x != y or prefix == 4:
            break
        prefix += 1
    return j + prefix * 0.1 * (1.0 - j)


def token_cosine_similarity(a, b):
    if not a or not b:
        return 0.0
    ca, cb = Counter(a.split()), Counter(b.split())
    shared = ca.keys() & cb.keys()
    dot = sum(ca[k] * cb[k] for k in shared)
    if not dot:
        return 0.0
    da = math.sqrt(sum(v * v for v in ca.values()))
    db = math.sqrt(sum(v * v for v in cb.values()))
    return dot / (da * db) if da and db else 0.0


def source_is_preprint_or_missing(source):
    if not source:
        return True
    return any(term in source for term in PREPRINT_SOURCE_TERMS)


def prepared(r, origin="master"):
    c = canonical(r)
    return {
        "lens_id": str(c.get("lens_id") or ""),
        "record_id": str(c.get("record_id") or ""),
        "title": c.get("title") or "",
        "title_key": title_key(r),
        "abstract_key": abstract_key(r),
        "doi_keys": extract_dois(r),
        "year_key": year_key(r),
        "year": year_int(c.get("year")),
        "source_key": source_key(r),
        "first_author_key": first_author_key(r),
        "title_prefix": title_prefix(r),
        "title_token_key": title_token_key(r),
        "origin": origin,
    }


def load_records(path):
    rows = []
    with path.open(encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                raise RuntimeError(f"Invalid JSONL at line {n}: {e}") from e
    return rows


def best_candidate(candidates):
    if not candidates:
        return None
    return sorted(
        candidates,
        key=lambda x: (
            x["priority"],
            -x.get("abstract_similarity", 0.0),
            -x.get("title_similarity", 0.0),
        ),
    )[0]


def candidate_payload(status, basis, matched, title_sim, priority, abstract_sim=0.0, manifestation=None):
    out = {
        "status": status,
        "basis": basis,
        "matched_master_record_id": matched["record_id"],
        "matched_master_lens_id": matched["lens_id"],
        "matched_master_title": matched["title"],
        "matched_record_origin": matched.get("origin", "master"),
        "title_similarity": round(title_sim, 6),
        "abstract_similarity": round(abstract_sim, 6),
        "priority": priority,
    }
    if manifestation:
        out["manifestation_pattern"] = manifestation
    return out


def match_record(inc, comparison_records):
    exact = [m for m in comparison_records if inc["title_key"] and m["title_key"] == inc["title_key"]]
    if exact:
        m = exact[0]
        return candidate_payload("duplicate", "exact normalised title", m, 1.0, 1)

    doi_candidates = []
    if inc["doi_keys"]:
        for m in comparison_records:
            if not (set(inc["doi_keys"]) & set(m["doi_keys"])):
                continue
            tsim = title_similarity(inc["title_key"], m["title_key"])
            asim = token_cosine_similarity(inc["abstract_key"], m["abstract_key"])
            if tsim >= DOI_TITLE_COMPATIBILITY_THRESHOLD:
                status, priority, basis = "duplicate", 2, "matching DOI plus compatible title"
            elif not inc["title_key"] or not m["title_key"]:
                status, priority, basis = "possible_duplicate", 5, "matching DOI but one title unavailable"
            else:
                status, priority, basis = "doi_conflict_review", 6, "matching DOI but discordant titles"
            doi_candidates.append(candidate_payload(status, basis, m, tsim, priority, asim))
    chosen = best_candidate(doi_candidates)
    if chosen and chosen["status"] != "doi_conflict_review":
        return chosen

    candidates = []
    for m in comparison_records:
        same_first_author = bool(inc["first_author_key"] and inc["first_author_key"] == m["first_author_key"])
        year_gap = None
        if inc["year"] is not None and m["year"] is not None:
            year_gap = abs(inc["year"] - m["year"])
        compatible_year = year_gap is None or year_gap <= MAX_PREPRINT_YEAR_GAP
        tsim = title_similarity(inc["title_key"], m["title_key"])

        # Dedicated preprint/repository-to-journal pathway. Missing journal/source on the
        # earlier manifestation is supportive evidence, not a mismatch.
        if same_first_author and compatible_year and inc["abstract_key"] and m["abstract_key"]:
            asim = token_cosine_similarity(inc["abstract_key"], m["abstract_key"])
            preprint_pattern = source_is_preprint_or_missing(inc["source_key"]) or source_is_preprint_or_missing(m["source_key"])
            if asim >= ABSTRACT_HIGH_THRESHOLD:
                candidates.append(candidate_payload(
                    "probable_duplicate",
                    "very high abstract similarity plus same first author and compatible publication year",
                    m, tsim, 3, asim,
                    "preprint_or_repository_to_later_manifestation" if preprint_pattern else "same_work_manifestation",
                ))
                continue
            if asim >= ABSTRACT_PROBABLE_THRESHOLD and (preprint_pattern or tsim >= 0.80):
                candidates.append(candidate_payload(
                    "probable_duplicate",
                    "high abstract similarity plus same first author, compatible publication year, and preprint/repository or compatible-title evidence",
                    m, tsim, 3, asim,
                    "preprint_or_repository_to_later_manifestation" if preprint_pattern else "same_work_manifestation",
                ))
                continue
            if asim >= ABSTRACT_POSSIBLE_THRESHOLD:
                candidates.append(candidate_payload(
                    "possible_duplicate",
                    "moderate-high abstract similarity plus same first author and compatible publication year",
                    m, tsim, 4, asim,
                    "possible_same_work_manifestation",
                ))

        bases = []
        if inc["year_key"] and m["year_key"] and inc["year_key"] == m["year_key"]:
            bases.append("same year")
        if same_first_author:
            bases.append("same first author")
        if inc["title_prefix"] and m["title_prefix"] and inc["title_prefix"] == m["title_prefix"]:
            bases.append("same title prefix")
        if inc["title_token_key"] and m["title_token_key"] and inc["title_token_key"] == m["title_token_key"]:
            bases.append("same title-token key")
        if not bases or tsim < FUZZY_THRESHOLD:
            continue
        blocking = bases[0]
        probable = tsim >= PROBABLE_THRESHOLD and blocking in {"same first author", "same title prefix", "same title-token key"}
        candidates.append(candidate_payload(
            "probable_duplicate" if probable else "possible_duplicate",
            f"{'very high' if probable else 'high'} title similarity plus {blocking}",
            m, tsim, 3 if probable else 4,
        ))
    return best_candidate(candidates) or chosen


def save_checkpoint(path, completed, total, chunk_size):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps({
        "checkpoint_version": CHECKPOINT_VERSION,
        "workflow": "02_deduplication",
        "completed_records": completed,
        "total_records": total,
        "next_record_index": completed,
        "chunk_size": chunk_size,
        "updated_at": now(),
    }, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--master", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--audit", required=True)
    ap.add_argument("--checkpoint")
    ap.add_argument("--chunk-size", type=int, default=250)
    ap.add_argument("--resume", action="store_true")
    args = ap.parse_args()
    if args.chunk_size < 1:
        raise ValueError("--chunk-size must be at least 1")

    incoming_records = load_records(Path(args.input))
    master = [prepared(r, origin="master") for r in load_records(Path(args.master))]
    incoming = [prepared(r, origin="incoming") for r in incoming_records]
    outp = Path(args.output)
    auditp = Path(args.audit)
    cp = Path(args.checkpoint) if args.checkpoint else outp.with_suffix(outp.suffix + ".checkpoint.json")
    outp.parent.mkdir(parents=True, exist_ok=True)
    auditp.parent.mkdir(parents=True, exist_ok=True)

    start = 0
    seen = set()
    processed_incoming = []
    if args.resume:
        state = json.loads(cp.read_text(encoding="utf-8"))
        start = int(state["completed_records"])
        if state["total_records"] != len(incoming_records):
            raise RuntimeError("Checkpoint input length mismatch")
        existing = load_records(outp)
        seen = {str(r.get("identity", {}).get("lens_id") or canonical(r).get("lens_id") or "") for r in existing}
        if len(existing) != start:
            raise RuntimeError("Checkpoint/output record count mismatch")
        processed_incoming = incoming[:start]
    else:
        outp.write_text("", encoding="utf-8")
        auditp.write_text("", encoding="utf-8")
        save_checkpoint(cp, 0, len(incoming_records), args.chunk_size)

    with outp.open("a", encoding="utf-8") as out, auditp.open("a", encoding="utf-8") as audit:
        for i in range(start, len(incoming_records)):
            original, record = incoming_records[i], incoming[i]
            lid = record["lens_id"]
            if not lid:
                raise RuntimeError("Incoming record has no authoritative lens_id")
            if lid in seen:
                decision = {
                    "status": "identity_match",
                    "basis": "matching lens_id within incoming batch",
                    "matched_master_record_id": "",
                    "matched_master_lens_id": lid,
                    "matched_master_title": "",
                    "matched_record_origin": "incoming",
                    "title_similarity": 1.0,
                    "abstract_similarity": 1.0,
                }
            else:
                decision = match_record(record, master + processed_incoming) or {
                    "status": "new",
                    "basis": "no deterministic bibliographic match",
                    "matched_master_record_id": "",
                    "matched_master_lens_id": "",
                    "matched_master_title": "",
                    "matched_record_origin": "",
                    "title_similarity": 0.0,
                    "abstract_similarity": 0.0,
                }
            seen.add(lid)
            processed_incoming.append(record)
            enriched = dict(original)
            enriched["deduplication"] = {k: v for k, v in decision.items() if k != "priority"}
            out.write(json.dumps(enriched, ensure_ascii=False, separators=(",", ":")) + "\n")
            audit.write(json.dumps({"lens_id": lid, **{k: v for k, v in decision.items() if k != "priority"}}, ensure_ascii=False, separators=(",", ":")) + "\n")
            completed = i + 1
            if completed % args.chunk_size == 0 or completed == len(incoming_records):
                out.flush()
                audit.flush()
                save_checkpoint(cp, completed, len(incoming_records), args.chunk_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
