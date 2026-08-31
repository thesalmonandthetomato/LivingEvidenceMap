#!/usr/bin/env python3
"""Test abstract recovery from Semantic Scholar and Crossref.

Targets records with missing abstracts, validates bibliographic identity before
accepting an abstract, writes an audit ledger/report, and never mutates the
canonical JSONL.
"""
from __future__ import annotations
import argparse, html, json, re, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

UA = "LivingEvidenceMap abstract-repair/1.0 (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
MIN_ABSTRACT_CHARS = 80
TITLE_STRICT = 0.94
TITLE_WITH_DOI = 0.86


def clean(v): return re.sub(r"\s+", " ", str(v or "")).strip()
def norm_title(v): return re.sub(r"[^a-z0-9]+", " ", clean(v).lower()).strip()
def title_sim(a,b):
    a,b=norm_title(a),norm_title(b)
    return SequenceMatcher(None,a,b).ratio() if a and b else None
def norm_doi(v):
    s=clean(v).lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p): s=s[len(p):].strip()
    return s or None
def now(): return datetime.now(timezone.utc).isoformat()
def payload(r): return (r.get("lens") or {}).get("raw_payload") or {}
def canonical(r): return r.get("canonical") or {}
def title(r): return clean(canonical(r).get("title") or payload(r).get("title"))
def abstract(r): return clean(canonical(r).get("abstract") or payload(r).get("abstract"))
def lens_id(r): return str((r.get("identity") or {}).get("lens_id") or payload(r).get("lens_id") or "")
def year(r): return str(canonical(r).get("year") or payload(r).get("year") or "").strip()
def doi(r):
    for v in (canonical(r).get("doi"),payload(r).get("doi")):
        d=norm_doi(v)
        if d:return d
    return None

