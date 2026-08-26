#!/usr/bin/env python3
"""Verify that schema, prompt scope and validator use the same current fields/vocabularies."""
from __future__ import annotations
import ast, json, re
from pathlib import Path

CURRENT_FIELDS = {
    "document_type", "review_type", "study_type", "study_design", "research_approach", "setting", "sample_unit",
    "study_period", "location_region", "location_country", "species", "other_farmed_species", "study_population",
    "aquaculture_facility", "system_studied", "production_stage", "fish_life_stage", "exposure_intervention",
    "comparator", "outcome_measured", "impact_type", "impact_details", "funding_body", "research_question",
    "objectives_summary", "ontology_codes", "multiple_studies_flag", "multiple_studies_reason"
}
PROHIBITED_FIELDS = {
    "sample_size", "methodology_for_data_collection", "funder", "intervention", "exposure", "source_id",
    "openalex_id", "doi", "title", "year", "schema_version", "run_metadata", "non_methods_results_evidence",
    "non_methods_results_evidence_fields"
}


def load_validator_constants(path: Path) -> dict[str, set[str]]:
    text = path.read_text(encoding="utf-8")
    out = {}
    for name in ["DOCUMENT_TYPES","REVIEW_TYPES","STUDY_TYPES","STUDY_DESIGNS","RESEARCH_APPROACHES","SETTINGS","PRODUCTION_STAGES","AQUACULTURE_FACILITIES","SPECIES"]:
        m = re.search(rf"^{name}\s*=\s*(\{{.*?\}})", text, flags=re.M)
        if not m: raise ValueError(f"Validator constant not found: {name}")
        out[name] = set(ast.literal_eval(m.group(1)))
    return out


def main() -> int:
    import argparse
    ap=argparse.ArgumentParser(); ap.add_argument("--schema",type=Path,required=True); ap.add_argument("--validator",type=Path,required=True); args=ap.parse_args()
    schema=json.loads(args.schema.read_text(encoding="utf-8")); validator=load_validator_constants(args.validator)
    errors=[]
    schema_fields=set(schema.get("fields",{}))
    if schema_fields != CURRENT_FIELDS:
        errors.append(f"schema field mismatch: schema_only={sorted(schema_fields-CURRENT_FIELDS)}, missing={sorted(CURRENT_FIELDS-schema_fields)}")
    leaked=sorted(schema_fields & PROHIBITED_FIELDS)
    if leaked: errors.append(f"prohibited legacy fields remain in schema: {leaked}")
    mapping={"document_type":"DOCUMENT_TYPES","review_type":"REVIEW_TYPES","study_type":"STUDY_TYPES","study_design":"STUDY_DESIGNS","research_approach":"RESEARCH_APPROACHES","setting":"SETTINGS","production_stage":"PRODUCTION_STAGES","aquaculture_facility":"AQUACULTURE_FACILITIES","species":"SPECIES"}
    for field,const in mapping.items():
        if field not in schema: errors.append(f"schema missing controlled vocabulary: {field}"); continue
        if set(schema[field]) != validator[const]:
            errors.append(f"{field} mismatch: schema_only={sorted(set(schema[field])-validator[const])}, validator_only={sorted(validator[const]-set(schema[field]))}")
    if errors:
        print("PREFLIGHT FAILED"); [print(f"- {e}") for e in errors]; return 1
    print("PREFLIGHT PASSED: exact current field scope and vocabularies are synchronized")
    return 0

if __name__ == "__main__": raise SystemExit(main())
