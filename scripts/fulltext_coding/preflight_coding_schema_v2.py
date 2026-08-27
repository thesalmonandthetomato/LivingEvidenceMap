#!/usr/bin/env python3
"""Preflight check for synchronization of current schema and validator."""
import argparse,ast,re,json
from pathlib import Path
FIELDS={"document_type","review_type","study_type","study_design","research_approach","setting","sample_unit","study_period","location_region","location_country","species","other_farmed_species","study_population","aquaculture_facility","system_studied","production_stage","fish_life_stage","exposure_intervention","comparator","outcome_measured","funding_body","research_question","objectives_summary","ontology_codes","multiple_studies_flag","multiple_studies_reason"}
MAP={"document_type":"DOC_TYPES","review_type":"REVIEW_TYPES","study_type":"STUDY_TYPES","study_design":"DESIGNS","research_approach":"APPROACHES","setting":"SETTINGS","production_stage":"PRODUCTION","fish_life_stage":"LIFE","aquaculture_facility":"FACILITIES","species":"SPECIES"}
def main():
 p=argparse.ArgumentParser();p.add_argument("--schema",type=Path,required=True);p.add_argument("--validator",type=Path,required=True);a=p.parse_args();s=json.loads(a.schema.read_text());v=a.validator.read_text();errs=[]
 if set(s.get("fields",{}))!=FIELDS:errs.append("schema substantive fields do not equal the 26 current fields")
 if set(s.get("current_substantive_fields",[]))!=FIELDS:errs.append("schema current_substantive_fields mismatch")
 if set(s.get("audit_fields",[]))!={"evidence","document_completeness","document_completeness_evidence","field_completeness","not_reported_fields"}:errs.append("schema audit fields mismatch")
 for f,n in MAP.items():
  if f not in s:errs.append(f"schema missing vocabulary: {f}");continue
  m=re.search(rf"^{n}=\s*(\{{.*?\}})",v,re.M)
  if not m:errs.append(f"validator constant missing: {n}");continue
  if set(s[f])!=set(ast.literal_eval(m.group(1))):errs.append(f"vocabulary mismatch: {f}")
 if "Harvest" in s.get("fish_life_stage",[]):errs.append("Harvest remains in fish_life_stage vocabulary")
 if errs:
  print("PREFLIGHT FAILED");[print("-",e) for e in errs];return 1
 print("PREFLIGHT PASSED: schema, prompt scope and validator are synchronized");return 0
if __name__=="__main__":raise SystemExit(main())