#!/usr/bin/env python3
"""Remove all legacy relevance-screening state from the canonical JSONL.

This is a one-off reset utility. It preserves every record and every non-screening
field while removing screening decisions and screening-decision provenance so that
relevance screening can be rebuilt from scratch.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

SCREENING_PROVENANCE_KEYS = {
    "historical_screening",
    "historical_excludes_reconciliation",
    "residual_screening_assignment",
    "screening_decision_history",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    src = Path(args.input)
    dst = Path(args.output)
    summary_path = Path(args.summary)

    counts = {
        "records_in": 0,
        "records_out": 0,
        "records_with_screening_removed": 0,
        "provenance_fields_removed": {k: 0 for k in sorted(SCREENING_PROVENANCE_KEYS)},
    }

    dst.parent.mkdir(parents=True, exist_ok=True)
    with src.open(encoding="utf-8") as fin, dst.open("w", encoding="utf-8") as fout:
        for line_no, line in enumerate(fin, 1):
            if not line.strip():
                continue
            record = json.loads(line)
            counts["records_in"] += 1

            if "screening" in record:
                del record["screening"]
                counts["records_with_screening_removed"] += 1

            provenance = record.get("provenance")
            if isinstance(provenance, dict):
                for key in SCREENING_PROVENANCE_KEYS:
                    if key in provenance:
                        del provenance[key]
                        counts["provenance_fields_removed"][key] += 1

            fout.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            counts["records_out"] += 1

    if counts["records_out"] != counts["records_in"]:
        raise SystemExit(f"Record-count mismatch: {counts}")

    # Independent verification pass: no reset-target fields may remain.
    remaining_screening = 0
    remaining_provenance = {k: 0 for k in sorted(SCREENING_PROVENANCE_KEYS)}
    with dst.open(encoding="utf-8") as f:
        verify_n = 0
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            verify_n += 1
            if "screening" in r:
                remaining_screening += 1
            p = r.get("provenance")
            if isinstance(p, dict):
                for key in SCREENING_PROVENANCE_KEYS:
                    if key in p:
                        remaining_provenance[key] += 1

    if verify_n != counts["records_in"]:
        raise SystemExit(f"Verification record-count mismatch: {verify_n} != {counts['records_in']}")
    if remaining_screening or any(remaining_provenance.values()):
        raise SystemExit(
            f"Screening state remains after reset: screening={remaining_screening}, provenance={remaining_provenance}"
        )

    counts["verification"] = {
        "records_verified": verify_n,
        "remaining_screening_objects": remaining_screening,
        "remaining_screening_provenance": remaining_provenance,
        "records_removed": 0,
    }
    summary_path.write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(counts, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
