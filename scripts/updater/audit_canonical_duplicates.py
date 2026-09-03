#!/usr/bin/env python3
"""Read-only full-corpus duplicate audit using Workflow 02 matching rules."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from deduplicate_jsonl import load_records, match_record, prepared


def add(index, key, i):
    if key:
        index[key].append(i)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    raw = load_records(Path(args.input))
    rows = [prepared(r, origin="canonical") for r in raw]

    by_lens = defaultdict(list)
    by_title = defaultdict(list)
    by_doi = defaultdict(list)
    by_author = defaultdict(list)
    by_prefix = defaultdict(list)
    by_token = defaultdict(list)

    for i, r in enumerate(rows):
        add(by_lens, r["lens_id"], i)
        add(by_title, r["title_key"], i)
        for doi in r["doi_keys"]:
            add(by_doi, doi, i)
        add(by_author, r["first_author_key"], i)
        add(by_prefix, r["title_prefix"], i)
        add(by_token, r["title_token_key"], i)

    candidates = []
    compared_pairs = set()

    for i, r in enumerate(rows):
        idx = set()
        idx.update(by_lens.get(r["lens_id"], []))
        idx.update(by_title.get(r["title_key"], []))
        for doi in r["doi_keys"]:
            idx.update(by_doi.get(doi, []))
        idx.update(by_prefix.get(r["title_prefix"], []))
        idx.update(by_token.get(r["title_token_key"], []))

        # Abstract/preprint pathway: same first author and publication year within +/-2.
        if r["first_author_key"]:
            for j in by_author.get(r["first_author_key"], []):
                if j >= i:
                    continue
                other = rows[j]
                if r["year"] is not None and other["year"] is not None and abs(r["year"] - other["year"]) > 2:
                    continue
                idx.add(j)

        idx = sorted(j for j in idx if j < i)
        if not idx:
            continue

        comparison = [rows[j] for j in idx]
        decision = match_record(r, comparison)
        if not decision or decision["status"] == "new":
            continue

        matched_lens = decision.get("matched_master_lens_id", "")
        matched_index = next((j for j in idx if rows[j]["lens_id"] == matched_lens), None)
        pair = tuple(sorted((r["lens_id"], matched_lens)))
        if not matched_lens or pair in compared_pairs:
            continue
        compared_pairs.add(pair)

        candidates.append({
            "record_index": i,
            "lens_id": r["lens_id"],
            "record_id": r["record_id"],
            "title": r["title"],
            "year": r["year"],
            "matched_index": matched_index,
            **{k: v for k, v in decision.items() if k != "priority"},
        })

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as f:
        for row in candidates:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    status_counts = defaultdict(int)
    manifestation_counts = defaultdict(int)
    for c in candidates:
        status_counts[c.get("status", "")] += 1
        manifestation_counts[c.get("manifestation_pattern", "none")] += 1

    summary = {
        "record_count": len(rows),
        "unique_lens_ids": len(by_lens),
        "candidate_pairs": len(candidates),
        "status_counts": dict(sorted(status_counts.items())),
        "manifestation_counts": dict(sorted(manifestation_counts.items())),
        "audit_only": True,
        "canonical_modified": False,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
