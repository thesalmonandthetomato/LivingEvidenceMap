#!/usr/bin/env python3
"""Workflow 01B: Europe PMC-only abstract enrichment for DOI-bearing Lens records.

Canonical abstracts are cleaned at the end of enrichment so downstream deduplication
sees comparable plain text. The original source payload is never modified.
"""
from __future__ import annotations
import argparse, html, json, re, time, unicodedata, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

BASE="https://www.ebi.ac.uk/europepmc/webservices/rest/search"
UA="LivingEvidenceMap abstract enrichment"
MAX_CHARS=12000
EPMC_MAX_ATTEMPTS=4
EPMC_BACKOFF_SECONDS=(1,2,4)

SECTION_LABELS={
    "abstract","aim","aims","background","conclusion","conclusions","discussion",
    "importance","introduction","method","methods","objective","objectives","purpose",
    "result","results","summary"
}
BLOCK_TAG_RE=re.compile(r"</?(?:abstract|abstract-text|body|br|div|p|sec|section|title)(?:\s[^>]*)?>",re.I)
TAG_RE=re.compile(r"<[^>]+>")
COMMENT_RE=re.compile(r"<!--.*?-->",re.S)
CDATA_RE=re.compile(r"<!\[CDATA\[(.*?)\]\]>",re.S)
JATS_TITLE_RE=re.compile(r"<title(?:\s[^>]*)?>(.*?)</title>",re.I|re.S)

def now(): return datetime.now(timezone.utc).isoformat()
def payload(r):
    p=r.get("lens",{}).get("raw_payload",{}) if isinstance(r.get("lens"),dict) else {}
    if not isinstance(p,dict): raise RuntimeError("lens.raw_payload is not an object")
    return p

def read_json_object_stream(path):
    """Read whitespace-separated JSON objects, allowing objects to span physical lines."""
    text=Path(path).read_text(encoding="utf-8")
    decoder=json.JSONDecoder()
    rows=[]; pos=0; n=len(text)
    while True:
        while pos<n and text[pos].isspace(): pos+=1
        if pos>=n: break
        try:
            obj,end=decoder.raw_decode(text,pos)
        except json.JSONDecodeError as e:
            context=text[max(0,e.pos-80):min(n,e.pos+80)].replace("\n","\\n")
            raise RuntimeError(f"Invalid canonical JSON near character {e.pos}: {e.msg}; context={context!r}") from e
        if not isinstance(obj,dict):
            raise RuntimeError(f"Expected a top-level JSON object at character {pos}, got {type(obj).__name__}")
        rows.append(obj); pos=end
    return rows

def clean_abstract(v):
    if v is None: return None
    s=unicodedata.normalize("NFKC",str(v))
    s=CDATA_RE.sub(lambda m:m.group(1),s)
    s=COMMENT_RE.sub(" ",s)
    def title_repl(m):
        inner=TAG_RE.sub(" ",html.unescape(m.group(1)))
        label=re.sub(r"[^a-z]+"," ",inner.casefold()).strip()
        return " " if label in SECTION_LABELS else f" {inner} "
    s=JATS_TITLE_RE.sub(title_repl,s)
    s=BLOCK_TAG_RE.sub(" ",s)
    s=TAG_RE.sub(" ",s)
    s=html.unescape(html.unescape(s))
    s=BLOCK_TAG_RE.sub(" ",s)
    s=TAG_RE.sub(" ",s)
    s=re.sub(r"\s+"," ",s).strip()
    s=re.sub(r"^abstract\s*[:.\-–—]?\s*","",s,flags=re.I)
    return s[:MAX_CHARS] if s else None

def norm_doi(v):
    if not v: return None
    s=str(v).strip().lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p): s=s[len(p):].strip()
    return s or None

def lens_id(r): return str(r.get("identity",{}).get("lens_id") or payload(r).get("lens_id") or "")
def doi(r):
    c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    if c.get("doi"): return norm_doi(c.get("doi"))
    for x in payload(r).get("external_ids") or []:
        if isinstance(x,dict) and str(x.get("type","")).lower()=="doi" and x.get("value"):
            return norm_doi(x.get("value"))
    return None

def existing_abstract(r):
    c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    for v in (c.get("abstract"),payload(r).get("abstract")):
        if isinstance(v,str) and v.strip(): return v
    return None

def canonicalise(r, abstract_value, fill_defaults=True):
    """Return canonical metadata with only the requested abstract change in clean-only mode."""
    old=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    result=dict(old)
    if fill_defaults:
        p=payload(r)
        src=p.get("source"); src_title=src.get("title") if isinstance(src,dict) else src
        defaults={
            "record_id":r.get("identity",{}).get("record_id") or lens_id(r),
            "lens_id":lens_id(r),
            "title":p.get("title"),
            "authors":p.get("authors"),
            "year":p.get("year_published") or p.get("date_published"),
            "source":src_title,
            "doi":doi(r),
        }
        for key,value in defaults.items():
            if result.get(key) in (None,"") and value not in (None,""): result[key]=value
    result["abstract"]=clean_abstract(abstract_value)
    return result

def transient_epmc_error(e):
    if isinstance(e, urllib.error.HTTPError): return e.code == 429 or 500 <= e.code < 600
    return isinstance(e, (TimeoutError, urllib.error.URLError))
