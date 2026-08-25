#!/usr/bin/env python3
"""Verify that the coding schema and validator use the same closed vocabularies."""
from __future__ import annotations
import ast, json, re, sys
from pathlib import Path


def load_schema(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_validator_constants(path: Path) -> dict[str, set[str]]:
    text = path.read_text(encoding="utf-8")
    out = {}
    for name in ["DOCUMENT_TYPES","REVIEW_TYPES","STUDY_TYPES","STUDY_DESIGNS","RESEARCH_APPROACHES","SETTINGS","PRODUCTION_STAGES","AQUACULTURE_FACILITIES","SPECIES"]:
        m = re.search(rf"^{name}\s*=\s*(\{{.*?\}})", text, flags=re.M)
        if not m:
            raise ValueError(f"Validator constant not found: {name}")
        out[name] = set(ast.literal_eval(m.group(1)))
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", type=Path, required=True)
    ap.add_argument("--validator", type=Path, required=True)
    args = ap.parse_args()
    schema = load_schema(args.schema)
    validator = load_validator_constants(args.validator)
    mapping = {
        "document_type": "DOCUMENT_TYPES",
        "review_type": "REVIEW_TYPES",
        "study_type": "STUDY_TYPES",
        "study_design": "STUDY_DESIGNS",
        "research_approach": "RESEARCH_APPROACHES",
        "setting": "SETTINGS",
        "production_stage": "PRODUCTION_STAGES",
        "aquaculture_facility": "AQUACULTURE_FACILITIES",
        "species": "SPECIES",
    }
    errors = []
    for field, const in mapping.items():
        if field not in schema:
            errors.append(f"schema missing controlled vocabulary: {field}")
            continue
        schema_values = set(schema[field])
        validator_values = validator[const]
        if schema_values != validator_values:
            errors.append(
                f"{field} mismatch: schema_only={sorted(schema_values-validator_values)}, "
                f"validator_only={sorted(validator_values-schema_values)}"
            )
    if errors:
        print("PREFLIGHT FAILED")
        for error in errors:
            print(f"- {error}")
        return 1
    print("PREFLIGHT PASSED: schema and validator vocabularies are synchronized")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
