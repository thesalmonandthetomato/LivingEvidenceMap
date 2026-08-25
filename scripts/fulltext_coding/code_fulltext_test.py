#!/usr/bin/env python3
"""Code prepared full texts with the OpenAI Responses API.

Every model response is checkpointed before parsing/validation. A malformed
response for one paper is retained for human review/retry and does not abort
the remaining papers in the batch.
"""
from __future__ import annotations
import argparse, json, os, time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_MODEL=os.getenv("FULLTEXT_CODING_MODEL","gpt-5.6-luna")
CHECKPOINT_RULE=("After every model response, checkpoint the raw response before parsing, validation, aggregation, merging, or downstream processing. Never re-call the model when a complete successful checkpoint exists. A malformed response is a paper-level review/retry status and must not abort the batch.")

def load(path: Path): return json.loads(path.read_text(encoding="utf-8"))

def call_api(base_url, api_key, model, system, user):
    payload={"model":model,"input":[{"role":"system","content":[{"type":"input_text","text":system}]},{"role":"user","content":[{"type":"input_text","text":user}]}]}
    req=Request(base_url.rstrip("/")+"/responses",data=json.dumps(payload).encode(),headers={"Authorization":f"Bearer {api_key}","Content-Type":"application/json","Accept":"application/json"},method="POST")
    try:
        with urlopen(req,timeout=300) as r: return json.load(r)
    except HTTPError as exc:
        body=exc.read().decode("utf-8",errors="replace"); raise RuntimeError(f"OpenAI API HTTP {exc.code}: {body}") from exc
    except URLError as exc: raise RuntimeError(f"OpenAI API connection error: {exc}") from exc

def response_text(data):
    if data.get("output_text"): return data["output_text"]
    parts=[]
    for item in data.get("output",[]):
        for c in item.get("content",[]):
            if isinstance(c,dict) and c.get("type")=="output_text": parts.append(c.get("text",""))
    return "\n".join(parts).strip()

def normalise_annotation(annotation):
    if not isinstance(annotation,dict): raise ValueError("Model output must be a JSON object")
    if isinstance(annotation.get("fields"),dict):
        fields=annotation["fields"]; merged=dict(fields)
        for key in ("schema_version","evidence","run_metadata"):
            if key in annotation: merged[key]=annotation[key]
        annotation=merged
    annotation.pop("description",None)
    annotation.pop("document_type_description",None)
    annotation.pop("contribution_type",None)
    annotation["schema_version"]="fulltext_coding_v1"
    return annotation

def write_failed_checkpoint(path, raw_response, status_out, error):
    ts=datetime.now(timezone.utc).isoformat()
    failed_raw=path.parent/(path.stem+".raw_response.json")
    failed_raw.write_text(json.dumps(raw_response,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    status_out.write_text(json.dumps({
        "source_prepared_file":path.name,
        "raw_response_file":failed_raw.name,
        "status":"needs_review_or_retry",
        "error_type":"invalid_json",
        "error":str(error),
        "checkpoint_rule":"raw_response_before_parsing",
        "timestamp_utc":ts
    },ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--input-dir",type=Path,required=True); ap.add_argument("--output-dir",type=Path,required=True); ap.add_argument("--ontology",type=Path,required=True); ap.add_argument("--schema",type=Path,required=True); ap.add_argument("--prompt",type=Path,required=True); ap.add_argument("--model",default=DEFAULT_MODEL); ap.add_argument("--max-papers",type=int,default=5); args=ap.parse_args()
    key=os.environ["OPENAI_API_KEY"]; base=os.getenv("OPENAI_BASE_URL","https://api.openai.com/v1"); args.output_dir.mkdir(parents=True,exist_ok=True)
    system=args.prompt.read_text(encoding="utf-8")+"\n\n"+CHECKPOINT_RULE; ontology=args.ontology.read_text(encoding="utf-8"); schema=load(args.schema)
    files=sorted(args.input_dir.glob("*.json"))[:args.max_papers]
    if not files: raise SystemExit("No prepared JSON files found")
    for i,path in enumerate(files,1):
        out=args.output_dir/path.name; raw_out=args.output_dir/(path.stem+".raw_response.json"); status_out=args.output_dir/(path.stem+".checkpoint.json")
        if out.exists() and raw_out.exists() and status_out.exists(): print(f"[{i}/{len(files)}] CHECKPOINT EXISTS {out.name}; skipping model call",flush=True); continue
        prepared=load(path)
        user=("Code this article according to the supplied schema and ontology. Return a single valid JSON object only. "
              "The substantive annotation fields must be at the TOP LEVEL, not under `fields`. Do not return schema descriptions, enum definitions, or explanatory top-level keys. "
              "Use exactly the requested top-level fields. Cite concise evidence for substantive extracted fields.\n\n"
              "CODING SCHEMA:\n"+json.dumps(schema,ensure_ascii=False,indent=2)+"\n\nONTOLOGY CSV:\n"+ontology+"\n\nPREPARED ARTICLE:\n"+json.dumps(prepared,ensure_ascii=False))
        print(f"[{i}/{len(files)}] CODING {path.name}",flush=True)
        completed=False
        for attempt in range(4):
            try:
                data=call_api(base,key,args.model,system,user); text=response_text(data)
                if not text: raise RuntimeError("OpenAI API returned no output text")
                raw_out.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
                try:
                    annotation=normalise_annotation(json.loads(text))
                except json.JSONDecodeError as exc:
                    write_failed_checkpoint(path,data,status_out,exc)
                    print(f"  INVALID JSON for {path.name}; raw response checkpointed; continuing batch",flush=True)
                    completed=True
                    break
                ts=datetime.now(timezone.utc).isoformat()
                annotation["run_metadata"]={"schema_version":"fulltext_coding_v1","ontology_version":"ontology_v3","model":args.model,"provider":"openai","timestamp_utc":ts,"source_prepared_file":path.name,"checkpoint_status":"generated"}
                out.write_text(json.dumps(annotation,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
                status_out.write_text(json.dumps({"source_prepared_file":path.name,"annotation_file":out.name,"raw_response_file":raw_out.name,"status":"generated","checkpoint_rule":"checkpoint_before_validation","timestamp_utc":ts},indent=2)+"\n",encoding="utf-8")
                print(f"  CHECKPOINTED {out.name} before validation",flush=True); completed=True; break
            except Exception as exc:
                print(f"  attempt {attempt+1}/4 failed before successful response: {exc}",flush=True)
                if attempt==3:
                    status_out.write_text(json.dumps({"source_prepared_file":path.name,"status":"api_or_execution_error","error":str(exc),"timestamp_utc":datetime.now(timezone.utc).isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
                    print(f"  PAPER FAILED, continuing batch: {path.name}",flush=True)
                    completed=True
                    break
                time.sleep(2**attempt)
        if not completed:
            print(f"  PAPER UNRESOLVED, continuing batch: {path.name}",flush=True)
    return 0
if __name__=="__main__": raise SystemExit(main())
