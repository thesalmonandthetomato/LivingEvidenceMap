#!/usr/bin/env python3
"""Full-text coding runner using the synchronized v2 schema/validator contract."""
from __future__ import annotations
import argparse,json,os,time,importlib.util
from datetime import datetime,timezone
from pathlib import Path
from urllib.error import HTTPError,URLError
from urllib.request import Request,urlopen
DEFAULT_MODEL=os.getenv("FULLTEXT_CODING_MODEL","gpt-5.6-luna")
CHECKPOINT_RULE="After every model response, checkpoint the raw response before parsing, validation, aggregation, merging, or downstream processing. Never re-call the model when a complete successful checkpoint exists. A malformed response is a paper-level review/retry status and must not abort the batch."
def load(path):return json.loads(path.read_text(encoding="utf-8"))
def load_validator():
 path=Path(__file__).with_name("validate_coding_output_v2.py");spec=importlib.util.spec_from_file_location("fulltext_validator_v2",path)
 if spec is None or spec.loader is None:raise RuntimeError(f"Cannot load validator: {path}")
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
def call_api(base_url,key,model,system,user):
 payload={"model":model,"input":[{"role":"system","content":[{"type":"input_text","text":system}]},{"role":"user","content":[{"type":"input_text","text":user}]}]}
 req=Request(base_url.rstrip("/")+"/responses",data=json.dumps(payload).encode(),headers={"Authorization":f"Bearer {key}","Content-Type":"application/json","Accept":"application/json"},method="POST")
 try:
  with urlopen(req,timeout=300) as r:return json.load(r)
 except HTTPError as exc:raise RuntimeError(f"OpenAI API HTTP {exc.code}: {exc.read().decode('utf-8',errors='replace')}") from exc
 except URLError as exc:raise RuntimeError(f"OpenAI API connection error: {exc}") from exc
def response_text(data):
 if data.get("output_text"):return data["output_text"]
 parts=[]
 for item in data.get("output",[]):
  for c in item.get("content",[]):
   if isinstance(c,dict) and c.get("type")=="output_text":parts.append(c.get("text",""))
 return "\n".join(parts).strip()
def parse_annotation(text):
 annotation=json.loads(text)
 if not isinstance(annotation,dict):raise ValueError("Model output must be a JSON object")
 if "fields" in annotation:raise ValueError("Model output must place extraction fields at top level; nested fields object is prohibited")
 return annotation
def failed(path,raw,status,error):
 failed_raw=path.parent/(path.stem+".raw_response.json");failed_raw.write_text(json.dumps(raw,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
 status.write_text(json.dumps({"source_prepared_file":path.name,"raw_response_file":failed_raw.name,"status":"needs_review_or_retry","error_type":"invalid_json_or_structure","error":str(error),"checkpoint_rule":"raw_response_before_parsing","timestamp_utc":datetime.now(timezone.utc).isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
def main():
 ap=argparse.ArgumentParser();ap.add_argument("--input-dir",type=Path,required=True);ap.add_argument("--output-dir",type=Path,required=True);ap.add_argument("--ontology",type=Path,required=True);ap.add_argument("--schema",type=Path,required=True);ap.add_argument("--prompt",type=Path,required=True);ap.add_argument("--model",default=DEFAULT_MODEL);ap.add_argument("--max-papers",type=int,default=5);args=ap.parse_args()
 key=os.environ["OPENAI_API_KEY"];base=os.getenv("OPENAI_BASE_URL","https://api.openai.com/v1");args.output_dir.mkdir(parents=True,exist_ok=True);validator=load_validator()
 system=args.prompt.read_text(encoding="utf-8")+"\n\n"+CHECKPOINT_RULE;ontology=args.ontology.read_text(encoding="utf-8");schema=load(args.schema);files=sorted(args.input_dir.glob("*.json"))[:args.max_papers]
 if not files:raise SystemExit("No prepared JSON files found")
 for i,path in enumerate(files,1):
  out=args.output_dir/path.name;raw_out=args.output_dir/(path.stem+".raw_response.json");status=args.output_dir/(path.stem+".checkpoint.json")
  if out.exists() and raw_out.exists() and status.exists():print(f"[{i}/{len(files)}] CHECKPOINT EXISTS {out.name}; skipping model call",flush=True);continue
  prepared=load(path);user=("Code this article according to the supplied schema and ontology. Return a single valid JSON object only. Return exactly the current extraction fields and explicitly permitted audit/evidence structures. Do not return schema descriptions, provenance metadata, extra keys, or explanatory top-level fields. The substantive annotation fields must be at the TOP LEVEL.\n\nCODING SCHEMA:\n"+json.dumps(schema,ensure_ascii=False,indent=2)+"\n\nONTOLOGY CSV:\n"+ontology+"\n\nPREPARED ARTICLE:\n"+json.dumps(prepared,ensure_ascii=False))
  print(f"[{i}/{len(files)}] CODING {path.name}",flush=True);completed=False
  for attempt in range(4):
   try:
    data=call_api(base,key,args.model,system,user);text=response_text(data)
    if not text:raise RuntimeError("OpenAI API returned no output text")
    raw_out.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    try:annotation=parse_annotation(text)
    except (json.JSONDecodeError,ValueError) as exc:failed(path,data,status,exc);print(f"  INVALID JSON/STRUCTURE for {path.name}; raw response checkpointed; continuing batch",flush=True);completed=True;break
    warnings=validator.validate(annotation);annotation=dict(annotation);annotation["validation_warnings"]=warnings
    if warnings:
     print(f"  VALIDATION WARNINGS ({len(warnings)}) for {path.name}",flush=True)
     for warning in warnings:print(f"    - {warning}",flush=True)
    else:print(f"  VALIDATION OK for {path.name}",flush=True)
    out.write_text(json.dumps(annotation,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    status.write_text(json.dumps({"source_prepared_file":path.name,"annotation_file":out.name,"raw_response_file":raw_out.name,"status":"generated","validation_warning_count":len(warnings),"checkpoint_rule":"checkpoint_before_validation","timestamp_utc":datetime.now(timezone.utc).isoformat()},indent=2)+"\n",encoding="utf-8")
    print(f"  CHECKPOINTED {out.name} with validation warnings before downstream processing",flush=True);completed=True;break
   except Exception as exc:
    print(f"  attempt {attempt+1}/4 failed before successful response: {exc}",flush=True)
    if attempt==3:
     status.write_text(json.dumps({"source_prepared_file":path.name,"status":"api_or_execution_error","error":str(exc),"timestamp_utc":datetime.now(timezone.utc).isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8");print(f"  PAPER FAILED, continuing batch: {path.name}",flush=True);completed=True;break
    time.sleep(2**attempt)
  if not completed:print(f"  PAPER UNRESOLVED, continuing batch: {path.name}",flush=True)
 return 0
if __name__=="__main__":raise SystemExit(main())