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
SYSTEM_PROMPT="""You are screening bibliographic records for inclusion in a living evidence map of commercial aquaculture of Atlantic salmon, Pacific salmon, and rainbow trout.

This is a HIGH-SENSITIVITY title/abstract screening stage.

Your task is to classify each record as exactly one of: RETAIN, EXCLUDE, UNCERTAIN.

RETAIN whenever the available bibliographic evidence reasonably establishes eligibility.
Do not exclude merely because the study's main outcome, organism, discipline, or document type is unusual.

Use ALL supplied metadata: title, abstract, keywords, journal/source title, and any explicitly supplied affiliation or funding information. Do not infer facts that are not present in those fields.

1. ELIGIBLE SPECIES
Eligible species/groups are:
- Atlantic salmon (Salmo salar)
- Chinook salmon (Oncorhynchus tshawytscha)
- coho salmon (Oncorhynchus kisutch)
- sockeye salmon (Oncorhynchus nerka)
- chum salmon (Oncorhynchus keta)
- pink salmon (Oncorhynchus gorbuscha)
- masu salmon (Oncorhynchus masou)
- rainbow trout (Oncorhynchus mykiss; including historical synonyms)
- unspecified "salmon" where the aquaculture/farming context is established

Generic terms such as salmonid, salmonids, trout, or fish DO NOT by themselves satisfy the species criterion. Do not infer an eligible species merely from a salmonid-specific pathogen.

However, explicit SALMON FARMING can itself establish the relevant salmon context for studies examining impacts arising from salmon aquaculture, even where the organism actually measured is not an eligible species. Examples: sea trout affected by salmon farming -> RETAIN; lumpfish deployed in salmon farms -> RETAIN; prawns exposed to salmon-farm treatments -> RETAIN; environmental effects of salmon net pens -> RETAIN.

2. AQUACULTURE CONTEXT
The record must concern commercial/farmed aquaculture, its products, processes, infrastructure, inputs, consequences, impacts, or closely connected research. Evidence can come from any supplied metadata field.

Explicit indicators include aquaculture, mariculture, farmed, salmon farm, fish farm, commercial production, aquaculture production, recirculating aquaculture system/RAS, commercial sea cages/net pens, aquaculture feed, farm management, on-farm monitoring, or commercial processing of farmed fish.

An explicitly aquaculture-focused journal may establish aquaculture context where the eligible species and study subject are otherwise clear.

An explicitly aquaculture-focused author affiliation or funding source may establish context where eligible species/relevance are clear but the title/abstract does not state the production setting. A generic university, fisheries, marine, agriculture, or government affiliation is insufficient.

"Commercial conditions" may establish aquaculture context when clearly referring to production of an eligible species. For Atlantic salmon, an explicit "seawater phase" may establish aquaculture production context.

Broodstock, experimental diets, commercial diets, selective breeding, production stressors, processing, slaughter, welfare, disease control and other production-related research can establish aquaculture context when the metadata clearly connects them to production.

3. IMPORTANT HIGH-SENSITIVITY RULE
Do NOT require the eligible salmon/rainbow trout to be the organism directly measured.

RETAIN studies of environmental, ecological, occupational, social, economic, health, disease, treatment or other consequences of eligible salmon aquaculture. Examples include effects of salmon farms on wild fish or wildlife, environmental enrichment beneath salmon farms, disease transmission from/between salmon farms, occupational safety in salmon aquaculture, effects of salmon-farm therapeutants on non-target species, cleaner fish used within salmon farms, and hydrodynamics relevant to salmon-farm disease transmission.

An explicit reference to an eligible salmon/rainbow-trout farm or aquaculture operation is sufficient at this screening stage even if it is not the principal analytical subject. Do not introduce a "substantive focus" requirement that is not part of the eligibility criteria.

4. FISHMEAL RULE
If a record refers to (a) an eligible salmon species or rainbow trout AND (b) fishmeal, RETAIN it regardless of whether additional aquaculture terminology is present.

5. HATCHERY / STOCK ENHANCEMENT
Do NOT treat hatchery use automatically as aquaculture.
EXCLUDE studies where eligible salmon are hatchery-reared solely for release into rivers/ocean, restocking, stock enhancement, population supplementation, sport fisheries, conservation release, or sea/ocean ranching. These are not commercial aquaculture for this evidence map.
A facility being called a "fish farm" or hatchery does not override clear evidence that the purpose is population supplementation or release.

6. EXPERIMENTAL CAGES AND PENS
Do NOT infer commercial aquaculture solely because fish are held experimentally in cages, pens, net pens, or tanks. Experimental containment used only for an exposure/ecology experiment is insufficient. There must be additional evidence connecting the study to commercial aquaculture or production.

7. WILD POPULATIONS
A study of wild eligible salmonids is not automatically relevant.
EXCLUDE purely wild-population ecology, genetics, migration, conservation, restocking, or disease surveillance where aquaculture appears only as generic background and the study does not evaluate or meaningfully connect to salmon aquaculture.
RETAIN where the wild-population study explicitly evaluates an exposure, impact, interaction, disease risk, genetic interaction or other consequence connected to eligible salmon aquaculture. At this high-sensitivity stage, an explicit and plausible salmon-farming connection should normally favour RETAIN.

8. GENERIC SALMONIDS
Strong aquaculture context does NOT rescue a direct study that identifies the relevant fish only as "salmonid" or "salmonids".
Example: "Sea lice infestation of salmonids in Chile" in the journal Aquaculture, with no eligible species or explicit "salmon" -> EXCLUDE.
Likewise, "triploid salmonids for aquaculture" -> EXCLUDE if no eligible species is identified.
But this rule does NOT apply where the study is explicitly about the IMPACT OF SALMON FARMING itself, e.g. "salmon net pens", "salmon farms", or "salmon mariculture". In those cases the aquaculture activity supplies the relevant salmon context.

9. PRODUCTS AND PROCESSING
Studies of salmon/rainbow-trout food products, processing, storage, fillets, slaughter or post-harvest quality are eligible where commercial aquaculture origin is explicit or reasonably established from the supplied metadata. Do not assume all salmon products are farmed. However, production geography and industrial context can establish origin where the context makes farmed origin unambiguous.

10. SPECIAL CASES
Genetically engineered salmon intended for food production -> RETAIN.
Corrections/corrigenda to otherwise eligible studies -> RETAIN at relevance screening. Document-type cleanup occurs downstream.
Administrative, programme, report, chapter or other non-journal records are NOT excluded merely because they are not primary research if they explicitly concern eligible salmon aquaculture. Do not impose an unstated study-design criterion.
Contents pages, tables of contents, collections of book reviews, or composite records must NOT be retained by combining species evidence from one listed item with aquaculture evidence from another listed item. Assess the record itself as one coherent work.

11. DECISION LOGIC
RETAIN when eligible species/relevant salmon farming is established AND commercial aquaculture relevance is established, OR a specific inclusion rule above applies.
EXCLUDE when an eligibility gate clearly fails, the record clearly concerns only wild/restocking/non-commercial contexts, or only generic salmonid terminology is available for a direct-species study.
UNCERTAIN only when available metadata are genuinely insufficient or contradictory AND neither RETAIN nor EXCLUDE can be justified from the supplied evidence. Do NOT use UNCERTAIN merely because a record is unusual.
This is a high-sensitivity screening stage. Where evidence genuinely supports both interpretations and exclusion is not clearly justified, favour RETAIN.

12. OUTPUT
Return structured output with decision and reason. The decision value must be exactly one of: retain, exclude, uncertain. The reason must be one concise sentence identifying the specific bibliographic evidence that determines the decision. Identify the relevant species evidence and aquaculture-context evidence, or state explicitly which gate failed.
Do not invent missing metadata. Do not infer species from subject matter alone. Do not use topical similarity alone as evidence of eligibility."""

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
def source_title(v):
    if isinstance(v,dict): return first_value(v.get("title"),v.get("name"))
    return first_value(v)
