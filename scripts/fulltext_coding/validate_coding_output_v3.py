#!/usr/bin/env python3
"""Non-blocking validator for the current full-text coding contract."""
import argparse, json
from pathlib import Path

CURRENT_FIELDS={"document_type","review_type","study_type","study_design","research_approach","setting","sample_unit","study_period","location_region","location_country","species","other_farmed_species","study_population","aquaculture_facility","system_studied","production_stage","fish_life_stage","exposure_intervention","comparator","outcome_measured","funding_body","research_question","objectives_summary","ontology_codes","multiple_studies_flag","multiple_studies_reason"}
AUDIT_FIELDS={"evidence","document_completeness","document_completeness_evidence","field_completeness","not_reported_fields"}
ALLOWED=CURRENT_FIELDS|AUDIT_FIELDS|{"validation_warnings"}
DOC_TYPES={"study","review","perspective","commentary","editorial","book","book_chapter","report","thesis","protocol","other"}
REVIEW_TYPES={"primer_overview","systematic_style","not_applicable"}
STUDY_TYPES={"experimental","observational","modelling","not_stated","not_applicable"}
DESIGNS={"BA","CI","BACI","RCT","Time-series","Modelling","Qualitative","not_stated","not_applicable"}
APPROACHES={"quantitative","qualitative","mixed_methods","not_applicable"}
SETTINGS={"field","laboratory/controlled facility","in_vitro","in_silico"}
PRODUCTION={"Feed","Hatchery","Transfer between Hatchery and Adult","Adult grow-out","Processing"}
LIFE={"Sperm","Egg","Embryo","Alevin","Fry","Parr","Pre-smolt","Smolt","Juvenile","Adult","Broodstock","Product"}
FACILITIES={"salmon_farming_region","hatchery","open_cages","closed_cages","land_based","land_based_RAS"}
SPECIES={"Atlantic salmon","chum salmon","pink salmon","coho salmon","chinook salmon","sockeye salmon","masu salmon","rainbow trout","unspecified salmon species"}

def empty(v): return v in (None,"",[],{})
def found(v):
    if isinstance(v,str): return v.strip().upper()=="FOUND"
    if isinstance(v,list): return any(found(x) for x in v)
    if isinstance(v,dict): return any(found(k) or found(x) for k,x in v.items())
    return False

def validate(r):
    w=[]
    if not isinstance(r,dict): return ["top-level output must be a JSON object"]
    extra=sorted(set(r)-ALLOWED); missing=sorted(CURRENT_FIELDS-set(r))
    if extra:w.append(f"unexpected top-level fields: {extra}")
    if missing:w.append(f"missing current extraction fields: {missing}")
    if found(r):w.append('literal value "FOUND" is prohibited')
    dc=r.get("document_completeness")
    if dc not in {"COMPLETE","INCOMPLETE","UNCERTAIN"}:w.append(f"invalid or missing document_completeness: {dc!r}")
    dce=r.get("document_completeness_evidence")
    if dc in {"INCOMPLETE","UNCERTAIN"} and (not isinstance(dce,dict) or not dce.get("text") or not dce.get("reason")):w.append("INCOMPLETE/UNCERTAIN document requires document_completeness_evidence with text and reason")
    if dc=="COMPLETE" and dce not in (None,{}):w.append("document_completeness_evidence must be null/absent when COMPLETE")
    if r.get("document_type") not in DOC_TYPES and not (dc=="INCOMPLETE" and r.get("document_type") is None):w.append(f"invalid document_type: {r.get('document_type')!r}")
    if dc=="INCOMPLETE" and r.get("document_type") is not None:w.append("INCOMPLETE requires document_type=null")
    if r.get("review_type") not in REVIEW_TYPES and r.get("review_type") is not None:w.append("invalid review_type")
    if r.get("study_type") not in STUDY_TYPES:w.append("invalid study_type")
    if not isinstance(r.get("study_design"),list) or any(x not in DESIGNS for x in r.get("study_design",[])):w.append("invalid study_design")
    if r.get("research_approach") not in APPROACHES:w.append("invalid research_approach")
    for f in ("setting","sample_unit","species","other_farmed_species","aquaculture_facility","production_stage","fish_life_stage","outcome_measured","ontology_codes","not_reported_fields","evidence"):
        if not isinstance(r.get(f),list):w.append(f"{f} must be an array")
    if not isinstance(r.get("species"),list) or not r.get("species"):w.append("species must be a non-empty array")
    elif any(x not in SPECIES for x in r["species"]):w.append("invalid species value")
    for f,allowed in (("setting",SETTINGS),("production_stage",PRODUCTION),("fish_life_stage",LIFE),("aquaculture_facility",FACILITIES)):
        if isinstance(r.get(f),list) and any(x not in allowed for x in r[f]):w.append(f"invalid {f} value")
    if isinstance(r.get("fish_life_stage"),list) and "Harvest" in r["fish_life_stage"]:w.append("Harvest is prohibited in fish_life_stage")
    if not isinstance(r.get("multiple_studies_flag"),bool):w.append("multiple_studies_flag must be boolean")
    if r.get("multiple_studies_flag") and not isinstance(r.get("multiple_studies_reason"),str):w.append("multiple_studies_reason required when multiple_studies_flag=true")
    if not r.get("multiple_studies_flag") and r.get("multiple_studies_reason") is not None:w.append("multiple_studies_reason must be null when flag=false")
    fc=r.get("field_completeness")
    if not isinstance(fc,dict):w.append("field_completeness must be an object")
    else:
        bad=set(fc)-CURRENT_FIELDS
        if bad:w.append(f"field_completeness has non-current fields: {sorted(bad)}")
        if any(v not in (None,"NOT FOUND") for v in fc.values()):w.append("invalid field_completeness status")
        nr=sorted(k for k,v in fc.items() if v=="NOT FOUND"); actual=sorted(r.get("not_reported_fields",[]))
        if nr!=actual:w.append(f"not_reported_fields mismatch: expected {nr}, got {actual}")
    ev=r.get("evidence")
    if isinstance(ev,list):
        ef=set()
        for i,e in enumerate(ev):
            if not isinstance(e,dict):w.append(f"evidence[{i}] must be an object");continue
            ef.add(e.get("field"))
            if e.get("field") not in CURRENT_FIELDS:w.append(f"evidence[{i}] references non-current field")
            if not isinstance(e.get("text"),str) or not e.get("text").strip():w.append(f"evidence[{i}] requires source text")
        for f in CURRENT_FIELDS:
            if not empty(r.get(f)) and not (f=="review_type" and r.get(f) in (None,"not_applicable")) and not (f=="multiple_studies_reason" and r.get(f) is None) and f not in ef:w.append(f"populated current field lacks field-specific evidence: {f}")
    return w

def main():
    p=argparse.ArgumentParser();p.add_argument("--input",type=Path,required=True);p.add_argument("--output",type=Path);a=p.parse_args();r=json.loads(a.input.read_text());w=validate(r);out=dict(r);out["validation_warnings"]=w
    if a.output:a.output.write_text(json.dumps(out,ensure_ascii=False,indent=2)+"\n")
    print("VALIDATION WARNINGS" if w else "VALIDATION OK")
    for x in w:print("-",x)
    return 0
if __name__=="__main__": raise SystemExit(main())
