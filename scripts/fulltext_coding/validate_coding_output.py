#!/usr/bin/env python3
"""Validate LivingEvidenceMap full-text coding JSON against the closed schema."""
from __future__ import annotations
import argparse, json
from pathlib import Path

SCHEMA_KEYS = {
    "schema_version", "source_id", "doi", "openalex_id", "title", "year", "document_type",
    "review_type", "study_type", "study_design", "research_approach", "setting", "sample_size", "sample_unit",
    "study_period", "location_region", "location_country", "species", "other_farmed_species", "study_population", "aquaculture_facility",
    "system_studied", "production_stage", "fish_life_stage", "impact_type", "impact_details", "outcome_measured",
    "intervention", "exposure", "comparator", "methodology_for_data_collection", "funding_body", "funder",
    "research_question", "objectives_summary", "ontology_codes", "multiple_studies_flag", "multiple_studies_reason",
    "document_completeness_evidence", "non_methods_results_evidence", "non_methods_results_evidence_fields", "not_reported_fields",
    "evidence", "run_metadata"
}
DOCUMENT_TYPES = {"study", "review", "perspective", "commentary", "editorial", "book", "book_chapter", "report", "thesis", "protocol", "other"}
REVIEW_TYPES = {"primer_overview", "systematic_style", "not_applicable"}
STUDY_TYPES = {"experimental", "observational", "modelling", "not_stated", "not_applicable"}
STUDY_DESIGNS = {"BA", "CI", "BACI", "RCT", "Time-series", "Modelling", "Qualitative", "not_stated", "not_applicable"}
RESEARCH_APPROACHES = {"quantitative", "qualitative", "mixed_methods", "not_applicable"}
SETTINGS = {"field", "laboratory/controlled facility", "in_vitro", "in_silico"}
PRODUCTION_STAGES = {"Feed", "Hatchery", "Transfer between Hatchery and Adult", "Adult grow-out", "Processing"}
FISH_LIFE_STAGES = {"Sperm", "Egg", "Embryo", "Alevin", "Fry", "Parr", "Smolt", "Juvenile", "Adult", "Broodstock", "Harvest", "Product"}
AQUACULTURE_FACILITIES = {"salmon_farming_region", "hatchery", "open_cages", "closed_cages", "land_based", "land_based_RAS"}
SPECIES = {"Atlantic salmon", "chum salmon", "pink salmon", "coho salmon", "chinook salmon", "sockeye salmon", "masu salmon", "rainbow trout", "unspecified salmon species"}


