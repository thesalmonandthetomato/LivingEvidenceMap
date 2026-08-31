#!/usr/bin/env python3
"""Test abstract recovery from URLs already stored in canonical records.

Selects a deterministic random sample of records with missing abstracts, walks
HTTP(S) URLs already present in each record, validates page identity, and only
then accepts an extracted abstract. Does not mutate canonical data.
"""
from __future__ import annotations
import argparse, hashlib, json, random, re, time, urllib.error, urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from bs4 import BeautifulSoup

UA="Mozilla/5.0 (compatible; LivingEvidenceMap abstract-repair/1.0; +https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
MIN_CHARS=80; MAX_CHARS=12000; MAX_BYTES=5_000_000

def now(): return datetime.now(timezone.utc).isoformat()
def clean(v): return re.sub(r"\s+"," ",str(v or "")).strip()
def norm_title(v): return re.sub(r"[^a-z0-9]+"," ",clean(v).lower()).strip()
def title_sim(a,b):
    a,b=norm_title(a),norm_title(b)
    return round(SequenceMatcher(None,a,b).ratio(),4) if a and b else None
def norm_doi(v):
    s=clean(v).lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p): s=s[len(p):].strip()
    return s or None
def payload(r): return (r.get("lens") or {}).get("raw_payload") or {}
def canonical(r): return r.get("canonical") or {}
def lid(r): return str((r.get("identity") or {}).get("lens_id") or payload(r).get("lens_id") or "")
def title(r): return clean(canonical(r).get("title") or payload(r).get("title"))
def abstract(r): return clean(canonical(r).get("abstract") or payload(r).get("abstract"))
def doi(r): return norm_doi(canonical(r).get("doi") or payload(r).get("doi"))

def collect_urls(obj,out,key=""):
    if isinstance(obj,dict):
        for k,v in obj.items():
            collect_urls(v,out,k)
    elif isinstance(obj,list):
        for v in obj: collect_urls(v,out,key)
    elif isinstance(obj,str):
        for u in re.findall(r"https?://[^\s\"'<>]+",obj):
            u=u.rstrip(".,;:)]}")
            if u not in out: out.append(u)

def fetch(url):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"text/html,application/xhtml+xml;q=0.9,*/*;q=0.1","Accept-Language":"en-GB,en;q=0.8"})
    with urllib.request.urlopen(req,timeout=25) as resp:
        data=resp.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES: raise ValueError("response_too_large")
        return data.decode("utf-8",errors="replace"),resp.geturl(),getattr(resp,"status",None),str(resp.headers.get("Content-Type") or "")

def meta(soup,names):
    wanted={x.lower() for x in names}
    for tag in soup.find_all("meta"):
        k=clean(tag.get("name") or tag.get("property")).lower()
        if k in wanted:
            v=clean(tag.get("content"))
            if v:return v,k
    return "",None

def page_identity(soup):
    t,tk=meta(soup,["citation_title","dc.title","dcterms.title","og:title","twitter:title"])
    if not t and soup.title: t=clean(soup.title.get_text(" ",strip=True)); tk="html_title"
    d,dk=meta(soup,["citation_doi","dc.identifier.doi","prism.doi","doi"])
    return {"title":t,"title_key":tk,"doi":norm_doi(d),"doi_key":dk}
def valid(target_title,target_doi,ident):
    sim=title_sim(target_title,ident.get("title")); pd=ident.get("doi")
    dm=None if not pd or not target_doi else pd==target_doi
    if dm is False:return False,{"title_similarity":sim,"doi_match":False}
    if dm is True and sim is not None and sim>=0.86:return True,{"title_similarity":sim,"doi_match":True}
    if sim is not None and sim>=0.94:return True,{"title_similarity":sim,"doi_match":dm}
    return False,{"title_similarity":sim,"doi_match":dm}
