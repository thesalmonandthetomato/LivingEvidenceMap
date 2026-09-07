#!/usr/bin/env python3
"""Augment Workflow 02 candidates using reviewed decisions and conservative rules."""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path

VERSION_TERMS = {
    "peer review", "reply", "comment", "supplement", "corrigendum",
    "erratum", "editorial", "response to", "version",
}
PREPRINT_TERMS = {
    "preprint", "biorxiv", "medrxiv", "arxiv", "repository",
    "working paper", "repec", "ssrn", "hal",
}


def norm(value):
    if value is None:
        return ""
    s = unicodedata.normalize("NFKD", str(value)).casefold()
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def lens_payload(record):
    p = record.get("lens", {}).get("raw_payload", {})
    return p if isinstance(p, dict) else {}


def canonical(record):
    c = record.get("canonical")
    if isinstance(c, dict):
        return c
    p = lens_payload(record)
    src = p.get("source")
    return {
        "record_id": record.get("identity", {}).get("record_id"),
        "lens_id": record.get("identity", {}).get("lens_id") or p.get("lens_id"),
        "title": p.get("title"),
        "authors": p.get("authors"),
        "year": p.get("year_published") if p.get("year_published") is not None else p.get("date_published"),
        "source": src.get("title") if isinstance(src, dict) else src,
        "doi": None,
        "abstract": p.get("abstract"),
    }


def extract_dois(record):
    c = canonical(record)
    if c.get("doi"):
        v = norm(c.get("doi"))
        return [v] if v else []
    out = []
    for item in lens_payload(record).get("external_ids") or []:
        if isinstance(item, dict) and norm(item.get("type")) == "doi":
            v = norm(item.get("value"))
            if v:
                out.append(v)
    return sorted(set(out))


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


def raw_payload(record):
    return lens_payload(record)


def publication_type(record):
    return str(raw_payload(record).get("publication_type") or "")


def source_title(record):
    c = canonical(record)
    s = raw_payload(record).get("source")
    raw = s.get("title") if isinstance(s, dict) else s
    return str(c.get("source") or raw or "")


def title(record):
    return str(canonical(record).get("title") or "")


def year(record):
    m = re.search(r"(?:19|20)\d{2}", str(canonical(record).get("year") or ""))
    return int(m.group(0)) if m else None


def author_values(record):
    authors = canonical(record).get("authors") or []
    if isinstance(authors, str):
        return [norm(x) for x in re.split(r"\s*\|\s*|\s*;\s*", authors) if x.strip()]
    if not isinstance(authors, list):
        return []
    out = []
    for x in authors:
        if isinstance(x, dict):
            v = " ".join(y for y in (norm(x.get("last_name")), norm(x.get("first_name"))) if y) or norm(x.get("name"))
        else:
            v = norm(x)
        if v:
            out.append(v)
    return out


def author_jaccard(a, b):
    aa, bb = set(author_values(a)), set(author_values(b))
    return len(aa & bb) / len(aa | bb) if aa and bb else 0.0


def title_token_jaccard(a, b):
    aa, bb = set(norm(title(a)).split()), set(norm(title(b)).split())
    return len(aa & bb) / len(aa | bb) if aa and bb else 0.0


def is_preprint_like(record):
    text = " ".join((norm(publication_type(record)), norm(source_title(record))))
    return any(term in text for term in PREPRINT_TERMS)


def missing_source_or_doi(record):
    return not norm(source_title(record)) or not extract_dois(record)


def has_version_discriminator(a, b):
    text = f"{norm(title(a))} {norm(title(b))}"
    return any(term in text for term in VERSION_TERMS)


def pair_key(a, b):
    return tuple(sorted((str(a or ""), str(b or ""))))


def load_reviewed(path):
    if not path:
        return {}
    out = {}
    for row in load_records(Path(path)):
        if row.get("decision") != "duplicate":
            continue
        out[pair_key(row.get("lens_id_a"), row.get("lens_id_b"))] = row
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--reviewed")
    args = ap.parse_args()

    records = load_records(Path(args.canonical))
    candidates = load_records(Path(args.candidates))
    reviewed = load_reviewed(args.reviewed)
    counts = Counter()
    out = []

    for candidate in candidates:
        c = dict(candidate)
        ai, bi = c.get("record_index"), c.get("matched_index")
        if not isinstance(ai, int) or not isinstance(bi, int) or not (0 <= ai < len(records) and 0 <= bi < len(records)):
            out.append(c)
            counts["unchanged_invalid_indices"] += 1
            continue
        a, b = records[ai], records[bi]
        lids = pair_key(canonical(a).get("lens_id"), canonical(b).get("lens_id"))

        if lids in reviewed:
            d = reviewed[lids]
            c["status"] = "duplicate"
            c["basis"] = "human-reviewed duplicate adjudication"
            c["reviewed_adjudication"] = {
                "decision": "duplicate",
                "source": "workflow02_reviewed_duplicate_pairs_2026-09-07",
                "source_queue_row": d.get("source_queue_row"),
                "pattern": d.get("pattern"),
            }
            counts["reviewed_duplicate_override"] += 1
            out.append(c)
            continue

        # Do not broaden records the existing resolver already treats as deterministic.
        if c.get("status") == "duplicate":
            counts["unchanged_existing_duplicate"] += 1
            out.append(c)
            continue

        asim = float(c.get("abstract_similarity") or 0)
        tsim = float(c.get("title_similarity") or 0)
        aj = author_jaccard(a, b)
        tj = title_token_jaccard(a, b)
        ya, yb = year(a), year(b)
        gap = abs(ya - yb) if ya and yb else 0
        version_block = has_version_discriminator(a, b)

        if (
            is_preprint_like(a) != is_preprint_like(b)
            and gap <= 2 and aj >= 0.60 and not version_block
            and ((asim >= 0.88 and tj >= 0.65) or tsim >= 0.95)
        ):
            c["status"] = "duplicate"
            c["basis"] = "conservative preprint/repository/working-paper manifestation rule"
            c["automation_signal"] = "preprint_repository_manifestation_v2"
            counts["auto_preprint_repository_manifestation"] += 1
            out.append(c)
            continue

        if (
            (missing_source_or_doi(a) or missing_source_or_doi(b))
            and gap <= 2 and aj >= 0.80 and tsim >= 0.97 and not version_block
        ):
            c["status"] = "duplicate"
            c["basis"] = "conservative sparse-metadata duplicate rule"
            c["automation_signal"] = "sparse_metadata_duplicate_v1"
            counts["auto_sparse_metadata_duplicate"] += 1
            out.append(c)
            continue

        # These signals improve prioritisation but are deliberately not auto-merges.
        if asim >= 0.95 and aj >= 0.80 and tsim < 0.90 and title(a) and title(b):
            c["automation_signal"] = "translated_or_related_work_review"
            counts["flag_translated_or_related_work_review"] += 1
        elif asim >= 0.98 and tsim < 0.75:
            c["automation_signal"] = "possible_abstract_contamination"
            counts["flag_possible_abstract_contamination"] += 1
        else:
            counts["unchanged"] += 1
        out.append(c)

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    with Path(args.output).open("w", encoding="utf-8") as f:
        for row in out:
            f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    summary = {
        "input_candidates": len(candidates),
        "output_candidates": len(out),
        "reviewed_duplicate_pairs_loaded": len(reviewed),
        "rule_counts": dict(counts),
        "canonical_modified": False,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
