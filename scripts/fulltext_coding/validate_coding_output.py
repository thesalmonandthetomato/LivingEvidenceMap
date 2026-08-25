#!/usr/bin/env python3
"""Validate full-text coding JSON against the closed coding schema."""
from __future__ import annotations
import argparse, json
from pathlib import Path

SCHEMA_KEYS = {
    "schema_version", "source_id", "doi", "openalex_id", "title", "year", "document_type",
    "review_type", "study_type", "study_design", "research_approach", "setting", "sample_size", "sample_unit",
    "study_period", "location_region", "location_country", "species", "study_population", "aquaculture_facility",
    "system_studied", "production_stage", "impact_type", "impact_details", "outcome_measured",
    "impact_pathway", "mitigation_evaluation", "intervention", "exposure", "comparator",
    "methodology_for_data_collection", "funding_body", "funder", "research_question", "objectives_summary",
    "ontology_codes", "evidence", "run_metadata"
}
DOCUMENT_TYPES = {"study", "review", "systematic_review", "perspective", "commentary", "editorial", "book", "book_chapter", "report", "thesis", "protocol", "other"}
REVIEW_TYPES = {"systematic", "non_systematic", "not_applicable"}
STUDY_TYPES = {"experimental", "observational", "modelling", "not_stated", "not_applicable"}
STUDY_DESIGNS = {"BA", "CI", "BACI", "RCT", "Time-series", "Modelling", "Qualitative", "not_stated", "not_applicable"}
RESEARCH_APPROACHES = {"quantitative", "qualitative", "mixed_methods", "not_applicable"}
SETTINGS = {"field", "laboratory", "in_vitro", "in_silico"}
PRODUCTION_STAGES = {"Feed", "Roe", "Fry", "Smolt", "Adult", "Processing"}
AQUACULTURE_FACILITIES = {"salmon_farming_region", "hatchery", "open_cages", "closed_cages", "land_based"}


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
    if record.get("study_type") not in STUDY_TYPES: errors.append(f"invalid study_type: {record.get('study_type')!r}")
    if not isinstance(record.get("study_design"), list): errors.append("study_design must be a JSON array")
    elif any(v not in STUDY_DESIGNS for v in record["study_design"]): errors.append(f"invalid study_design value(s): {[v for v in record['study_design'] if v not in STUDY_DESIGNS]}")
    if record.get("research_approach") not in RESEARCH_APPROACHES: errors.append(f"invalid research_approach: {record.get('research_approach')!r}")
    for field in ("setting", "species", "aquaculture_facility", "production_stage", "impact_type", "outcome_measured", "impact_pathway", "methodology_for_data_collection", "ontology_codes", "evidence"):
        if field in record and not isinstance(record[field], list): errors.append(f"{field} must be a JSON array")
    if isinstance(record.get("setting"), list):
        bad=set(record["setting"])-SETTINGS
        if bad: errors.append(f"invalid setting value(s): {sorted(bad)}")
    if isinstance(record.get("production_stage"), list):
        bad=set(record["production_stage"])-PRODUCTION_STAGES
        if bad: errors.append(f"invalid production_stage value(s): {sorted(bad)}")
    if isinstance(record.get("aquaculture_facility"), list):
        bad=set(record["aquaculture_facility"])-AQUACULTURE_FACILITIES
        if bad: errors.append(f"invalid aquaculture_facility value(s): {sorted(bad)}")
        if record.get("setting") and "laboratory" in record["setting"] and record["aquaculture_facility"]:
            errors.append("laboratory studies must have empty aquaculture_facility unless the paper explicitly states that the research was conducted within a listed aquaculture production facility")
    if record.get("document_type") in {"commentary", "editorial", "perspective", "book", "book_chapter"}:
        # These documents may discuss primary studies, but should not inherit their empirical methods/data.
        if record.get("sample_size") is not None: errors.append("non-primary document type should not inherit sample_size from discussed studies")
    if record.get("intervention") is not None and record.get("exposure") is not None:
        # Both are allowed only for the explicitly rare impact-plus-mitigation case; flag for manual review.
        if not record.get("mitigation_evaluation"): errors.append("intervention and exposure both populated without mitigation_evaluation; review the priority rule")
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
