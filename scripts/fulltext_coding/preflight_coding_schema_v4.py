#!/usr/bin/env python3
"""Strict preflight check for current full-text coding schema, validator and prompt."""
import argparse, ast, json, re
from pathlib import Path

FIELDS={"document_type","review_type","study_type","study_design","research_approach","setting","sample_unit","study_period","location_region","location_country","species","other_farmed_species","study_population","aquaculture_facility","system_studied","production_stage","fish_life_stage","exposure_intervention","comparator","outcome_measured","funding_body","research_question","objectives_summary","ontology_codes","multiple_studies_flag","multiple_studies_reason"}
AUDIT={"evidence","document_completeness","document_completeness_evidence","field_completeness","not_reported_fields"}
MAP={"document_type":"DOC_TYPES","review_type":"REVIEW_TYPES","study_type":"STUDY_TYPES","study_design":"DESIGNS","research_approach":"APPROACHES","setting":"SETTINGS","production_stage":"PRODUCTION","fish_life_stage":"LIFE","aquaculture_facility":"FACILITIES","species":"SPECIES"}


def main():
    p=argparse.ArgumentParser(); p.add_argument('--schema',type=Path,required=True); p.add_argument('--validator',type=Path,required=True); p.add_argument('--prompt',type=Path,required=True); a=p.parse_args()
    s=json.loads(a.schema.read_text(encoding='utf-8')); v=a.validator.read_text(encoding='utf-8'); prompt=a.prompt.read_text(encoding='utf-8'); errs=[]
    if s.get('schema_version') != 'fulltext_coding_v3': errs.append(f"schema_version must be fulltext_coding_v3, got {s.get('schema_version')!r}")
    if set(s.get('fields',{})) != FIELDS: errs.append('schema substantive fields mismatch')
    if set(s.get('current_substantive_fields',[])) != FIELDS: errs.append('schema current_substantive_fields mismatch')
    if set(s.get('audit_fields',[])) != AUDIT: errs.append('schema audit_fields mismatch')
    for f,n in MAP.items():
        if f not in s: errs.append(f'schema missing vocabulary: {f}'); continue
        m=re.search(rf'^{n}=\s*(\{{.*?\}})',v,re.M)
        if not m: errs.append(f'validator constant missing: {n}'); continue
        if set(s[f]) != set(ast.literal_eval(m.group(1))): errs.append(f'vocabulary mismatch: {f}')
    if 'Harvest' in s.get('fish_life_stage',[]): errs.append('Harvest remains in fish_life_stage vocabulary')
    if 'Schema version: fulltext_coding_v1' in prompt or 'Schema version: fulltext_coding_v2' in prompt: errs.append('prompt identifies an obsolete schema version')
    if prompt.startswith('LivingEvidenceMap full-text article coding prompt\nSchema version: fulltext_coding_v3\n') is False: errs.append('prompt header/version is not fulltext_coding_v3')
    if any(x in prompt for x in ['sample_size','impact_type','impact_details','methodology_for_data_collection','mitigation_evaluation']): errs.append('prompt contains removed extraction-field names')
    if re.search(r'(?m)^-? ?(?:funder|exposure|intervention)\s*$',prompt): errs.append('prompt contains a standalone legacy field name')
    if 'Harvest is NOT a fish_life_stage value' not in prompt: errs.append('prompt missing Harvest exclusion')
    if 'LIFE-STAGE INFERENCE' not in prompt or 'ONLY Juvenile or Adult' not in prompt: errs.append('prompt missing Juvenile/Adult-only inference rule')
    if 'EVIDENCE' not in prompt or 'actual article text' not in prompt: errs.append('prompt missing source-evidence rule')
    if 'research_question and objectives_summary' not in prompt: errs.append('prompt missing research-question/objectives retrieval rule')
    if errs:
        print('PREFLIGHT FAILED'); [print('-',e) for e in errs]; return 1
    print('PREFLIGHT PASSED: schema, validator, prompt and vocabularies are synchronized'); return 0
if __name__=='__main__': raise SystemExit(main())
