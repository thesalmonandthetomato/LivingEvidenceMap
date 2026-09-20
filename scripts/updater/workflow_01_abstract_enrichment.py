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

def record_title(r):
    if kind(r)=="lens":
        c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
        p=(r.get("lens") or {}).get("raw_payload") or {}
        return c.get("title") or p.get("title")
    return (r.get("mapped_fields") or {}).get("title")

def norm_title(v):
    if not v: return None
    s=html.unescape(str(v))
    s=unicodedata.normalize("NFKD",s)
    s="".join(ch for ch in s if not unicodedata.combining(ch))
    s=s.casefold()
    s=re.sub(r"[^a-z0-9]+"," ",s)
    s=re.sub(r"\s+"," ",s).strip()
    return s or None

def jaro_winkler(a,b):
    a=norm_title(a); b=norm_title(b)
    if not a or not b: return None
    if a==b: return 1.0
    la,lb=len(a),len(b)
    match_distance=max(la,lb)//2-1
    a_match=[False]*la; b_match=[False]*lb
    matches=0
    for i,ch in enumerate(a):
        start=max(0,i-match_distance); end=min(i+match_distance+1,lb)
        for j in range(start,end):
            if b_match[j] or b[j]!=ch: continue
            a_match[i]=True; b_match[j]=True; matches+=1; break
    if not matches: return 0.0
    a_chars=[a[i] for i in range(la) if a_match[i]]
    b_chars=[b[j] for j in range(lb) if b_match[j]]
    transpositions=sum(x!=y for x,y in zip(a_chars,b_chars))/2
    jaro=(matches/la + matches/lb + (matches-transpositions)/matches)/3
    prefix=0
    for x,y in zip(a,b):
        if x!=y or prefix==4: break
        prefix+=1
    return jaro + prefix*0.1*(1-jaro)

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
            candidates=[
                {"title":h.get("title"),"abstract":clean_abstract(h.get("abstractText"))}
                for h in exact if clean_abstract(h.get("abstractText"))
            ]
            return candidates,{"method":"europe_pmc_exact_doi_title_compatible","http_status":status,"url":url,"hit_count":data.get("hitCount"),"exact_doi_hits":len(exact),"attempts":attempt}
        except Exception as e:
            errors.append(f"{type(e).__name__}: {e}")
            transient=isinstance(e,(TimeoutError,urllib.error.URLError)) or (isinstance(e,urllib.error.HTTPError) and (e.code==429 or e.code>=500))
            if attempt==4 or not transient:
                return [],{"method":"europe_pmc_exact_doi_title_compatible","outcome":"technical_error","errors":errors,"attempts":attempt}
            time.sleep((1,2,4)[attempt-1])
    return [],{"method":"europe_pmc_exact_doi_title_compatible","outcome":"technical_error","errors":errors}

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
                donors[d].append({"source":src,"record_id":record_id(r),"title":record_title(r),"abstract":a})

    # Match rule reused from the reconciliation audit: exact normalised DOI generates
    # candidates, but title Jaro-Winkler similarity >= 0.90 is required to transfer text.
    priority={"lens":0,"agricola":0,"openalex":1,"scopus":2}
    def choose_donor(items,target_src,target_title):
        xs=[x for x in items if x["source"]!=target_src]
        scored=[]
        for x in xs:
            sim=jaro_winkler(target_title,x.get("title"))
            if sim is not None:
                scored.append((sim,x))
        compatible=[(sim,x) for sim,x in scored if sim>=0.90]
        compatible.sort(key=lambda z:(priority.get(z[1]["source"],9),-z[0],-len(z[1]["abstract"]),z[1]["source"],z[1]["record_id"]))
        diagnostics={
            "candidate_count":len(xs),
            "title_comparable_count":len(scored),
            "title_compatible_count":len(compatible),
            "title_conflict_count":sum(sim<0.90 for sim,_ in scored),
            "best_title_similarity":max((sim for sim,_ in scored),default=None)
        }
        return (compatible[0][1] if compatible else None),diagnostics

    repaired_by_cross=0; existing_n=0; missing_no_doi=0
    doi_title_conflict_records=0; doi_title_unavailable_records=0
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
                target_title=record_title(r)
                donor,diag=choose_donor(donors.get(d,[]),src,target_title)
                if donor:
                    repaired_by_cross+=1
                    meta={"workflow":"01","status":"abstract_enriched_cross_source","source_record":src,"doi":d,"enriched_at":now(),"method":"exact_doi_title_compatible_preserved_source","title_similarity":jaro_winkler(target_title,donor.get("title")),"donor_source":donor["source"],"donor_record_id":donor["record_id"],"canonical_store_modified":False}
                    out.append(set_abstract(r,donor["abstract"],meta))
                else:
                    idx=len(out)
                    if diag["candidate_count"] and diag["title_comparable_count"] and diag["title_conflict_count"]==diag["title_comparable_count"]:
                        status="doi_title_conflict"
                        doi_title_conflict_records+=1
                    elif diag["candidate_count"] and diag["title_comparable_count"]==0:
                        status="doi_title_unavailable"
                        doi_title_unavailable_records+=1
                    else:
                        status="pending_external_enrichment"
                    meta={"workflow":"01","status":status,"source_record":src,"doi":d,"enriched_at":None,"method":None,"title_match_diagnostics":diag,"canonical_store_modified":False}
                    out.append(set_abstract(r,None,meta))
                    unresolved_by_doi[d].append((src,idx,target_title))
            else:
                missing_no_doi+=1
                meta={"workflow":"01","status":"missing_no_doi","source_record":src,"doi":None,"enriched_at":None,"method":None,"canonical_store_modified":False}
                out.append(set_abstract(r,None,meta))
        prepared[src]=out

    epmc_cache={}
    external_recovered=0; external_not_found=0; external_technical=0
    if not args.no_external:
        for n,d in enumerate(sorted(unresolved_by_doi),1):
            candidates,attempt=epmc_lookup(d)
            epmc_cache[d]={"candidates":candidates,"attempt":attempt}
            if not candidates:
                if attempt.get("outcome")=="technical_error": external_technical+=1
                else: external_not_found+=1
            if args.delay and n < len(unresolved_by_doi): time.sleep(args.delay)

        for d,targets in unresolved_by_doi.items():
            hit=epmc_cache[d]
            for src,idx,target_title in targets:
                r=prepared[src][idx]
                compatible=[]
                for cand in hit["candidates"]:
                    sim=jaro_winkler(target_title,cand.get("title"))
                    if sim is not None and sim>=0.90:
                        compatible.append((sim,cand))
                compatible.sort(key=lambda z:-z[0])
                if compatible:
                    sim,cand=compatible[0]
                    external_recovered+=1
                    meta={"workflow":"01","status":"abstract_enriched_europe_pmc","source_record":src,"doi":d,"enriched_at":now(),"method":"europe_pmc_exact_doi_title_compatible","title_similarity":sim,"attempt":hit["attempt"],"canonical_store_modified":False}
                    prepared[src][idx]=set_abstract(r,cand["abstract"],meta)
                else:
                    status="external_technical_error" if hit["attempt"].get("outcome")=="technical_error" else "no_compatible_abstract_recovered"
                    meta={"workflow":"01","status":status,"source_record":src,"doi":d,"enriched_at":None,"method":"europe_pmc_exact_doi_title_compatible","attempt":hit["attempt"],"canonical_store_modified":False}
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
        "doi_title_conflict_records":doi_title_conflict_records,
        "doi_title_unavailable_records":doi_title_unavailable_records,
        "unique_unresolved_dois_after_cross_source_enrichment":len(unresolved_by_doi),
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
