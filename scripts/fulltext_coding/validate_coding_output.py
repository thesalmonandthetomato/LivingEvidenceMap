#!/usr/bin/env python3
"""Deterministic validator for the current LivingEvidenceMap full-text coding output."""
from __future__ import annotations
import argparse, json
from pathlib import Path

CURRENT_FIELDS = {
    "document_type", "review_type", "study_type", "study_design", "research_approach", "setting",
    "sample_unit", "study_period", "location_region", "location_country", "species", "other_farmed_species",
    "study_population", "aquaculture_facility", "system_studied", "production_stage", "fish_life_stage",
    "exposure_intervention", "comparator", "outcome_measured", "funding_body", "research_question",
    "objectives_summary", "ontology_codes", "multiple_studies_flag", "multiple_studies_reason"
}
AUDIT_FIELDS = {"field_completeness", "not_reported_fields", "evidence", "document_completeness_evidence"}
ALLOWED_TOP_LEVEL = CURRENT_FIELDS | AUDIT_FIELDS
DOCUMENT_TYPES = {"study", "review", "perspective", "commentary", "editorial", "book", "book_chapter", "report", "thesis", "protocol", "other"}
REVIEW_TYPES = {"primer_overview", "systematic_style", "not_applicable"}
STUDY_TYPES = {"experimental", "observational", "modelling", "not_stated", "not_applicable"}
STUDY_DESIGNS = {"BA", "CI", "BACI", "RCT", "Time-series", "Modelling", "Qualitative", "not_stated", "not_applicable"}
RESEARCH_APPROACHES = {"quantitative", "qualitative", "mixed_methods", "not_applicable"}
SETTINGS = {"field", "laboratory/controlled facility", "in_vitro", "in_silico"}
PRODUCTION_STAGES = {"Feed", "Hatchery", "Transfer between Hatchery and Adult", "Adult grow-out", "Processing"}
FISH_LIFE_STAGES = {"Sperm", "Egg", "Embryo", "Alevin", "Fry", "Parr", "Pre-smolt", "Smolt", "Juvenile", "Adult", "Broodstock", "Harvest", "Product"}
AQUACULTURE_FACILITIES = {"salmon_farming_region", "hatchery", "open_cages", "closed_cages", "land_based", "land_based_RAS"}
SPECIES = {"Atlantic salmon", "chum salmon", "pink salmon", "coho salmon", "chinook salmon", "sockeye salmon", "masu salmon", "rainbow trout", "unspecified salmon species"}


def _empty(v):
    return v in (None, "", [], {})


