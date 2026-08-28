#!/usr/bin/env python3
"""Workflow 01B: enrich DOI-bearing Lens records that lack abstracts.

Input is Workflow 01 canonical JSONL. lens.raw_payload is never modified.
A complete canonical bibliographic object is emitted for Workflow 02, with
abstract recovery attempted in this order:
  1. Europe PMC exact DOI
  2. Lens-provided source URLs (generic HTML/meta/JSON-LD extraction)
  3. Crossref exact DOI metadata
Existing abstracts are never overwritten. No title search, generated publisher
URLs, access-control bypass, or full-text scraping is performed.
"""
from __future__ import annotations
import argparse, json, re, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any
from bs4 import BeautifulSoup

UA="LivingEvidenceMap abstract enrichment (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
EPMC="https://www.ebi.ac.uk/europepmc/webservices/rest/search"
CROSSREF="https://api.crossref.org/works/"
MIN_CHARS=80; MAX_CHARS=12000; MAX_BYTES=5_000_000

def now(): return datetime.now(timezone.utc).isoformat()
def payload(r):
    p=r.get("lens",{}).get("raw_payload",{}) if isinstance(r.get("lens"),dict) else {}
    if not isinstance(p,dict): raise RuntimeError("lens.raw_payload is not an object")
    return p
def clean(v):
    if v is None:return None
    s=re.sub(r"\s+"," ",str(v)).strip(); s=re.sub(r"^abstract\s*[:.-]?\s*","",s,flags=re.I)
    return s[:MAX_CHARS] if s else None
def norm_doi(v):
    if not v:return None
    s=str(v).strip().lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p):s=s[len(p):].strip()
    return s or None
def doi(r):
    c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    if c.get("doi"): return norm_doi(c["doi"])
    for x in payload(r).get("external_ids") or []:
        if isinstance(x,dict) and str(x.get("type","")).lower()=="doi" and x.get("value"): return norm_doi(x["value"])
    return None
def lens_id(r): return str(r.get("identity",{}).get("lens_id") or payload(r).get("lens_id") or "")
def title(r): return (r.get("canonical") or {}).get("title") if isinstance(r.get("canonical"),dict) else payload(r).get("title")
def norm_title(v): return re.sub(r"[^a-z0-9]+"," ",str(v or "").lower()).strip()
def title_sim(a,b):
    a,b=norm_title(a),norm_title(b); return None if not a or not b else round(SequenceMatcher(None,a,b).ratio(),4)
def existing_abstract(r):
    c=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    return clean(c.get("abstract") or payload(r).get("abstract"))
def canonicalise(r, abstract_value):
    p=payload(r); old=r.get("canonical") if isinstance(r.get("canonical"),dict) else {}
    source=p.get("source"); source_title=source.get("title") if isinstance(source,dict) else source
    return {
      "record_id":old.get("record_id") or r.get("identity",{}).get("record_id") or lens_id(r),
      "lens_id":old.get("lens_id") or lens_id(r),
      "title":old.get("title") or p.get("title"),
      "authors":old.get("authors") or p.get("authors"),
      "year":old.get("year") or p.get("year_published") or p.get("date_published"),
      "source":old.get("source") or source_title,
      "doi":old.get("doi") or doi(r),
      "abstract":abstract_value,
    }
def add_url(v,out):
    if isinstance(v,str):
        v=v.strip()
        if v.startswith(("http://","https://")) and v not in out:out.append(v)
    elif isinstance(v,list):
        for x in v:add_url(x,out)
    elif isinstance(v,dict):
        for k in ("url","source_url","link","value","href"):
            if v.get(k):add_url(v[k],out)
        for x in v.values():
            if isinstance(x,(dict,list)):add_url(x,out)
def source_urls(r):
    out=[]; p=payload(r)
    for k in ("source_urls","urls","url","links"):
        if k in p:add_url(p[k],out)
    return out
