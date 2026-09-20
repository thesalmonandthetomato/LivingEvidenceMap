#!/usr/bin/env python3
"""Workflow 01: source-agnostic abstract enrichment.

Inputs are preserved Workflow 00 outputs. Existing abstracts are never replaced.
Missing abstracts are enriched first from another preserved source by exact DOI,
then (optionally) from Europe PMC by exact DOI. Source payloads remain immutable.
"""
from __future__ import annotations
import argparse, html, json, re, time, unicodedata, urllib.error, urllib.parse, urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

EPMC="https://www.ebi.ac.uk/europepmc/webservices/rest/search"
UA="LivingEvidenceMap Workflow 01 abstract repair"
MAX_CHARS=12000
SECTION_LABELS={"abstract","aim","aims","background","conclusion","conclusions","discussion","importance","introduction","method","methods","objective","objectives","purpose","result","results","summary"}
BLOCK_TAG_RE=re.compile(r"</?(?:abstract|abstract-text|body|br|div|p|sec|section|title)(?:\s[^>]*)?>",re.I)
TAG_RE=re.compile(r"<[^>]+>")
COMMENT_RE=re.compile(r"<!--.*?-->",re.S)
CDATA_RE=re.compile(r"<!\[CDATA\[(.*?)\]\]>",re.S)
JATS_TITLE_RE=re.compile(r"<title(?:\s[^>]*)?>(.*?)</title>",re.I|re.S)

def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")

def read_jsonl(path):
    rows=[]
    with open(path,encoding="utf-8") as f:
        for n,line in enumerate(f,1):
            if line.strip():
                try: rows.append(json.loads(line))
                except Exception as e: raise RuntimeError(f"{path}:{n}: invalid JSON: {e}")
    return rows

def write_jsonl(path,rows):
    Path(path).parent.mkdir(parents=True,exist_ok=True)
    with open(path,"w",encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r,ensure_ascii=True,separators=(",",":"))+"\n")

def clean_abstract(v):
    if v is None: return None
    s=unicodedata.normalize("NFKC",str(v))
    s=CDATA_RE.sub(lambda m:m.group(1),s); s=COMMENT_RE.sub(" ",s)
    def title_repl(m):
        inner=TAG_RE.sub(" ",html.unescape(m.group(1)))
        label=re.sub(r"[^a-z]+"," ",inner.casefold()).strip()
        return " " if label in SECTION_LABELS else f" {inner} "
    s=JATS_TITLE_RE.sub(title_repl,s)
    s=BLOCK_TAG_RE.sub(" ",s); s=TAG_RE.sub(" ",s)
    s=html.unescape(html.unescape(s)); s=BLOCK_TAG_RE.sub(" ",s); s=TAG_RE.sub(" ",s)
    s=re.sub(r"\s+"," ",s).strip()
    s=re.sub(r"^abstract\s*[:.\-–—]?\s*","",s,flags=re.I)
    return s[:MAX_CHARS] if s else None

def norm_doi(v):
    if not v: return None
    s=str(v).strip().lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p): s=s[len(p):].strip()
    return s.rstrip(".") or None

def kind(r):
    if isinstance(r.get("lens"),dict): return "lens"
    p=(r.get("source") or {}).get("provider")
    if p=="scopus": return "scopus"
    if p=="openalex": return "openalex"
    if p=="agricola_via_europe_pmc": return "agricola"
    raise RuntimeError(f"Unknown source record shape: provider={p!r}")

def record_id(r):
    if kind(r)=="lens":
        return str((r.get("identity") or {}).get("lens_id") or (r.get("identity") or {}).get("record_id") or "")
    return str((r.get("sidecar_identity") or {}).get("sidecar_record_id") or "")

def record_doi(r):
    if kind(r)=="lens":
        c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
        if c.get("doi"): return norm_doi(c.get("doi"))
        p=(r.get("lens") or {}).get("raw_payload") or {}
        for x in p.get("external_ids") or []:
            if isinstance(x,dict) and str(x.get("type","")).lower()=="doi" and x.get("value"):
                return norm_doi(x.get("value"))
        return None
    return norm_doi((r.get("mapped_fields") or {}).get("doi") or (r.get("sidecar_identity") or {}).get("doi"))