def validate(record: dict) -> list[str]:
    errors = []
    if not isinstance(record, dict):
        return ["top-level output must be a JSON object"]
    extra = sorted(set(record) - ALLOWED_TOP_LEVEL)
    missing = sorted(CURRENT_FIELDS - set(record))
    if extra: errors.append(f"unexpected top-level fields: {extra}")
    if missing: errors.append(f"missing current extraction fields: {missing}")
    if record.get("document_type") is None:
        if any(k in record and not _empty(record[k]) for k in CURRENT_FIELDS if k != "document_type"):
            errors.append("incomplete document must not contain substantive extraction values")
        if not isinstance(record.get("document_completeness_evidence"), str) or not record["document_completeness_evidence"].strip():
            errors.append("incomplete document requires document_completeness_evidence")
        return errors
    if record.get("document_type") not in DOCUMENT_TYPES: errors.append(f"invalid document_type: {record.get('document_type')!r}")
    if record.get("review_type") not in REVIEW_TYPES: errors.append(f"invalid review_type: {record.get('review_type')!r}")
    if record.get("document_type") == "review" and record.get("review_type") == "not_applicable": errors.append("review requires a review_type")
    if record.get("document_type") != "review" and record.get("review_type") != "not_applicable": errors.append("review_type must be not_applicable unless document_type is review")
    if record.get("study_type") not in STUDY_TYPES: errors.append(f"invalid study_type: {record.get('study_type')!r}")
    if not isinstance(record.get("study_design"), list) or any(v not in STUDY_DESIGNS for v in record.get("study_design", [])): errors.append("study_design must be an array containing only controlled values")
    if record.get("research_approach") not in RESEARCH_APPROACHES: errors.append(f"invalid research_approach: {record.get('research_approach')!r}")
    for field in ("setting", "species", "other_farmed_species", "sample_unit", "aquaculture_facility", "production_stage", "fish_life_stage", "outcome_measured", "ontology_codes", "not_reported_fields", "evidence"):
        if not isinstance(record.get(field), list): errors.append(f"{field} must be a JSON array")
    if not isinstance(record.get("species"), list) or not record["species"]: errors.append("species must be a non-empty array")
    elif any(v not in SPECIES for v in record["species"]): errors.append(f"invalid species value(s): {[v for v in record['species'] if v not in SPECIES]}")
    for field, allowed in (("setting", SETTINGS), ("production_stage", PRODUCTION_STAGES), ("fish_life_stage", FISH_LIFE_STAGES), ("aquaculture_facility", AQUACULTURE_FACILITIES)):
        if isinstance(record.get(field), list):
            bad = set(record[field]) - allowed
            if bad: errors.append(f"invalid {field} value(s): {sorted(bad)}")
    if not isinstance(record.get("multiple_studies_flag"), bool): errors.append("multiple_studies_flag must be boolean")
    if record.get("multiple_studies_flag"):
        if not isinstance(record.get("multiple_studies_reason"), str) or not record["multiple_studies_reason"].strip(): errors.append("multiple_studies_flag=true requires multiple_studies_reason")
    elif record.get("multiple_studies_reason") is not None: errors.append("multiple_studies_reason must be null when multiple_studies_flag=false")
    fc = record.get("field_completeness")
    if not isinstance(fc, dict): errors.append("field_completeness must be an object")
    else:
        extra_fc = sorted(set(fc) - CURRENT_FIELDS)
        if extra_fc: errors.append(f"field_completeness has prohibited/non-current fields: {extra_fc}")
        bad_status = {k: v for k, v in fc.items() if v not in (None, "NOT FOUND")}
        if bad_status: errors.append(f"invalid field_completeness status(es): {bad_status}")
        expected_nr = sorted(k for k, v in fc.items() if v == "NOT FOUND")
        actual_nr = sorted(set(record.get("not_reported_fields", [])))
        if expected_nr != actual_nr: errors.append(f"not_reported_fields mismatch: expected {expected_nr}, got {actual_nr}")
        for field, status in fc.items():
            if status == "NOT FOUND" and not _empty(record.get(field)): errors.append(f"field_completeness says NOT FOUND but {field} is populated")
            if status is None and field not in {"review_type", "multiple_studies_reason"} and not _empty(record.get(field)): errors.append(f"field_completeness says null/inapplicable but {field} is populated")
    if isinstance(record.get("evidence"), list):
        evidence_fields = {item.get("field") for item in record["evidence"] if isinstance(item, dict)}
        for i, item in enumerate(record["evidence"]):
            if not isinstance(item, dict): errors.append(f"evidence[{i}] is not an object"); continue
            for key in ("field", "value", "text", "section", "page"):
                if key not in item: errors.append(f"evidence[{i}] missing {key}")
            if item.get("field") not in CURRENT_FIELDS: errors.append(f"evidence[{i}] references non-current field {item.get('field')!r}")
            if not isinstance(item.get("text"), str) or not item.get("text", "").strip(): errors.append(f"evidence[{i}] requires article-text evidence")
        for field in CURRENT_FIELDS:
            value = record.get(field)
            if field == "review_type" and value == "not_applicable": continue
            if field == "multiple_studies_reason" and value is None: continue
            if _empty(value): continue
            if field not in evidence_fields: errors.append(f"populated current field lacks field-specific evidence: {field}")
    if any(x in record for x in ("sample_size", "methodology_for_data_collection", "funder", "intervention", "exposure", "impact_type", "impact_details")):
        errors.append("legacy/removed extraction field present; remove it")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); args = parser.parse_args()
    errors = validate(json.loads(args.input.read_text(encoding="utf-8")))
    if errors:
        print("INVALID"); [print(f"- {e}") for e in errors]; return 1
    print("VALID"); return 0

if __name__ == "__main__": raise SystemExit(main())