def get_json(url):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"application/json"})
    with urllib.request.urlopen(req,timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8")), getattr(resp,"status",None)

def strip_crossref_jats(s):
    s=re.sub(r"<[^>]+>"," ",str(s or ""))
    return clean(html.unescape(s))

def valid(target_title,target_doi,target_year,cand_title,cand_doi,cand_year):
    sim=title_sim(target_title,cand_title); cd=norm_doi(cand_doi)
    doi_match=None if not target_doi or not cd else target_doi==cd
    year_match=None if not target_year or not cand_year else str(target_year)==str(cand_year)
    if doi_match is False:return False,{"title_similarity":sim,"doi_match":False,"year_match":year_match}
    if target_doi and doi_match is True and sim is not None and sim>=TITLE_WITH_DOI:
        return True,{"title_similarity":sim,"doi_match":True,"year_match":year_match}
    if sim is not None and sim>=TITLE_STRICT and year_match is not False:
        return True,{"title_similarity":sim,"doi_match":doi_match,"year_match":year_match}
    return False,{"title_similarity":sim,"doi_match":doi_match,"year_match":year_match}

def semantic(target_title,target_doi,target_year):
    base="https://api.semanticscholar.org/graph/v1/paper/"
    fields="title,abstract,year,externalIds,url,authors"
    urls=[]
    if target_doi: urls.append(base+urllib.parse.quote("DOI:"+target_doi,safe="")+"?fields="+urllib.parse.quote(fields))
    urls.append(base+"search/match?query="+urllib.parse.quote(target_title)+"&fields="+urllib.parse.quote(fields))
    attempts=[]
    for url in urls:
        try:
            data,status=get_json(url)
            cd=(data.get("externalIds") or {}).get("DOI")
            ok,evidence=valid(target_title,target_doi,target_year,data.get("title"),cd,data.get("year"))
            a=clean(data.get("abstract"))
            att={"status":status,"candidate_title":data.get("title"),"candidate_doi":cd,"candidate_year":data.get("year"),"validation":evidence,"abstract_chars":len(a)}
            attempts.append(att)
            if ok and len(a)>=MIN_ABSTRACT_CHARS:return a,data.get("url"),evidence,attempts
        except urllib.error.HTTPError as e: attempts.append({"error":f"HTTPError:{e.code}"})
        except Exception as e: attempts.append({"error":f"{type(e).__name__}:{e}"})
        time.sleep(1)
    return None,None,None,attempts

def crossref(target_title,target_doi,target_year):
    urls=[]
    if target_doi: urls.append("https://api.crossref.org/works/"+urllib.parse.quote(target_doi,safe=""))
    urls.append("https://api.crossref.org/works?query.bibliographic="+urllib.parse.quote(target_title)+"&rows=2")
    attempts=[]
    for url in urls:
        try:
            data,status=get_json(url); msg=data.get("message") or {}
            candidates=msg.get("items") if isinstance(msg,dict) and "items" in msg else [msg]
            for c in candidates:
                ct=(c.get("title") or [""])[0] if isinstance(c.get("title"),list) else c.get("title")
                cy=None
                for k in ("published-print","published-online","published","issued"):
                    parts=((c.get(k) or {}).get("date-parts") or [])
                    if parts and parts[0]: cy=parts[0][0]; break
                ok,evidence=valid(target_title,target_doi,target_year,ct,c.get("DOI"),cy)
                a=strip_crossref_jats(c.get("abstract"))
                att={"status":status,"candidate_title":ct,"candidate_doi":c.get("DOI"),"candidate_year":cy,"validation":evidence,"abstract_chars":len(a)}
                attempts.append(att)
                if ok and len(a)>=MIN_ABSTRACT_CHARS:return a,c.get("URL"),evidence,attempts
        except urllib.error.HTTPError as e: attempts.append({"error":f"HTTPError:{e.code}"})
        except Exception as e: attempts.append({"error":f"{type(e).__name__}:{e}"})
        time.sleep(1)
    return None,None,None,attempts

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--records",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); ap.add_argument("--max-records",type=int,default=10); args=ap.parse_args()
    records=[json.loads(x) for x in Path(args.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    missing=[r for r in records if title(r) and not abstract(r)][:args.max_records]
    out=[]
    for r in missing:
        t,d,y=title(r),doi(r),year(r)
        sa,surl,se,satt=semantic(t,d,y)
        ca,curl,ce,catt=crossref(t,d,y)
        sources=[]
        if sa:sources.append("semantic_scholar")
        if ca:sources.append("crossref")
        chosen=sa or ca
        out.append({"lens_id":lens_id(r),"title":t,"doi":d,"year":y,"status":"abstract_recovered" if chosen else "not_recovered","recovered_by":sources,"abstract":chosen,"semantic_scholar":{"abstract":sa,"source_url":surl,"identity_evidence":se,"attempts":satt},"crossref":{"abstract":ca,"source_url":curl,"identity_evidence":ce,"attempts":catt},"retrieved_at":now()})
    Path(args.output).write_text("".join(json.dumps(x,ensure_ascii=False)+"\n" for x in out),encoding="utf-8")
    report={"created_at":now(),"input_record_count":len(records),"missing_abstract_count":sum(1 for r in records if title(r) and not abstract(r)),"attempted_count":len(out),"recovered_count":sum(x["status"]=="abstract_recovered" for x in out),"semantic_scholar_recovered":sum(bool(x["semantic_scholar"]["abstract"]) for x in out),"crossref_recovered":sum(bool(x["crossref"]["abstract"]) for x in out),"canonical_mutated":False,"identity_policy":{"doi":"candidate DOI must not conflict; DOI match requires title similarity >= 0.86","without_doi":"title similarity >= 0.94 and publication year must not conflict"},"records":out}
    Path(args.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:report[k] for k in ("input_record_count","missing_abstract_count","attempted_count","recovered_count","semantic_scholar_recovered","crossref_recovered","canonical_mutated")},indent=2))
if __name__=="__main__": main()
