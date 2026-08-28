#!/usr/bin/env python3
"""Workflow 04: JSON-native salmon-farming relevance screening.

All records except definitive duplicates are screened. Screening never stops
later annotation: exclude/uncertain are provisional until consolidated human
adjudication after topic assignment.
"""
from __future__ import annotations
import argparse, json, os
from datetime import datetime, timezone
from pathlib import Path

DECISIONS={"retain","exclude","uncertain"}
CHECKPOINT_VERSION=1
SYSTEM_PROMPT="""You are screening titles and abstracts for a living evidence map of salmon farming.

RETAIN a record when salmon farming is a substantive focus and it concerns one or more eligible farmed salmonids:
- Atlantic salmon
- Pacific salmon species, including Chinook, coho, sockeye, chum, pink and masu salmon
- rainbow trout
- farmed salmon where the species is not specified

Eligible records may concern any substantive aspect of farming, production, inputs, fish health, welfare, environmental pressures or impacts, products, economics, governance, labour, communities, consumers, or research methods specifically applied to eligible salmon farming.

EXCLUDE when:
- the study concerns only wild salmonids, capture fisheries or conservation;
- salmon farming is only background, context or a passing example;
- it concerns only non-eligible aquaculture species;
- it concerns basic salmon biology without a substantive farming context;
- the available title and abstract clearly do not concern eligible salmon farming.

For mixed-species studies, RETAIN if eligible farmed salmonids are a substantive part of the evidence, analysis or conclusions.

Reviews, systematic reviews, meta-analyses, policy papers and synthesis papers are eligible when eligible salmon farming is a substantive focus, even if other aquaculture species, fisheries or food systems are also discussed.

Use UNCERTAIN only as a last resort. Choose RETAIN whenever the available title and abstract make eligibility more defensible than ineligibility. Choose EXCLUDE whenever the available title and abstract make ineligibility more defensible than eligibility. Use UNCERTAIN only when the title and abstract genuinely do not contain enough information to make a defensible decision. Do not use UNCERTAIN merely because the paper is broad, multidisciplinary, uses unusual terminology, or requires reasonable inference.

DECISION HIERARCHY
1. If clearly eligible, choose RETAIN.
2. Otherwise, if clearly ineligible, choose EXCLUDE.
3. Otherwise, choose UNCERTAIN.

Base the decision only on the supplied title and abstract. Give one concise reason."""

def now(): return datetime.now(timezone.utc).isoformat()
def schema(): return {"type":"object","properties":{"decision":{"type":"string","enum":["retain","exclude","uncertain"]},"reason":{"type":"string"}},"required":["decision","reason"],"additionalProperties":False}
def payload(r): return r.get("lens",{}).get("raw_payload",{}) if isinstance(r.get("lens"),dict) else {}
def title_abstract(r):
    p=payload(r); c=r.get("canonical",{}) if isinstance(r.get("canonical"),dict) else {}
    return c.get("title") or p.get("title") or "", c.get("abstract") or p.get("abstract") or ""
def lens_id(r): return str(r.get("identity",{}).get("lens_id") or payload(r).get("lens_id") or "")
def definitive_duplicate(r):
    d=r.get("deduplication",{}) if isinstance(r.get("deduplication"),dict) else {}
    if d.get("status")=="duplicate": return True
    # Workflow 03 decisions can be carried either under adjudication or at top level.
    a=r.get("adjudication",{}) if isinstance(r.get("adjudication"),dict) else {}
    return a.get("decision")=="duplicate" or (r.get("workflow")=="03_adjudication" and r.get("decision")=="duplicate")
def request(r,model):
    title,abstract=title_abstract(r); user=f"TITLE\n{title}\n\nABSTRACT\n{abstract}\n\nDecide whether this record meets the salmon-farming eligibility criteria."
    return {"model":model,"store":False,"reasoning":{"effort":"low"},"input":[{"role":"system","content":SYSTEM_PROMPT},{"role":"user","content":user}],"text":{"verbosity":"low","format":{"type":"json_schema","name":"salmon_farming_relevance_screen","strict":True,"schema":schema()}}}
def dump(v):
    if v is None:return None
    if hasattr(v,"model_dump"):
        try:return v.model_dump(mode="json")
        except TypeError:return v.model_dump()
    return v if isinstance(v,(dict,list,str,int,float,bool)) else str(v)