def extract(soup):
    v,k=meta(soup,["citation_abstract","dc.description","dcterms.description","eprints.abstract","bepress_citation_abstract","prism.teaser"])
    if len(v)>=MIN_CHARS:return v[:MAX_CHARS],f"meta:{k}"
    for script in soup.find_all("script"):
        if "ld+json" not in clean(script.get("type")).lower():continue
        try:data=json.loads(script.string or script.get_text() or "")
        except Exception:continue
        stack=data if isinstance(data,list) else [data]
        while stack:
            o=stack.pop()
            if isinstance(o,list):stack.extend(o);continue
            if not isinstance(o,dict):continue
            for k in ("abstract","description"):
                v=clean(o.get(k))
                if len(v)>=MIN_CHARS:return v[:MAX_CHARS],f"jsonld:{k}"
            stack.extend(x for x in o.values() if isinstance(x,(dict,list)))
    best=""
    for sel in ("section.abstract","div.abstract","article .abstract","[id*='abstract' i]","[class*='abstract' i]"):
        try:nodes=soup.select(sel)
        except Exception:nodes=[]
        for n in nodes:
            v=re.sub(r"^abstract\s*[:.-]?\s*","",clean(n.get_text(" ",strip=True)),flags=re.I)
            if MIN_CHARS<=len(v)<=MAX_CHARS and len(v)>len(best):best=v
    return (best,"dom_abstract_container") if best else ("",None)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--records",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); ap.add_argument("--max-records",type=int,default=10); ap.add_argument("--seed",default="canonical-source-url-random10-2026-08-31"); ap.add_argument("--delay",type=float,default=.5); a=ap.parse_args()
    records=[json.loads(x) for x in Path(a.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    eligible=[]
    for r in records:
        if not title(r) or abstract(r):continue
        urls=[]; collect_urls(r,urls)
        urls=[u for u in urls if not u.startswith("https://doi.org/") and "api." not in urllib.request.urlparse(u).netloc.lower()]
        if urls:eligible.append((r,urls))
    rng=random.Random(a.seed); sample=rng.sample(eligible,min(a.max_records,len(eligible)))
    results=[]
    for r,urls in sample:
        item={"lens_id":lid(r),"title":title(r),"doi":doi(r),"stored_url_count":len(urls),"stored_urls":urls,"status":"not_recovered","abstract":None,"source_url":None,"attempts":[],"retrieved_at":now()}
        for url in urls:
            att={"url":url}
            try:
                body,final,status,ctype=fetch(url); att.update({"final_url":final,"http_status":status,"content_type":ctype})
                soup=BeautifulSoup(body,"html.parser"); ident=page_identity(soup); ok,evidence=valid(title(r),doi(r),ident); att.update({"identity":ident,"validation":evidence})
                if not ok:att["outcome"]="identity_not_strict_enough"
                else:
                    ab,method=extract(soup); att.update({"abstract_chars":len(ab),"extraction_method":method})
                    if ab:
                        att["outcome"]="abstract_recovered"; item.update({"status":"abstract_recovered","abstract":ab,"source_url":final,"extraction_method":method,"identity_evidence":evidence}); item["attempts"].append(att);break
                    att["outcome"]="validated_page_no_abstract"
            except urllib.error.HTTPError as e:att.update({"outcome":"http_error","error":f"HTTPError:{e.code}"})
            except Exception as e:att.update({"outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
            item["attempts"].append(att);time.sleep(a.delay)
        results.append(item)
    Path(a.output).parent.mkdir(parents=True,exist_ok=True); Path(a.output).write_text("".join(json.dumps(x,ensure_ascii=False)+"\n" for x in results),encoding="utf-8")
    counts={}
    for x in results:counts[x["status"]]=counts.get(x["status"],0)+1
    report={"created_at":now(),"input_record_count":len(records),"missing_abstract_count":sum(1 for r in records if title(r) and not abstract(r)),"eligible_missing_with_stored_urls":len(eligible),"sample_seed":a.seed,"sample_count":len(results),"recovered_count":sum(x["status"]=="abstract_recovered" for x in results),"status_counts":counts,"canonical_mutated":False,"records":results}
    Path(a.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"); print(json.dumps({k:report[k] for k in ("input_record_count","missing_abstract_count","eligible_missing_with_stored_urls","sample_seed","sample_count","recovered_count","status_counts","canonical_mutated")},indent=2))
if __name__=="__main__":main()
