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
SYSTEM_PROMPT="""You are screening bibliographic records for a living evidence map of commercial salmon and rainbow-trout aquaculture. Use only the supplied TITLE, ABSTRACT, KEYWORDS and JOURNAL / SOURCE TITLE.

A record is eligible only when BOTH of these gates are satisfied by the supplied metadata:

GATE 1 — ELIGIBLE SPECIES
There must be explicit evidence of at least one eligible species or group:
- Atlantic salmon (Salmo salar)
- Chinook salmon (Oncorhynchus tshawytscha)
- coho salmon (Oncorhynchus kisutch)
- sockeye salmon (Oncorhynchus nerka)
- chum salmon (Oncorhynchus keta)
- pink salmon (Oncorhynchus gorbuscha)
- masu salmon (Oncorhynchus masou)
- rainbow trout (Oncorhynchus mykiss), including an explicitly identified O. mykiss form
- unspecified salmon, when the record says salmon but does not identify the species

Do NOT treat generic terms such as trout, salmonid, salmonids, fish, or cultured fish as sufficient evidence of an eligible species. Do NOT infer an eligible host species from a pathogen name such as Aeromonas salmonicida.

GATE 2 — AQUACULTURE CONTEXT
There must be explicit evidence that the eligible fish, population, product, system or evidence concerns aquaculture, farming or commercial culture. Evidence may occur in any supplied field, including the journal/source title.

Valid aquaculture evidence includes explicit terms or clear production-system terminology such as aquaculture, aquacultural, farmed, farming, fish farm, salmon farm, cultured, commercial culture, rearing for production, sea cage/net-pen production, stocking density in a production context, or equivalent wording. An aquaculture-focused journal/source title (for example Aquaculture, Aquaculture Research, Aquaculture Nutrition or Aquaculture International) counts as explicit aquaculture evidence. A journal/source title using Agriculture may also count as production-context evidence when the record explicitly concerns an eligible aquatic species and the study itself concerns a production, processing, sorting or other agricultural application.

Do NOT infer aquaculture merely because a study of an eligible species concerns diet, feed, growth, reproduction, breeding, genetics, physiology, immunology, disease, diagnostics, transport, environmental stress, processing, products, or another topic that could be useful to aquaculture. Potential applicability is not evidence of aquaculture context.

SPECIAL CASES
- Genetically engineered salmon intended as a produced food animal may be treated as inherently aquaculture-related even if the supplied fields do not separately say farmed or aquaculture.
- Hatchery does NOT automatically mean aquaculture. EXCLUDE records about hatchery fish produced for release, sport-fish stocking, stock enhancement, supplementation of wild populations, sea ranching or ocean ranching when that is the relevant production context.
- Wild salmonids, capture fisheries and conservation are not eligible unless the record explicitly and substantively examines an effect, pressure, interaction or consequence of eligible commercial salmon/rainbow-trout aquaculture. A wild population alone is not enough.
- Products derived from salmon or trout are not automatically aquaculture products. Require evidence that both the species gate and aquaculture-context gate are satisfied.
- For mixed-species studies, RETAIN only when an eligible species is explicitly identified and is a substantive part of the aquaculture evidence, analysis or conclusions. A generic claim covering all fish or all animal species is not enough.
- Reviews, systematic reviews, meta-analyses, policy papers and synthesis papers are eligible under the same two-gate rule.

DECISIONS
RETAIN when both gates are satisfied and eligible commercial aquaculture is a substantive part of the record.
EXCLUDE when either gate clearly fails, when the only relevant context is wild/capture/conservation/ranching/stock enhancement, or when salmon aquaculture is only background or a passing example.
UNCERTAIN only when the supplied metadata genuinely do not contain enough information to determine whether one or both gates are satisfied. Do not use UNCERTAIN merely because the abstract is missing if the other supplied fields establish both gates.

This is a high-sensitivity updater screen: avoid false exclusions when the supplied evidence genuinely supports both gates. However, do not invent or infer a missing species gate or aquaculture gate from likely applicability.

Give one concise reason that identifies the evidence for, or failure of, the species gate and aquaculture-context gate."""

def now(): return datetime.now(timezone.utc).isoformat()
def schema(): return {"type":"object","properties":{"decision":{"type":"string","enum":["retain","exclude","uncertain"]},"reason":{"type":"string"}},"required":["decision","reason"],"additionalProperties":False}
def payload(r): return r.get("lens",{}).get("raw_payload",{}) if isinstance(r.get("lens"),dict) else {}
def canonical(r): return r.get("canonical",{}) if isinstance(r.get("canonical"),dict) else {}
def first_value(*values):
    for v in values:
        if v is None: continue
        if isinstance(v,str) and v.strip(): return v.strip()
        if isinstance(v,(list,tuple)) and v: return "; ".join(str(x) for x in v if x is not None)
    return ""
def screening_fields(r):
    p=payload(r); c=canonical(r)
    title=first_value(c.get("title"),p.get("title"))
    abstract=first_value(c.get("abstract"),p.get("abstract"))
    keywords=first_value(c.get("keywords"),p.get("keywords"),p.get("keyword"),p.get("author_keywords"))
    journal=first_value(c.get("source_title"),c.get("journal"),p.get("source_title"),p.get("journal"),p.get("source"),p.get("publication"))
    return title,abstract,keywords,journal
def title_abstract(r):
    title,abstract,_,_=screening_fields(r); return title,abstract
def lens_id(r): return str(r.get("identity",{}).get("lens_id") or payload(r).get("lens_id") or "")
def definitive_duplicate(r):
    d=r.get("deduplication",{}) if isinstance(r.get("deduplication"),dict) else {}
    if d.get("status")=="duplicate": return True
    a=r.get("adjudication",{}) if isinstance(r.get("adjudication"),dict) else {}
    return a.get("decision")=="duplicate" or (r.get("workflow")=="03_adjudication" and r.get("decision")=="duplicate")
def request(r,model):
    title,abstract,keywords,journal=screening_fields(r)
    user=f"TITLE\n{title}\n\nABSTRACT\n{abstract}\n\nKEYWORDS\n{keywords}\n\nJOURNAL / SOURCE TITLE\n{journal}\n\nDecide whether this record meets the eligibility criteria."
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
        title,abstract,keywords,journal=screening_fields(r); text=" ".join((title,abstract,keywords,journal)).lower()
        if not any((title,abstract,keywords,journal)): parsed={"decision":"uncertain","reason":"No screening metadata is available."}
        elif "atlantic salmon" in text and any(x in text for x in ("farm","aquaculture","cultured")): parsed={"decision":"retain","reason":"Eligible salmon and aquaculture context are explicit."}
        elif "wild salmon" in text and not any(x in text for x in ("farm","aquaculture","cultured")): parsed={"decision":"exclude","reason":"The supplied evidence concerns wild salmon only and lacks aquaculture context."}
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