def existing_abstract(r):
    if kind(r)=="lens":
        c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
        p=(r.get("lens") or {}).get("raw_payload") or {}
        return c.get("abstract") or p.get("abstract")
    return (r.get("mapped_fields") or {}).get("abstract")

def set_abstract(r,text,meta):
    out=dict(r)
    cleaned=clean_abstract(text)
    if kind(r)=="lens":
        c=dict(out.get("canonical") or {})
        p=(out.get("lens") or {}).get("raw_payload") or {}
        src=p.get("source"); src_title=src.get("title") if isinstance(src,dict) else src
        defaults={
            "record_id":(out.get("identity") or {}).get("record_id") or record_id(out),
            "lens_id":(out.get("identity") or {}).get("lens_id") or record_id(out),
            "title":p.get("title"),"authors":p.get("authors"),
            "year":p.get("year_published") or p.get("date_published"),
            "source":src_title,"doi":record_doi(out)
        }
        for k,v in defaults.items():
            if c.get(k) in (None,"") and v not in (None,""): c[k]=v
        c["abstract"]=cleaned
        out["canonical"]=c
    else:
        mf=dict(out.get("mapped_fields") or {})
        mf["abstract"]=cleaned
        out["mapped_fields"]=mf
    out["abstract_enrichment"]=meta
    return out

