#!/usr/bin/env python3
"""Validate full-text coding JSON against Coding Schema v1.

This is deliberately a structural validator, not a substantive adjudicator.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

SCHEMA_KEYS = {
    "source_id", "doi", "openalex_id", "title", "year", "document_type",
    "contribution_type", "review_type", "study_design", "research_approach",
    "setting", "sample_size", "sample_unit", "study_period", "location_region",
    "location_country", "species", "population", "outcome_measured",
    "intervention", "comparator", "research_question", "objectives_summary",
    "ontology_codes", "evidence", "run_metadata"
}


def validate(record: dict) -> list[str]:
    errors: list[str] = []
    missing = sorted(SCHEMA_KEYS - set(record))
    extra = sorted(set(record) - SCHEMA_KEYS)
    if missing:
        errors.append(f"missing top-level fields: {missing}")
    if extra:
        errors.append(f"unexpected top-level fields: {extra}")
    for field in ("species", "population", "outcome_measured", "ontology_codes", "evidence"):
        if field in record and not isinstance(record[field], list):
            errors.append(f"{field} must be a JSON array")
    if isinstance(record.get("objectives_summary"), str) and len(record["objectives_summary"].strip()) == 0:
        errors.append("objectives_summary is empty")
    if isinstance(record.get("evidence"), list):
        for i, item in enumerate(record["evidence"]):
            if not isinstance(item, dict):
                errors.append(f"evidence[{i}] is not an object")
                continue
            for key in ("field", "value", "text", "section", "page"):
                if key not in item:
                    errors.append(f"evidence[{i}] missing {key}")
    else:
        errors.append("evidence must be an array")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    record = json.loads(args.input.read_text(encoding="utf-8"))
    errors = validate(record)
    if errors:
        print("INVALID")
        for error in errors:
            print(f"- {error}")
        return 1
    print("VALID")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
