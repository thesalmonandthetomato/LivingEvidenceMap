#!/usr/bin/env python3
"""Preflight check for synchronization of current coding schema, validator and prompt."""
import argparse, ast, json, re
from pathlib import Path

FIELDS={"document_type","review_type","study_type","study_design","research_approach","setting","sample_unit","study_period","location_region","location_country","species","other_farmed_species","study_population","aquaculture_facility","system_studied","production_stage","fish_life_stage","exposure_intervention","comparator","outcome_measured","funding_body","research_question","objectives_summary","ontology_codes","multiple_studies_flag","multiple_studies_reason"}
AUDIT={"evidence","document_completeness","document_completeness_evidence","field_completeness","not_reported_fields"}
MAP={"document_type":"DOC_TYPES","review_type":"REVIEW_TYPES","study_type":"STUDY_TYPES","study_design":"DESIGNS","research_approach":"APPROACHES","setting":"SETTINGS","production_stage":"PRODUCTION","fish_life_stage":"LIFE","aquaculture_facility":"FACILITIES","species":"SPECIES"}

def main():
    p=argparse.ArgumentParser(); p.add_argument('--schema',type=Path,required=True); p.add_argument('--validator',type=Path,required=True); p.add_argument('--prompt',type=Path,required=True); a=p.parse_args(); s=json.loads(a.schema.read_text()); v=a.validator.read_text(); prompt=a.prompt.read_text(); errs=[]
    if set(s.get('fields',{}))!=FIELDS: errs.append('schema substantive fields mismatch')
    if set(s.get('current_substantive_fields',[]))!=FIELDS: errs.append('schema current_substantive_fields mismatch')
    if set(s.get('audit_fields',[]))!=AUDIT: errs.append('schema audit_fields mismatch')
    for f,n in MAP.items():
        if f not in s: errs.append(f'schema missing vocabulary: {f}'); continue
        m=re.search(rf'^{n}=\s*(\{{.*?\}})',v,re.M)
        if not m: errs.append(f'validator constant missing: {n}'); continue
        if set(s[f])!=set(ast.literal_eval(m.group(1))): errs.append(f'vocabulary mismatch: {f}')
    if 'Harvest' in s.get('fish_life_stage',[]): errs.append('Harvest remains in fish_life_stage vocabulary')
    if 'Schema version: fulltext_coding_v1' in prompt: errs.append('prompt still identifies schema as v1')
    if 'sample_size' in prompt.lower(): errs.append('prompt contains removed sample-size variable by name')
    if 'impact_type' in prompt or 'impact_details' in prompt or 'methodology_for_data_collection' in prompt or 'mitigation_evaluation' in prompt: errs.append('prompt contains removed legacy field names')
    if 'funder' in prompt and 'funding_body' in prompt: errs.append('prompt contains legacy funder terminology; review wording')
    if 'exposure\n' in prompt or 'intervention\n' in prompt: errs.append('prompt contains standalone legacy exposure/intervention field wording')
    if errs:
        print('PREFLIGHT FAILED'); [print('-',e) for e in errs]; return 1
    print('PREFLIGHT PASSED: schema, validator and prompt are synchronized'); return 0
if __name__=='__main__': raise SystemExit(main())
