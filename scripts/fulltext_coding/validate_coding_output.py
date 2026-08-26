#!/usr/bin/env python3
"""Deterministic structural validator for LivingEvidenceMap full-text coding JSON.

This validator is intentionally narrow. It checks JSON/schema shape, closed vocabularies,
required types, forbidden legacy fields, and deterministic completeness bookkeeping.
It does NOT make scientific, document-completeness, or semantic judgements.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path

SCHEMA_KEYS = {
    "schema_version", "source_id", "doi", "openalex_id", "title", "year", "document_type",
    "review_type", "study_type", "study_design", "research_approach", "setting", "sample_size", "sample_unit",
    "study_period", "location_region", "location_country", "species", "other_farmed_species", "study_population", "aquaculture_facility",
    "system_studied", "production_stage", "fish_life_stage", "impact_type", "impact_details", "outcome_measured",
    "exposure_intervention", "comparator", "methodology_for_data_collection", "funding_body", "funder",
    "research_question", "objectives_summary", "ontology_codes", "multiple_studies_flag", "multiple_studies_reason",
    "document_completeness_evidence", "non_methods_results_evidence", "non_methods_results_evidence_fields", "not_reported_fields",
    "field_completeness", "evidence", "run_metadata"
}
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
COMPLETENESS_STATUSES = {None, "NOT FOUND"}
SUBSTANTIVE_FIELDS = {
    "document_type", "review_type", "study_type", "study_design", "research_approach", "setting",
    "sample_size", "sample_unit", "study_period", "location_region", "location_country", "species",
    "other_farmed_species", "study_population", "aquaculture_facility", "system_studied", "production_stage",
    "fish_life_stage", "impact_type", "impact_details", "outcome_measured", "exposure_intervention",
    "comparator", "methodology_for_data_collection", "funding_body", "funder", "research_question",
    "objectives_summary", "ontology_codes", "multiple_studies_flag", "multiple_studies_reason"
}


def _is_empty(value) -> bool:
    return value in (None, "", [], {})


def validate(record: dict) -> list[str]:
    errors = []

    missing = sorted(SCHEMA_KEYS - set(record))
    extra = sorted(set(record) - SCHEMA_KEYS)
    if missing:
        errors.append(f"missing top-level fields: {missing}")
    if extra:
        errors.append(f"unexpected top-level fields: {extra}")
    if record.get("schema_version") != "fulltext_coding_v1":
        errors.append("schema_version must be 'fulltext_coding_v1'")

    # These are always structural requirements, including for an explicitly incomplete document.
    if not isinstance(record.get("source_id"), str) or not record["source_id"].strip():
        errors.append("source_id must be a non-empty string")
    if not isinstance(record.get("run_metadata"), dict):
        errors.append("run_metadata must be an object")
    else:
        for key in ("schema_version", "ontology_version", "model", "provider", "timestamp_utc"):
            if key not in record["run_metadata"]:
                errors.append(f"run_metadata missing {key}")
    if "mitigation_evaluation" in record: errors.append("legacy field mitigation_evaluation is prohibited")
    if "intervention" in record or "exposure" in record: errors.append("legacy separate intervention/exposure fields are prohibited; use exposure_intervention")

    # An explicitly incomplete document is a controlled workflow state. The validator does not
    # decide whether that state is scientifically justified; it only checks that the state is
    # represented with the required evidence and otherwise leaves its substantive fields alone.
    if record.get("document_type") is None:
        if not isinstance(record.get("document_completeness_evidence"), str) or not record["document_completeness_evidence"].strip():
            errors.append("incomplete-document record requires document_completeness_evidence")
        return errors

    if record.get("document_type") not in DOCUMENT_TYPES:
        errors.append(f"invalid document_type: {record.get('document_type')!r}")
    if record.get("review_type") not in REVIEW_TYPES:
        errors.append(f"invalid review_type: {record.get('review_type')!r}")
    if record.get("study_type") not in STUDY_TYPES:
        errors.append(f"invalid study_type: {record.get('study_type')!r}")
    if record.get("research_approach") not in RESEARCH_APPROACHES:
        errors.append(f"invalid research_approach: {record.get('research_approach')!r}")

    if record.get("doi") is not None and not isinstance(record.get("doi"), str): errors.append("doi must be string or null")
    if record.get("openalex_id") is not None and not isinstance(record.get("openalex_id"), str): errors.append("openalex_id must be string or null")
    if record.get("title") is not None and not isinstance(record.get("title"), str): errors.append("title must be string or null")
    if record.get("year") is not None and not isinstance(record.get("year"), int): errors.append("year must be integer or null")

    array_fields = (
        "study_design", "setting", "sample_unit", "species", "other_farmed_species", "aquaculture_facility",
        "production_stage", "fish_life_stage", "impact_type", "outcome_measured", "methodology_for_data_collection",
        "ontology_codes", "non_methods_results_evidence_fields", "not_reported_fields", "evidence"
    )
    for field in array_fields:
        if not isinstance(record.get(field), list):
            errors.append(f"{field} must be a JSON array")

    if record.get("sample_size") is not None and not isinstance(record.get("sample_size"), (int, float, str)):
        errors.append("sample_size must be number, string, or null")
    for field in ("study_period", "location_region", "location_country", "study_population", "system_studied", "impact_details", "exposure_intervention", "comparator", "funding_body", "funder", "research_question", "objectives_summary", "multiple_studies_reason", "document_completeness_evidence"):
        if record.get(field) is not None and not isinstance(record.get(field), str):
            errors.append(f"{field} must be string or null")

    if not record.get("species") or any(v not in SPECIES for v in record["species"]):
        errors.append("species must be a non-empty array containing only closed-vocabulary species")
    if any(v not in STUDY_DESIGNS for v in record["study_design"]): errors.append("invalid study_design value(s)")
    if any(v not in SETTINGS for v in record["setting"]): errors.append("invalid setting value(s)")
    if any(v not in PRODUCTION_STAGES for v in record["production_stage"]): errors.append("invalid production_stage value(s)")
    if any(v not in FISH_LIFE_STAGES for v in record["fish_life_stage"]): errors.append("invalid fish_life_stage value(s)")
    if any(v not in AQUACULTURE_FACILITIES for v in record["aquaculture_facility"]): errors.append("invalid aquaculture_facility value(s)")
    if not all(isinstance(v, str) and v.strip() for v in record["sample_unit"]): errors.append("sample_unit must contain non-empty strings")
    if not all(isinstance(v, str) and v.strip() for v in record["other_farmed_species"]): errors.append("other_farmed_species must contain non-empty strings")

    if not isinstance(record.get("multiple_studies_flag"), bool): errors.append("multiple_studies_flag must be boolean")
    if not isinstance(record.get("non_methods_results_evidence"), bool): errors.append("non_methods_results_evidence must be boolean")
    if not all(isinstance(v, str) and v.strip() for v in record["not_reported_fields"]): errors.append("not_reported_fields must contain non-empty strings")

    # Completeness is deterministic bookkeeping only. No scientific judgement is made here.
    fc = record.get("field_completeness")
    if not isinstance(fc, dict):
        errors.append("field_completeness must be an object")
    else:
        extra_fc = sorted(set(fc) - SUBSTANTIVE_FIELDS)
        if extra_fc:
            errors.append(f"field_completeness has unexpected fields: {extra_fc}")
        bad_status = {k: v for k, v in fc.items() if v not in COMPLETENESS_STATUSES}
        if bad_status:
            errors.append(f"invalid field_completeness status(es); only null or 'NOT FOUND' are permitted: {bad_status}")
        expected_not_reported = sorted(k for k, v in fc.items() if v == "NOT FOUND")
        actual_not_reported = sorted(set(record["not_reported_fields"]))
        if expected_not_reported != actual_not_reported:
            errors.append(f"not_reported_fields does not match field_completeness: expected {expected_not_reported}, got {actual_not_reported}")
        for field, status in fc.items():
            if field not in record:
                errors.append(f"field_completeness references missing field: {field}")
            elif status == "NOT FOUND" and not _is_empty(record.get(field)):
                errors.append(f"field_completeness says NOT FOUND but {field} is populated")
            elif status is None and not _is_empty(record.get(field)):
                errors.append(f"field_completeness says null/inapplicable but {field} is populated")
        for field in SUBSTANTIVE_FIELDS:
            if field in fc and field in record and not _is_empty(record.get(field)):
                errors.append(f"populated field {field} must be omitted from field_completeness")
        if any(v == "FOUND" for v in fc.values()):
            errors.append("FOUND is prohibited in field_completeness")

    for i, item in enumerate(record["evidence"]):
        if not isinstance(item, dict):
            errors.append(f"evidence[{i}] is not an object")
            continue
        for key in ("field", "value", "text", "section", "page"):
            if key not in item: errors.append(f"evidence[{i}] missing {key}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    try:
        record = json.loads(args.input.read_text(encoding="utf-8"))
    except Exception as exc:
        print("INVALID")
        print(f"- invalid JSON: {exc}")
        return 1
    if not isinstance(record, dict):
        print("INVALID")
        print("- top-level JSON value must be an object")
        return 1
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
