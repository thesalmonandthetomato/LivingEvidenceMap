#!/usr/bin/env python3
"""Atomically append/update one completed full-text coding record.

This helper is deliberately small: it is the persistence boundary between one
successful model-coding record and the next record in the Zenodo workflow.
"""
import argparse, json, os
from datetime import datetime, timezone
from pathlib import Path


def read_json(path, default):
    p=Path(path)
    if not p.exists():
        return default
    return json.loads(p.read_text(encoding="utf-8"))


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--annotation", required=True)
    ap.add_argument("--provenance", required=True)
    ap.add_argument("--record-id", required=True)
    ap.add_argument("--zenodo-context", required=True)
    ap.add_argument("--cumulative", default="data/fulltext_coding/cumulative_coding.json")
    ap.add_argument("--architecture", default="data/fulltext_coding/coding_architecture.json")
    args=ap.parse_args()

    annotation=read_json(args.annotation,{})
    provenance=read_json(args.provenance,[])
    context=read_json(args.zenodo_context,{})
    pmap={str(r.get("openalex_id","")):r for r in provenance}
    prov=pmap.get(args.record_id,{})
    now=datetime.now(timezone.utc).isoformat()

    cumulative=read_json(args.cumulative,{"architecture_version":"1.0","workflow":"zenodo_fulltext_ai_coding","created_at_utc":now,"updated_at_utc":now,"record_count":0,"records":[]})
    architecture=read_json(args.architecture,{"architecture_version":"1.0","workflow":"zenodo_fulltext_ai_coding","created_at_utc":now,"updated_at_utc":now,"record_count":0,"provenance_key_order":["zenodo_record_id","zenodo_archive_filename","zenodo_source_filename","openalex_id","doi","master_csv_match","coding_run_id"],"records":{}})

    wid=args.record_id
    doi=str(prov.get("doi") or "").strip()
    record={
        "openalex_id":wid,
        "doi":doi,
        "zenodo_record_id":str(context.get("zenodo_record_id", "")),
        "zenodo_record_url":context.get("zenodo_record_url",""),
        "zenodo_archive_filename":context.get("zenodo_archive_filename",""),
        "zenodo_source_filename":prov.get("source_filename",f"{wid}.tei.xml"),
        "coding_status":"completed",
        "coding_run_id":os.environ.get("GITHUB_RUN_ID",""),
        "coding_timestamp_utc":now,
        "prompt_version":"fulltext_coding_v3",
        "schema_version":"coding_schema_v3",
        "ontology":"data/reference/topic_ontology_v3.csv",
        "annotation":annotation,
    }
    # Replace an existing record with the same OpenAlex ID, otherwise append.
    records=cumulative.setdefault("records",[])
    replaced=False
    for i,r in enumerate(records):
        if str(r.get("openalex_id",""))==wid:
            records[i]=record; replaced=True; break
    if not replaced: records.append(record)
    cumulative["updated_at_utc"]=now
    cumulative["record_count"]=len(records)
    cumulative["workflow"]="zenodo_fulltext_ai_coding"

    architecture.setdefault("records",{})[wid]={k:record[k] for k in [
        "openalex_id","doi","zenodo_record_id","zenodo_record_url",
        "zenodo_archive_filename","zenodo_source_filename","coding_status",
        "coding_run_id","coding_timestamp_utc","prompt_version",
        "schema_version","ontology"]}
    architecture["updated_at_utc"]=now
    architecture["record_count"]=len(architecture["records"])

    for path,obj in [(args.cumulative,cumulative),(args.architecture,architecture)]:
        p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
        tmp=p.with_suffix(p.suffix+".tmp")
        tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        tmp.replace(p)

    print(f"Persisted cumulative checkpoint for {wid}; total records={len(records)}")

if __name__ == "__main__":
    main()
