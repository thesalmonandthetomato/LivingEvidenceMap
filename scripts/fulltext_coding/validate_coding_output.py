#!/usr/bin/env python3
"""Validate full-text coding JSON against Coding Schema v1."""
from __future__ import annotations
import argparse, json
from pathlib import Path

SCHEMA_KEYS = {
    "schema_version", "source_id", "doi", "openalex_id", "title", "year", "document_type",
    "review_type", "study_design", "research_approach", "setting", "sample_size", "sample_unit",
    "study_period", "location_region", "location_country", "species", "population",
    "outcome_measured", "intervention", "comparator", "research_question", "objectives_summary",
    "ontology_codes", "evidence", "run_metadata"
}
DOCUMENT_TYPES = {"study", "review", "systematic_review", "perspective", "commentary", "editorial", "book", "book_chapter", "report", "thesis", "protocol", "other"}
REVIEW_TYPES = {"systematic", "non_systematic", "not_applicable"}


def validate(record: dict) -> list[str]:
    errors = []
    missing = sorted((SCHEMA_KEYS - {"schema_version"}) - set(record))
    extra = sorted(set(record) - SCHEMA_KEYS)
    if missing: errors.append(f"missing top-level fields: {missing}")
    if extra: errors.append(f"unexpected top-level fields: {extra}")
    if record.get("schema_version") != "fulltext_coding_v1": errors.append("schema_version must be 'fulltext_coding_v1'")
    if record.get("document_type") not in DOCUMENT_TYPES: errors.append(f"invalid document_type: {record.get('document_type')!r}")
    if record.get("review_type") not in REVIEW_TYPES: errors.append(f"invalid review_type: {record.get('review_type')!r}")
    if record.get("document_type") == "review" and record.get("review_type") == "not_applicable": errors.append("review requires systematic or non_systematic review_type")
    if record.get("document_type") != "review" and record.get("review_type") != "not_applicable": errors.append("review_type must be not_applicable unless document_type is review")
    for field in ("species", "population", "outcome_measured", "ontology_codes", "evidence"):
        if field in record and not isinstance(record[field], list): errors.append(f"{field} must be a JSON array")
    if isinstance(record.get("objectives_summary"), str) and not record["objectives_summary"].strip(): errors.append("objectives_summary is empty")
    if not isinstance(record.get("run_metadata"), dict): errors.append("run_metadata must be an object")
    else:
        for key in ("schema_version", "ontology_version", "model", "provider", "timestamp_utc"):
            if key not in record["run_metadata"]: errors.append(f"run_metadata missing {key}")
    if isinstance(record.get("evidence"), list):
        for i, item in enumerate(record["evidence"]):
            if not isinstance(item, dict): errors.append(f"evidence[{i}] is not an object"); continue
            for key in ("field", "value", "text", "section", "page"):
                if key not in item: errors.append(f"evidence[{i}] missing {key}")
    else: errors.append("evidence must be an array")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); args = parser.parse_args()
    errors = validate(json.loads(args.input.read_text(encoding="utf-8")))
    if errors:
        print("INVALID"); [print(f"- {e}") for e in errors]; return 1
    print("VALID"); return 0

if __name__ == "__main__": raise SystemExit(main())
