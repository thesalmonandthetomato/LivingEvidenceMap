#!/usr/bin/env python3
"""Workflow 03: adjudicate residual duplicate candidates."""
import argparse, json, os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DECISIONS = {"duplicate", "not_duplicate", "uncertain"}

def utc_now():
    return datetime.now(timezone.utc).isoformat()

def mock_adjudication(candidate):
    if candidate.get("duplicate_basis") == "doi_conflict_review":
        return {"decision":"uncertain","confidence":0.5,"rationale":"Mock mode: DOI conflict requires adjudication and is not auto-resolved."}
    return {"decision":"uncertain","confidence":0.0,"rationale":"Mock mode: no production adjudication performed."}

def openai_adjudication(candidate, model):
    from openai import OpenAI
    client = OpenAI()
    schema = {"type":"object","properties":{"decision":{"type":"string","enum":["duplicate","not_duplicate","uncertain"]},"confidence":{"type":"number","minimum":0,"maximum":1},"rationale":{"type":"string"}},"required":["decision","confidence","rationale"],"additionalProperties":False}
    system = ("You adjudicate whether two bibliographic records represent the same publication. "
              "Use the supplied evidence. DOI is supporting evidence only and may be wrong. "
              "Never treat lens_id as duplicate evidence. If evidence is insufficient or conflicting, return uncertain.")
    response = client.responses.create(
        model=model,
        input=[{"role":"system","content":system},{"role":"user","content":json.dumps(candidate,ensure_ascii=False,sort_keys=True)}],
        text={"format":{"type":"json_schema","name":"duplicate_adjudication","strict":True,"schema":schema}},
    )
    return json.loads(response.output_text)

def adjudicate(candidate, mode, model):
    try:
        result = mock_adjudication(candidate) if mode == "mock" else openai_adjudication(candidate, model)
        if result["decision"] not in DECISIONS: raise ValueError("Invalid adjudication decision")
        if not isinstance(result["confidence"],(int,float)) or not 0 <= result["confidence"] <= 1: raise ValueError("Invalid adjudication confidence")
        if not isinstance(result["rationale"],str) or not result["rationale"]: raise ValueError("Empty adjudication rationale")
        return result
    except Exception as exc:
        return {"decision":"uncertain","confidence":0.0,"rationale":"Adjudication failed; human review required.","adjudication_error":type(exc).__name__+": "+str(exc)}

def run(input_path, output_path, audit_path, mode, model):
    candidates=[json.loads(x) for x in input_path.read_text(encoding="utf-8").splitlines() if x.strip()]
    output_path.parent.mkdir(parents=True,exist_ok=True); audit_path.parent.mkdir(parents=True,exist_ok=True)
    with output_path.open("w",encoding="utf-8") as out, audit_path.open("w",encoding="utf-8") as audit:
        for candidate in candidates:
            result=adjudicate(candidate,mode,model)
            record={"workflow":"03_adjudication","candidate_id":candidate.get("candidate_id"),"incoming_record_id":candidate.get("incoming_record_id"),"matched_master_record_id":candidate.get("matched_master_record_id"),"duplicate_basis":candidate.get("duplicate_basis"),"title_similarity":candidate.get("title_similarity"),"decision":result["decision"],"confidence":result["confidence"],"rationale":result["rationale"],"mode":mode,"model":model if mode=="openai" else None,"adjudication_error":result.get("adjudication_error"),"created_at":utc_now()}
            line=json.dumps(record,ensure_ascii=False,separators=(",",":")); out.write(line+"\n"); audit.write(line+"\n")

def main():
    p=argparse.ArgumentParser(); p.add_argument("--input",required=True); p.add_argument("--output",required=True); p.add_argument("--audit",required=True); p.add_argument("--mode",choices=["mock","openai"],default="mock"); p.add_argument("--model",default="gpt-5-mini"); a=p.parse_args()
    if a.mode=="openai" and not os.environ.get("OPENAI_API_KEY"): raise SystemExit("OPENAI_API_KEY is required for openai mode")
    run(Path(a.input),Path(a.output),Path(a.audit),a.mode,a.model)

if __name__=="__main__": main()