def request_json(url, params=None):
    if params:url += "?"+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"application/json"})
    with urllib.request.urlopen(req,timeout=30) as resp:return json.load(resp),resp.geturl(),getattr(resp,"status",None)
def epmc(d):
    data,url,status=request_json(EPMC,{"query":f'DOI:"{d}"',"format":"json","resultType":"core","pageSize":5})
    hits=data.get("resultList",{}).get("result",[]); exact=[h for h in hits if norm_doi(h.get("doi"))==d]
    a=next((clean(h.get("abstractText")) for h in exact if clean(h.get("abstractText"))),None)
    return a,{"method":"europe_pmc_exact_doi","url":url,"http_status":status,"hit_count":data.get("hitCount"),"exact_doi_hits":len(exact),"outcome":"abstract_recovered" if a else ("matched_no_abstract" if exact else "no_exact_match")}
def meta(soup,keys):
    wanted={k.lower() for k in keys}
    for tag in soup.find_all("meta"):
        k=str(tag.get("name") or tag.get("property") or "").strip().lower()
        if k in wanted:
            v=clean(tag.get("content"))
            if v:return v,k
    return None,None
def fetch_html(url):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"})
    with urllib.request.urlopen(req,timeout=30) as resp:
        data=resp.read(MAX_BYTES+1); final=resp.geturl(); status=getattr(resp,"status",None); ctype=str(resp.headers.get("Content-Type") or "")
    if len(data)>MAX_BYTES:raise ValueError("response_too_large")
    if "html" not in ctype.lower() and not data.lstrip().startswith(b"<"):raise ValueError("not_html")
    return data.decode("utf-8",errors="replace"),final,status,ctype
def html_abstract(html):
    soup=BeautifulSoup(html,"html.parser")
    for tag in list(soup.find_all(["style","noscript"])):tag.decompose()
    v,k=meta(soup,["citation_abstract","dc.description","dcterms.description","eprints.abstract","bepress_citation_abstract","prism.teaser"])
    if v and len(v)>=MIN_CHARS:return v,f"meta:{k}",soup
    for script in soup.find_all("script"):
        if "ld+json" not in str(script.get("type") or "").lower():continue
        try:data=json.loads(script.string or script.get_text() or "")
        except Exception:continue
        for obj in (data if isinstance(data,list) else [data]):
            if isinstance(obj,dict):
                for key in ("abstract","description"):
                    v=clean(obj.get(key))
                    if v and len(v)>=MIN_CHARS:return v,f"jsonld:{key}",soup
    candidates=[]
    for sel in ("section.abstract","div.abstract","article .abstract","[id*='abstract' i]","[class*='abstract' i]"):
        try:candidates.extend(soup.select(sel))
        except Exception:pass
    best=None
    for c in candidates:
        v=clean(c.get_text(" ",strip=True))
        if v and MIN_CHARS<=len(v)<=MAX_CHARS and (best is None or len(v)>len(best)):best=v
    return (best,"dom_abstract_container",soup) if best else (None,None,soup)
def html_identity(soup,d,t):
    pd,_=meta(soup,["citation_doi","dc.identifier.doi","prism.doi","doi"]); pt,_=meta(soup,["citation_title","dc.title","dcterms.title","og:title","twitter:title"])
    if not pt and soup.title:pt=clean(soup.title.get_text(" ",strip=True))
    nd=norm_doi(pd); dm=None if not nd else nd==d; ts=title_sim(t,pt)
    return dm is not False and not(dm is None and ts is not None and ts<0.72),{"page_doi":nd,"doi_match":dm,"page_title":pt,"title_similarity":ts}