def screen(r,mode,model):
    started=now(); req=request(r,model)
    if mode=="mock":
        title,abstract=title_abstract(r); text=(title+" "+abstract).lower()
        if not title and not abstract: parsed={"decision":"uncertain","reason":"No title or abstract is available."}
        elif "atlantic salmon" in text and any(x in text for x in ("farm","aquaculture","rearing")): parsed={"decision":"retain","reason":"Eligible farmed salmon is a substantive focus."}
        elif "wild salmon" in text and not any(x in text for x in ("farm","aquaculture")): parsed={"decision":"exclude","reason":"The supplied evidence concerns wild salmon only."}
        else: parsed={"decision":"uncertain","reason":"Mock mode cannot make a defensible eligibility decision."}
        return parsed,{"request":req,"response_id":None,"resolved_model":None,"usage":None,"raw_response":None,"parsed_response":parsed,"mode":mode,"started_at":started,"completed_at":now(),"screening_error":None}
    try:
        from openai import OpenAI
        resp=OpenAI().responses.create(**req); parsed=json.loads(resp.output_text)
        if parsed.get("decision") not in DECISIONS or not parsed.get("reason"): raise ValueError("Invalid screening response")
        return parsed,{"request":req,"response_id":getattr(resp,"id",None),"resolved_model":getattr(resp,"model",None),"usage":dump(getattr(resp,"usage",None)),"raw_response":dump(resp),"parsed_response":parsed,"mode":mode,"started_at":started,"completed_at":now(),"screening_error":None}
    except Exception as e:
        parsed={"decision":"uncertain","reason":"Screening failed; retain for downstream processing and consolidated review."}
        return parsed,{"request":req,"response_id":None,"resolved_model":None,"usage":None,"raw_response":None,"parsed_response":None,"mode":mode,"started_at":started,"completed_at":now(),"screening_error":type(e).__name__+": "+str(e)}
def load(path):
    with path.open(encoding="utf-8") as f:return [json.loads(x) for x in f if x.strip()]
def count(path):
    if not path.exists():return 0
    with path.open(encoding="utf-8") as f:return sum(1 for x in f if x.strip())
def checkpoint(path,completed,total,screened,skipped,chunk,mode,model):
    tmp=path.with_suffix(path.suffix+".tmp"); tmp.write_text(json.dumps({"checkpoint_version":CHECKPOINT_VERSION,"workflow":"04_relevance_screening","completed_records":completed,"total_records":total,"screened_records":screened,"definitive_duplicates_skipped":skipped,"next_record_index":completed,"chunk_size":chunk,"mode":mode,"model":model,"updated_at":now()},indent=2)+"\n"); tmp.replace(path)
def main():
    p=argparse.ArgumentParser(); p.add_argument("--input",required=True); p.add_argument("--output",required=True); p.add_argument("--audit",required=True); p.add_argument("--checkpoint"); p.add_argument("--chunk-size",type=int,default=250); p.add_argument("--mode",choices=["mock","openai"],default="mock"); p.add_argument("--model",default="gpt-5-mini"); p.add_argument("--resume",action="store_true"); a=p.parse_args()
    if a.chunk_size<1:raise SystemExit("--chunk-size must be at least 1")
    if a.mode=="openai" and not os.environ.get("OPENAI_API_KEY"):raise SystemExit("OPENAI_API_KEY is required")
    rows=load(Path(a.input)); out=Path(a.output); audit=Path(a.audit); cp=Path(a.checkpoint) if a.checkpoint else out.with_suffix(out.suffix+".checkpoint.json"); out.parent.mkdir(parents=True,exist_ok=True); audit.parent.mkdir(parents=True,exist_ok=True)
    start=screened=skipped=0
    if a.resume:
        state=json.loads(cp.read_text()); start=int(state["completed_records"]); screened=int(state["screened_records"]); skipped=int(state["definitive_duplicates_skipped"])
        if state["total_records"]!=len(rows) or state["mode"]!=a.mode or state["model"]!=a.model:raise RuntimeError("Checkpoint parameters do not match this run")
        if count(out)!=start:raise RuntimeError("Checkpoint/output count mismatch")
    else:
        out.write_text(""); audit.write_text(""); checkpoint(cp,0,len(rows),0,0,a.chunk_size,a.mode,a.model)
    with out.open("a",encoding="utf-8") as fo,audit.open("a",encoding="utf-8") as fa:
        for i in range(start,len(rows)):
            r=rows[i]; enriched=dict(r)
            if definitive_duplicate(r):
                skipped+=1; screening={"status":"not_screened_definitive_duplicate","decision":None,"reason":"Definitive duplicate; relevance screening not required.","requires_human_review":False,"provisional":False,"created_at":now()}; provenance=None
            else:
                screened+=1; result,provenance=screen(r,a.mode,a.model); error=provenance.get("screening_error"); screening={"status":"screened","decision":result["decision"],"reason":result["reason"],"requires_human_review":bool(result["decision"]=="uncertain" or error),"provisional":True,"technical_error":error,"model":a.model if a.mode=="openai" else None,"resolved_model":provenance.get("resolved_model"),"response_id":provenance.get("response_id"),"usage":provenance.get("usage"),"created_at":provenance["completed_at"]}
            enriched["screening"]=screening; fo.write(json.dumps(enriched,ensure_ascii=False,separators=(",",":"))+"\n"); fa.write(json.dumps({"workflow":"04_relevance_screening","lens_id":lens_id(r),"input_record":r,"screening":screening,"screening_provenance":provenance},ensure_ascii=False,separators=(",",":"))+"\n")
            completed=i+1
            if completed%a.chunk_size==0 or completed==len(rows):fo.flush(); fa.flush(); checkpoint(cp,completed,len(rows),screened,skipped,a.chunk_size,a.mode,a.model)
if __name__=="__main__":main()
