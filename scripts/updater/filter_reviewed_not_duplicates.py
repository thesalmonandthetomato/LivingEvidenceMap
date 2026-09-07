#!/usr/bin/env python3
"""Remove explicitly reviewed not-duplicate pairs from Workflow 02 candidates.

The decisions are stored as hashes of the unordered pair of Lens IDs. This keeps the
candidate stream lossless for all other pairs while ensuring reviewed non-duplicates do
not remain in the human adjudication queue or become downstream blockers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def load_jsonl(path: Path):
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


def pair_hash(a, b):
    joined = "|".join(sorted((str(a or ""), str(b or ""))))
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--reviewed", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--removed-audit", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    candidates = load_jsonl(Path(args.candidates))
    reviewed = json.loads(Path(args.reviewed).read_text(encoding="utf-8"))
    assert reviewed.get("decision") == "not_duplicate"
    expected = int(reviewed.get("count") or 0)
    reviewed_rows = reviewed.get("pairs") or []
    hashes = {str(x.get("hash")) for x in reviewed_rows if x.get("hash")}
    assert len(hashes) == expected, (len(hashes), expected)

    kept, removed = [], []
    for c in candidates:
        h = pair_hash(c.get("lens_id"), c.get("matched_master_lens_id"))
        if h in hashes:
            row = dict(c)
            row["reviewed_adjudication"] = {
                "decision": "not_duplicate",
                "source": "workflow02_reviewed_not_duplicate_hashes_2026-09-07",
                "pair_hash": h,
            }
            removed.append(row)
        else:
            kept.append(c)

    outp = Path(args.output)
    outp.parent.mkdir(parents=True, exist_ok=True)
    with outp.open("w", encoding="utf-8") as f:
        for row in kept:
            f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    auditp = Path(args.removed_audit)
    with auditp.open("w", encoding="utf-8") as f:
        for row in removed:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    removed_hashes = {pair_hash(x.get("lens_id"), x.get("matched_master_lens_id")) for x in removed}
    missing = sorted(hashes - removed_hashes)
    summary = {
        "input_candidates": len(candidates),
        "output_candidates": len(kept),
        "reviewed_not_duplicate_pairs_loaded": len(hashes),
        "reviewed_not_duplicate_pairs_removed": len(removed),
        "reviewed_hashes_not_present_in_current_candidates": len(missing),
        "missing_hashes": missing,
        "canonical_modified": False,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