def crossref(d,t):
    data,url,status=request_json(CROSSREF+urllib.parse.quote(d,safe="")); msg=data.get("message") or {}; rd=norm_doi(msg.get("DOI")); titles=msg.get("title") or []; rt=titles[0] if isinstance(titles,list) and titles else titles if isinstance(titles,str) else None; ts=title_sim(t,rt)
    raw=msg.get("abstract"); a=clean(BeautifulSoup(str(raw),"html.parser").get_text(" ",strip=True)) if raw else None
    ok=rd==d and not(ts is not None and ts<0.72); a=a if ok and a and len(a)>=MIN_CHARS else None
    return a,{"method":"crossref_exact_doi","url":url,"http_status":status,"response_doi":rd,"doi_match":rd==d,"response_title":rt,"title_similarity":ts,"outcome":"abstract_recovered" if a else "no_abstract_detected"}
def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--input",required=True); ap.add_argument("--output",required=True); ap.add_argument("--audit",required=True); ap.add_argument("--report",required=True); ap.add_argument("--delay",type=float,default=.25); args=ap.parse_args()
    rows=[json.loads(x) for x in Path(args.input).read_text(encoding="utf-8").splitlines() if x.strip()]; out=[]; audits=[]
    for r in rows:
        lid=lens_id(r); d=doi(r); old=existing_abstract(r); recovered=None; source=None; attempts=[]
        if old: status="existing_abstract"
        elif not d: status="missing_no_doi"
        else:
            for method in ("epmc","lens_urls","crossref"):
                if recovered:break
                if method=="epmc":
                    try:recovered,att=epmc(d); attempts.append(att)
                    except Exception as e:attempts.append({"method":"europe_pmc_exact_doi","outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
                elif method=="lens_urls":
                    for url in source_urls(r):
                        try:
                            html,final,http,ctype=fetch_html(url); a,extract,soup=html_abstract(html); ok,ident=html_identity(soup,d,title(r)); att={"method":"lens_source_url","source_url":url,"final_url":final,"http_status":http,"content_type":ctype,"identity":ident,"extraction_method":extract}
                            if not ok:att["outcome"]="identity_mismatch"
                            elif a:recovered=a;source=final;att["outcome"]="abstract_recovered"
                            else:att["outcome"]="no_abstract_detected"
                            attempts.append(att)
                            if recovered:break
                        except Exception as e:attempts.append({"method":"lens_source_url","source_url":url,"outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
                        time.sleep(args.delay)
                else:
                    try:recovered,att=crossref(d,title(r)); attempts.append(att); source=att.get("url") if recovered else source
                    except Exception as e:attempts.append({"method":"crossref_exact_doi","outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
            status="abstract_recovered" if recovered else "no_abstract_recovered"
        enriched=dict(r); enriched["canonical"]=canonicalise(r,old or recovered); enriched["abstract_enrichment"]={"workflow":"01B","status":status,"doi":d,"source":source,"retrieved_at":now() if recovered else None,"attempts":attempts}; out.append(enriched)
        audits.append({"lens_id":lid,"doi":d,"status":status,"abstract_chars":len(old or recovered or ""),"source":source,"attempts":attempts})
        if d and not old:time.sleep(args.delay)
    Path(args.output).parent.mkdir(parents=True,exist_ok=True); Path(args.output).write_text("".join(json.dumps(x,ensure_ascii=False,separators=(",",":"))+"\n" for x in out),encoding="utf-8"); Path(args.audit).write_text("".join(json.dumps(x,ensure_ascii=False,separators=(",",":"))+"\n" for x in audits),encoding="utf-8")
    counts={}
    for x in audits:counts[x["status"]]=counts.get(x["status"],0)+1
    report={"workflow":"01B_abstract_enrichment","created_at":now(),"total_records":len(rows),"status_counts":counts,"doi_missing_abstract_targets":sum(x["doi"] and x["status"] not in {"existing_abstract"} for x in audits),"abstracts_recovered":counts.get("abstract_recovered",0),"output":"deduplication_ready"}
    Path(args.report).write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8"); print(json.dumps(report,indent=2))
if __name__=="__main__":raise SystemExit(main())
