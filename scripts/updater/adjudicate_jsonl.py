#!/usr/bin/env python3
"""Workflow 03: adjudicate residual duplicate candidates with full provenance and resumable checkpoints."""
import argparse,json,os
from datetime import datetime,timezone
from pathlib import Path
DECISIONS={"duplicate","not_duplicate","uncertain"}; CHECKPOINT_VERSION=1
def utc_now():return datetime.now(timezone.utc).isoformat()
def adjudication_schema():return {"type":"object","properties":{"decision":{"type":"string","enum":["duplicate","not_duplicate","uncertain"]},"confidence":{"type":"number","minimum":0,"maximum":1},"rationale":{"type":"string"}},"required":["decision","confidence","rationale"],"additionalProperties":False}
def system_prompt():return "You adjudicate whether two bibliographic records represent the same publication. Use the supplied evidence. DOI is supporting evidence only and may be wrong. Never treat lens_id as duplicate evidence. If evidence is insufficient or conflicting, return uncertain."
def build_request(candidate,model):return {"model":model,"input":[{"role":"system","content":system_prompt()},{"role":"user","content":json.dumps(candidate,ensure_ascii=False,sort_keys=True)}],"text":{"format":{"type":"json_schema","name":"duplicate_adjudication","strict":True,"schema":adjudication_schema()}}}
def safe_model_dump(v):
    if v is None:return None
    if hasattr(v,"model_dump"):
        try:return v.model_dump(mode="json")
        except TypeError:return v.model_dump()
    if isinstance(v,(dict,list,str,int,float,bool)):return v
    return str(v)
def mock_adjudication(candidate,model):
    if candidate.get("duplicate_basis")=="doi_conflict_review" or candidate.get("deduplication",{}).get("status")=="doi_conflict_review":p={"decision":"uncertain","confidence":0.5,"rationale":"Mock mode: DOI conflict requires adjudication and is not auto-resolved."}
    else:p={"decision":"uncertain","confidence":0.0,"rationale":"Mock mode: no production adjudication performed."}
    return p,{"request":build_request(candidate,model),"response_id":None,"resolved_model":None,"usage":None,"raw_response":None,"parsed_response":p}
def openai_adjudication(candidate,model):
    from openai import OpenAI
    client=OpenAI(); request=build_request(candidate,model); response=client.responses.create(**request); parsed=json.loads(response.output_text)
    return parsed,{"request":request,"response_id":getattr(response,"id",None),"resolved_model":getattr(response,"model",None),"usage":safe_model_dump(getattr(response,"usage",None)),"raw_response":safe_model_dump(response),"parsed_response":parsed}
def validate_result(r):
    if r["decision"] not in DECISIONS:raise ValueError("Invalid adjudication decision")
    if not isinstance(r["confidence"],(int,float)) or not 0<=r["confidence"]<=1:raise ValueError("Invalid adjudication confidence")
    if not isinstance(r["rationale"],str) or not r["rationale"]:raise ValueError("Empty adjudication rationale")
def adjudicate(candidate,mode,model):
    started=utc_now(); request=build_request(candidate,model)
    try:r,p=(mock_adjudication(candidate,model) if mode=="mock" else openai_adjudication(candidate,model)); validate_result(r); error=None
    except Exception as e:r={"decision":"uncertain","confidence":0.0,"rationale":"Adjudication failed; human review required."}; p={"request":request,"response_id":None,"resolved_model":None,"usage":None,"raw_response":None,"parsed_response":None}; error=type(e).__name__+": "+str(e)
    p.update({"requested_model":model if mode=="openai" else None,"mode":mode,"started_at":started,"completed_at":utc_now(),"adjudication_error":error}); return r,p
def count_jsonl(path):
    if not path.exists():return 0
    with path.open(encoding="utf-8") as f:return sum(1 for x in f if x.strip())
def save_checkpoint(path,completed,total,chunk_size,mode,model):
    path.parent.mkdir(parents=True,exist_ok=True); tmp=path.with_suffix(path.suffix+".tmp"); tmp.write_text(json.dumps({"checkpoint_version":CHECKPOINT_VERSION,"workflow":"03_adjudication","completed_candidates":completed,"total_candidates":total,"next_candidate_index":completed,"chunk_size":chunk_size,"mode":mode,"model":model,"updated_at":utc_now()},indent=2)+"\n",encoding="utf-8"); tmp.replace(path)
def run(input_path,output_path,audit_path,mode,model,checkpoint_path,chunk_size,resume):
    candidates=[json.loads(x) for x in input_path.read_text(encoding="utf-8").splitlines() if x.strip()]; output_path.parent.mkdir(parents=True,exist_ok=True); audit_path.parent.mkdir(parents=True,exist_ok=True)
    start=0
    if resume:
        state=json.loads(checkpoint_path.read_text(encoding="utf-8")); start=int(state["completed_candidates"])
        if state["total_candidates"]!=len(candidates) or state["mode"]!=mode or state["model"]!=model:raise RuntimeError("Checkpoint parameters do not match this run")
        if count_jsonl(output_path)!=start or count_jsonl(audit_path)!=start:raise RuntimeError("Checkpoint/output count mismatch")
    else:output_path.write_text("",encoding="utf-8"); audit_path.write_text("",encoding="utf-8"); save_checkpoint(checkpoint_path,0,len(candidates),chunk_size,mode,model)
    with output_path.open("a",encoding="utf-8") as out,audit_path.open("a",encoding="utf-8") as audit:
        for i in range(start,len(candidates)):
            candidate=candidates[i]; result,provenance=adjudicate(candidate,mode,model); record=dict(candidate); record.update({"workflow":"03_adjudication","decision":result["decision"],"confidence":result["confidence"],"rationale":result["rationale"],"mode":mode,"model":model if mode=="openai" else None,"resolved_model":provenance.get("resolved_model"),"response_id":provenance.get("response_id"),"usage":provenance.get("usage"),"adjudication_error":provenance.get("adjudication_error"),"created_at":provenance["completed_at"]}); audit_record={"workflow":"03_adjudication","candidate_id":candidate.get("candidate_id"),"candidate_evidence":candidate,"decision_record":record,"adjudication_provenance":provenance}; out.write(json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n"); audit.write(json.dumps(audit_record,ensure_ascii=False,separators=(",",":"))+"\n")
            completed=i+1
            if completed%chunk_size==0 or completed==len(candidates):out.flush(); audit.flush(); save_checkpoint(checkpoint_path,completed,len(candidates),chunk_size,mode,model)
def main():
    p=argparse.ArgumentParser(); p.add_argument("--input",required=True); p.add_argument("--output",required=True); p.add_argument("--audit",required=True); p.add_argument("--mode",choices=["mock","openai"],default="mock"); p.add_argument("--model",default="gpt-5-mini"); p.add_argument("--checkpoint"); p.add_argument("--chunk-size",type=int,default=250); p.add_argument("--resume",action="store_true"); a=p.parse_args()
    if a.chunk_size<1:raise SystemExit("--chunk-size must be at least 1")
    if a.mode=="openai" and not os.environ.get("OPENAI_API_KEY"):raise SystemExit("OPENAI_API_KEY is required for openai mode")
    out=Path(a.output); cp=Path(a.checkpoint) if a.checkpoint else out.with_suffix(out.suffix+".checkpoint.json"); run(Path(a.input),out,Path(a.audit),a.mode,a.model,cp,a.chunk_size,a.resume)
if __name__=="__main__":main()