def epmc_lookup(d):
    q=urllib.parse.urlencode({"query":f'DOI:\"{d}\"',"format":"json","resultType":"core","pageSize":5})
    req=urllib.request.Request(BASE+"?"+q,headers={"User-Agent":UA,"Accept":"application/json"})
    errors=[]
    for attempt_no in range(1,EPMC_MAX_ATTEMPTS+1):
        try:
            with urllib.request.urlopen(req,timeout=30) as resp:
                data=json.load(resp); final_url=resp.geturl(); status=getattr(resp,"status",None)
            hits=data.get("resultList",{}).get("result",[])
            exact=[h for h in hits if norm_doi(h.get("doi"))==d]
            abstract=next((h.get("abstractText") for h in exact if clean_abstract(h.get("abstractText"))),None)
            outcome="abstract_recovered" if abstract else ("matched_no_abstract" if exact else "no_exact_match")
            return abstract,{"method":"europe_pmc_exact_doi","url":final_url,"http_status":status,"hit_count":data.get("hitCount"),"exact_doi_hits":len(exact),"outcome":outcome,"request_attempts":attempt_no,"retry_errors":errors}
        except Exception as e:
            errors.append(f"{type(e).__name__}: {e}")
            if attempt_no >= EPMC_MAX_ATTEMPTS or not transient_epmc_error(e):
                raise RuntimeError(f"Europe PMC failed after {attempt_no} attempt(s): {' | '.join(errors)}") from e
            time.sleep(EPMC_BACKOFF_SECONDS[attempt_no-1])

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--input",required=True); ap.add_argument("--output",required=True)
    ap.add_argument("--audit",required=True); ap.add_argument("--report",required=True)
    ap.add_argument("--delay",type=float,default=0.08)
    ap.add_argument("--clean-only",action="store_true")
    ap.add_argument("--expected-records",type=int,default=None)
    args=ap.parse_args()
    rows=read_json_object_stream(args.input)
    if args.expected_records is not None and len(rows)!=args.expected_records:
        raise RuntimeError(f"Canonical cardinality guard failed: expected {args.expected_records} records, parsed {len(rows)}")
    out=[]; audit=[]
    for r in rows:
        d=doi(r); old=existing_abstract(r); recovered=None; attempts=[]
        original_canonical=(r.get("canonical") or {}).get("abstract") if isinstance(r.get("canonical"),dict) else None
        if old: status="existing_abstract"
        elif args.clean_only: status="missing_clean_only"
        elif not d: status="missing_no_doi"
        else:
            try:
                recovered,attempt=epmc_lookup(d); attempts.append(attempt)
            except Exception as e:
                attempts.append({"method":"europe_pmc_exact_doi","outcome":"technical_error","error":f"{type(e).__name__}: {e}"})
            status="abstract_recovered" if recovered else "no_abstract_recovered"
        source_abstract=old or recovered
        cleaned_abstract=clean_abstract(source_abstract)
        enriched=dict(r)
        enriched["canonical"]=canonicalise(r,source_abstract,fill_defaults=not args.clean_only)
        if not args.clean_only:
            enriched["abstract_enrichment"]={"workflow":"01B","provider":"europe_pmc","status":status,"doi":d,"retrieved_at":now() if recovered else None,"attempts":attempts,"cleaning":{"method":"html_jats_plaintext_v1","source_chars":len(source_abstract or ""),"cleaned_chars":len(cleaned_abstract or ""),"changed":bool(source_abstract and cleaned_abstract != source_abstract)}}
        canonical_changed=original_canonical != enriched["canonical"].get("abstract")
        out.append(enriched)
        audit.append({"lens_id":lens_id(r),"doi":d,"status":status,"abstract_chars":len(cleaned_abstract or ""),"abstract_source_chars":len(source_abstract or ""),"abstract_text_normalised":bool(source_abstract and cleaned_abstract != source_abstract),"canonical_abstract_changed":canonical_changed,"attempts":attempts})
        if d and not old and not args.clean_only: time.sleep(args.delay)
    for path in (Path(args.output),Path(args.audit),Path(args.report)): path.parent.mkdir(parents=True,exist_ok=True)
    Path(args.output).write_text("".join(json.dumps(x,ensure_ascii=True,separators=(",",":"))+"\n" for x in out),encoding="utf-8")
    Path(args.audit).write_text("".join(json.dumps(x,ensure_ascii=True,separators=(",",":"))+"\n" for x in audit),encoding="utf-8")
    counts={}
    for x in audit: counts[x["status"]]=counts.get(x["status"],0)+1
    report={
        "workflow":"01B_abstract_enrichment","provider":"europe_pmc","created_at":now(),
        "mode":"clean_only" if args.clean_only else "enrich_and_clean",
        "total_records":len(rows),"expected_records":args.expected_records,"status_counts":counts,
        "doi_missing_abstract_targets":sum(bool(x["doi"]) and x["status"] not in {"existing_abstract","missing_clean_only"} for x in audit),
        "abstracts_recovered":counts.get("abstract_recovered",0),
        "abstract_texts_normalised":sum(bool(x["abstract_text_normalised"]) for x in audit),
        "canonical_abstracts_changed":sum(bool(x["canonical_abstract_changed"]) for x in audit),
        "abstract_cleaning_method":"html_jats_plaintext_v1","output":"deduplication_ready"
    }
    Path(args.report).write_text(json.dumps(report,indent=2,ensure_ascii=True)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))
if __name__=="__main__": raise SystemExit(main())