def validate(record: dict) -> list[str]:
    errors = []
    missing = sorted((SCHEMA_KEYS - {"schema_version"}) - set(record))
    extra = sorted(set(record) - SCHEMA_KEYS)
    if missing: errors.append(f"missing top-level fields: {missing}")
    if extra: errors.append(f"unexpected top-level fields: {extra}")
    if record.get("schema_version") != "fulltext_coding_v1": errors.append("schema_version must be 'fulltext_coding_v1'")

    # Incomplete documents may retain workflow-supplied provenance/identity metadata,
    # but no substantive coding. Validation must not fail merely because provenance exists.
    if record.get("document_type") is None:
        exempt = {"schema_version", "source_id", "doi", "openalex_id", "title", "year", "document_type", "run_metadata", "document_completeness_evidence", "non_methods_results_evidence", "non_methods_results_evidence_fields", "not_reported_fields"}
        nonempty = []
        for k, v in record.items():
            if k in exempt: continue
            if v not in (None, "", [], {}): nonempty.append(k)
        if nonempty: errors.append(f"incomplete-document record has populated substantive fields: {nonempty}")
        if record.get("evidence") not in (None, []): errors.append("incomplete-document record must have empty evidence")
        if not isinstance(record.get("document_completeness_evidence"), str) or not record["document_completeness_evidence"].strip():
            errors.append("incomplete-document record requires document_completeness_evidence")
        return errors

    if record.get("document_type") not in DOCUMENT_TYPES: errors.append(f"invalid document_type: {record.get('document_type')!r}")
    if record.get("review_type") not in REVIEW_TYPES: errors.append(f"invalid review_type: {record.get('review_type')!r}")
    if record.get("document_type") == "review" and record.get("review_type") == "not_applicable": errors.append("review requires primer_overview or systematic_style review_type")
    if record.get("document_type") != "review" and record.get("review_type") != "not_applicable": errors.append("review_type must be not_applicable unless document_type is review")
    if record.get("study_type") not in STUDY_TYPES: errors.append(f"invalid study_type: {record.get('study_type')!r}")
    if not isinstance(record.get("study_design"), list): errors.append("study_design must be a JSON array")
    elif any(v not in STUDY_DESIGNS for v in record["study_design"]): errors.append(f"invalid study_design value(s): {[v for v in record['study_design'] if v not in STUDY_DESIGNS]}")
    if record.get("research_approach") not in RESEARCH_APPROACHES: errors.append(f"invalid research_approach: {record.get('research_approach')!r}")

    array_fields = ("setting", "species", "other_farmed_species", "sample_unit", "aquaculture_facility", "production_stage", "fish_life_stage", "impact_type", "outcome_measured", "methodology_for_data_collection", "ontology_codes", "evidence", "non_methods_results_evidence_fields", "not_reported_fields")
    for field in array_fields:
        if field in record and not isinstance(record[field], list): errors.append(f"{field} must be a JSON array")

    if "species" not in record or not isinstance(record.get("species"), list) or not record["species"]:
        errors.append("species must be a non-empty array and may never be null")
    elif any(v not in SPECIES for v in record["species"]):
        errors.append(f"invalid species value(s): {[v for v in record['species'] if v not in SPECIES]}")
    if isinstance(record.get("setting"), list):
        bad=set(record["setting"])-SETTINGS
        if bad: errors.append(f"invalid setting value(s): {sorted(bad)}")
    if isinstance(record.get("production_stage"), list):
        bad=set(record["production_stage"])-PRODUCTION_STAGES
        if bad: errors.append(f"invalid production_stage value(s): {sorted(bad)}")
    if isinstance(record.get("fish_life_stage"), list):
        bad=set(record["fish_life_stage"])-FISH_LIFE_STAGES
        if bad: errors.append(f"invalid fish_life_stage value(s): {sorted(bad)}")
    if isinstance(record.get("aquaculture_facility"), list):
        bad=set(record["aquaculture_facility"])-AQUACULTURE_FACILITIES
        if bad: errors.append(f"invalid aquaculture_facility value(s): {sorted(bad)}")
        if record.get("setting") and "in_vitro" in record["setting"] and record["aquaculture_facility"]:
            errors.append("in_vitro studies should have null/empty aquaculture_facility unless the facility itself is explicitly the object/context of study")

    if record.get("document_type") in {"commentary", "editorial", "perspective", "book", "book_chapter"}:
        if record.get("sample_size") is not None: errors.append("non-primary document type should not inherit sample_size from discussed studies")

    if not isinstance(record.get("multiple_studies_flag"), bool): errors.append("multiple_studies_flag must be boolean")
    if record.get("multiple_studies_flag") and not isinstance(record.get("multiple_studies_reason"), str): errors.append("multiple_studies_flag=true requires multiple_studies_reason")

    if not isinstance(record.get("non_methods_results_evidence"), bool): errors.append("non_methods_results_evidence must be boolean")
    if not isinstance(record.get("non_methods_results_evidence_fields"), list): errors.append("non_methods_results_evidence_fields must be an array")
    elif not record.get("non_methods_results_evidence") and record["non_methods_results_evidence_fields"]:
        errors.append("non_methods_results_evidence_fields must be empty when non_methods_results_evidence=false")
    elif record.get("non_methods_results_evidence") and not record["non_methods_results_evidence_fields"]:
        errors.append("non_methods_results_evidence=true requires at least one affected field")

    if not isinstance(record.get("not_reported_fields"), list): errors.append("not_reported_fields must be an array")
    elif any(not isinstance(v, str) or not v.strip() for v in record["not_reported_fields"]): errors.append("not_reported_fields must contain non-empty field names")

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

    # Legacy-field guard: mitigation_evaluation must never return to the schema.
    if "mitigation_evaluation" in record: errors.append("legacy field mitigation_evaluation is prohibited")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); args = parser.parse_args()
    errors = validate(json.loads(args.input.read_text(encoding="utf-8")))
    if errors:
        print("INVALID"); [print(f"- {e}") for e in errors]; return 1
    print("VALID"); return 0
    
if __name__ == "__main__": raise SystemExit(main())