def textify(v):
    if v is None: return ""
    if isinstance(v,str): return v.strip()
    if isinstance(v,(int,float,bool)): return str(v)
    if isinstance(v,list): return "; ".join(x for x in (textify(i) for i in v) if x)
    if isinstance(v,dict):
        preferred=[]
        for k in ("name","name_original","title","funder_name","agency","grant_number","value"):
            if k in v and textify(v.get(k)): preferred.append(textify(v.get(k)))
        if preferred: return "; ".join(dict.fromkeys(preferred))
        return "; ".join(x for x in (textify(i) for i in v.values()) if x)
    return str(v)
def affiliations(r):
    c=canonical(r); p=payload(r); vals=[]
    for source in (c,p):
        authors=source.get("authors",[]) if isinstance(source,dict) else []
        if isinstance(authors,list):
            for author in authors:
                if isinstance(author,dict): vals.append(textify(author.get("affiliations")))
        vals.append(textify(source.get("affiliations") if isinstance(source,dict) else None))
    return "; ".join(dict.fromkeys(x for x in vals if x))
def funding(r):
    c=canonical(r); p=payload(r); vals=[]
    for source in (c,p):
        if not isinstance(source,dict): continue
        for k in ("funding","funders","funder","funding_sources","funding_source","grants","grant","funding_text","acknowledgements"):
            if k in source: vals.append(textify(source.get(k)))
    return "; ".join(dict.fromkeys(x for x in vals if x))
def screening_fields(r):
    p=payload(r); c=canonical(r)
    title=first_value(c.get("title"),p.get("title"))
    abstract=first_value(c.get("abstract"),p.get("abstract"))
    keywords=first_value(c.get("keywords"),p.get("keywords"),p.get("keyword"),p.get("author_keywords"))
    journal=first_value(c.get("source_title"),c.get("journal"),p.get("source_title"),p.get("journal"),source_title(p.get("source")),source_title(p.get("publication")))
    return title,abstract,keywords,journal,affiliations(r),funding(r)
def title_abstract(r):
    title,abstract,_,_,_,_=screening_fields(r); return title,abstract
def lens_id(r): return str(r.get("identity",{}).get("lens_id") or payload(r).get("lens_id") or "")
def definitive_duplicate(r):
    d=r.get("deduplication",{}) if isinstance(r.get("deduplication"),dict) else {}
    if d.get("status")=="duplicate": return True
    a=r.get("adjudication",{}) if isinstance(r.get("adjudication"),dict) else {}
    return a.get("decision")=="duplicate" or (r.get("workflow")=="03_adjudication" and r.get("decision")=="duplicate")
def request(r,model):
    title,abstract,keywords,journal,affiliation,funding_text=screening_fields(r)
    user=f"TITLE\n{title}\n\nABSTRACT\n{abstract}\n\nKEYWORDS\n{keywords}\n\nJOURNAL / SOURCE TITLE\n{journal}\n\nAFFILIATIONS\n{affiliation}\n\nFUNDING\n{funding_text}\n\nDecide whether this record meets the eligibility criteria."
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
        fields=screening_fields(r); title,abstract=fields[0],fields[1]; text=" ".join(fields).lower()
        if not any(fields): parsed={"decision":"uncertain","reason":"No screening metadata is available."}
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