def epmc_lookup(doi):
    q=urllib.parse.urlencode({"query":f'DOI:"{doi}"',"format":"json","resultType":"core","pageSize":5})
    req=urllib.request.Request(EPMC+"?"+q,headers={"User-Agent":UA,"Accept":"application/json"})
    errors=[]
    for attempt in range(1,5):
        try:
            with urllib.request.urlopen(req,timeout=30) as resp:
                data=json.load(resp); status=getattr(resp,"status",None); url=resp.geturl()
            hits=data.get("resultList",{}).get("result",[])
            exact=[h for h in hits if norm_doi(h.get("doi"))==doi]
            abstract=next((h.get("abstractText") for h in exact if clean_abstract(h.get("abstractText"))),None)
            return abstract,{"method":"europe_pmc_exact_doi","http_status":status,"url":url,"hit_count":data.get("hitCount"),"exact_doi_hits":len(exact),"attempts":attempt}
        except Exception as e:
            errors.append(f"{type(e).__name__}: {e}")
            transient=isinstance(e,(TimeoutError,urllib.error.URLError)) or (isinstance(e,urllib.error.HTTPError) and (e.code==429 or e.code>=500))
            if attempt==4 or not transient:
                return None,{"method":"europe_pmc_exact_doi","outcome":"technical_error","errors":errors,"attempts":attempt}
            time.sleep((1,2,4)[attempt-1])
    return None,{"method":"europe_pmc_exact_doi","outcome":"technical_error","errors":errors}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--lens",required=True); ap.add_argument("--scopus",required=True)
    ap.add_argument("--openalex",required=True); ap.add_argument("--agricola",required=True)
    ap.add_argument("--output-dir",required=True); ap.add_argument("--no-external",action="store_true")
    ap.add_argument("--delay",type=float,default=0.08)
    args=ap.parse_args()

    sources={s:read_jsonl(getattr(args,s)) for s in ("lens","scopus","openalex","agricola")}
    expected={s:len(v) for s,v in sources.items()}

    # Build exact-DOI donor index from preserved abstracts only.
    donors=defaultdict(list)
    for src,rows in sources.items():
        for r in rows:
            d=record_doi(r); a=clean_abstract(existing_abstract(r))
            if d and a:
                donors[d].append({"source":src,"record_id":record_id(r),"abstract":a})

    # Deterministic donor preference: non-reconstructed source abstracts before OpenAlex;
    # within equal priority prefer the longer cleaned abstract, then stable source/id order.
    priority={"lens":0,"agricola":0,"openalex":1,"scopus":2}
    def choose_donor(items,target_src):
        xs=[x for x in items if x["source"]!=target_src]
        if not xs: return None
        xs.sort(key=lambda x:(priority.get(x["source"],9),-len(x["abstract"]),x["source"],x["record_id"]))
        return xs[0]

    repaired_by_cross=0; existing_n=0; missing_no_doi=0
    unresolved_by_doi=defaultdict(list)
    prepared={}

    for src,rows in sources.items():
        out=[]
        for r in rows:
            rid=record_id(r); d=record_doi(r); old=clean_abstract(existing_abstract(r))
            if old:
                existing_n+=1
                meta={"workflow":"01","status":"existing_abstract","source_record":src,"doi":d,"enriched_at":None,"method":"source_native","canonical_store_modified":False}
                out.append(set_abstract(r,old,meta))
            elif d:
                donor=choose_donor(donors.get(d,[]),src)
                if donor:
                    repaired_by_cross+=1
                    meta={"workflow":"01","status":"abstract_enrichmented_cross_source","source_record":src,"doi":d,"enriched_at":now(),"method":"exact_doi_preserved_source","donor_source":donor["source"],"donor_record_id":donor["record_id"],"canonical_store_modified":False}
                    out.append(set_abstract(r,donor["abstract"],meta))
                else:
                    idx=len(out)
                    meta={"workflow":"01","status":"pending_external_enrichment","source_record":src,"doi":d,"enriched_at":None,"method":None,"canonical_store_modified":False}
                    out.append(set_abstract(r,None,meta))
                    unresolved_by_doi[d].append((src,idx))
            else:
                missing_no_doi+=1
                meta={"workflow":"01","status":"missing_no_doi","source_record":src,"doi":None,"enriched_at":None,"method":None,"canonical_store_modified":False}
                out.append(set_abstract(r,None,meta))
        prepared[src]=out

    epmc_cache={}
    external_recovered=0; external_not_found=0; external_technical=0
    if not args.no_external:
        for n,d in enumerate(sorted(unresolved_by_doi),1):
            abstract,attempt=epmc_lookup(d)
            epmc_cache[d]={"abstract":clean_abstract(abstract),"attempt":attempt}
            if abstract: external_recovered+=1
            elif attempt.get("outcome")=="technical_error": external_technical+=1
            else: external_not_found+=1
            if args.delay and n < len(unresolved_by_doi): time.sleep(args.delay)

        for d,targets in unresolved_by_doi.items():
            hit=epmc_cache[d]
            for src,idx in targets:
                r=prepared[src][idx]
                if hit["abstract"]:
                    meta={"workflow":"01","status":"abstract_enrichmented_europe_pmc","source_record":src,"doi":d,"enriched_at":now(),"method":"europe_pmc_exact_doi","attempt":hit["attempt"],"canonical_store_modified":False}
                    prepared[src][idx]=set_abstract(r,hit["abstract"],meta)
                else:
                    status="external_technical_error" if hit["attempt"].get("outcome")=="technical_error" else "no_abstract_recovered"
                    meta={"workflow":"01","status":status,"source_record":src,"doi":d,"enriched_at":None,"method":"europe_pmc_exact_doi","attempt":hit["attempt"],"canonical_store_modified":False}
                    prepared[src][idx]=set_abstract(r,None,meta)

    outdir=Path(args.output_dir); outdir.mkdir(parents=True,exist_ok=True)
    for src,rows in prepared.items():
        if len(rows)!=expected[src]: raise RuntimeError(f"{src} cardinality changed")
        ids=[record_id(r) for r in rows]
        if len(ids)!=len(set(ids)): raise RuntimeError(f"{src}: duplicate record IDs after repair")
        write_jsonl(outdir/f"{src}_records_for_deduplication.jsonl",rows)

    cache_rows=[{"doi":d,**v} for d,v in sorted(epmc_cache.items())]
    write_jsonl(outdir/"europe_pmc_lookup_cache.jsonl",cache_rows)

    report={
        "workflow":"01_abstract_enrichment","status":"success","created_at":now(),
        "inputs":expected,"existing_abstract_records":existing_n,
        "cross_source_enrichments":repaired_by_cross,"missing_without_doi":missing_no_doi,
        "unique_external_doi_queries":0 if args.no_external else len(unresolved_by_doi),
        "external_abstracts_recovered":external_recovered,
        "external_no_abstract_or_no_match":external_not_found,
        "external_technical_errors":external_technical,
        "external_lookup_skipped":args.no_external,
        "outputs":{s:f"{s}_records_for_deduplication.jsonl" for s in prepared},
        "canonical_store_modified":False,
        "source_payloads_modified":False
    }
    (outdir/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))

if __name__=="__main__": raise SystemExit(main())
