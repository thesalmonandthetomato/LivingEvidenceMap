#!/usr/bin/env python3
"""Recover missing abstracts using ordinary web search for title discovery.

Discovery uses exact-title searches against public Bing and DuckDuckGo HTML
results. Search snippets are never treated as abstracts. Candidate pages are
fetched and accepted only after strict bibliographic identity validation.
Existing abstracts are never overwritten and the canonical JSONL is never
mutated. Every attempt is retained in a separate audit ledger.
"""
from __future__ import annotations

import argparse, html as htmlmod, json, re, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from bs4 import BeautifulSoup

UA = "Mozilla/5.0 (compatible; LivingEvidenceMap abstract-repair/1.0; +https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
MIN_ABSTRACT_CHARS=80
MAX_ABSTRACT_CHARS=12000
MAX_BYTES=5_000_000
TITLE_STRICT=0.94
TITLE_WITH_DOI=0.86
MAX_RESULTS=8


def now(): return datetime.now(timezone.utc).isoformat()
def clean(v):
    if v is None: return ""
    return re.sub(r"\s+"," ",str(v)).strip()
def norm_title(v): return re.sub(r"[^a-z0-9]+"," ",clean(v).lower()).strip()
def title_sim(a,b):
    a,b=norm_title(a),norm_title(b)
    if not a or not b:return None
    return round(SequenceMatcher(None,a,b).ratio(),4)
def norm_doi(v):
    s=clean(v).lower()
    for p in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(p): s=s[len(p):].strip()
    return s or None

def payload(r): return (r.get("lens") or {}).get("raw_payload") or {}
def canonical(r): return r.get("canonical") or {}
def lens_id(r): return str((r.get("identity") or {}).get("lens_id") or payload(r).get("lens_id") or "")
def record_title(r): return clean(canonical(r).get("title") or payload(r).get("title"))
def record_abstract(r): return clean(canonical(r).get("abstract") or payload(r).get("abstract"))
def record_year(r): return str(canonical(r).get("year") or payload(r).get("year") or "").strip()
def record_authors(r):
    vals=canonical(r).get("authors") or payload(r).get("authors") or []
    out=[]
    if isinstance(vals,list):
        for a in vals:
            if isinstance(a,dict): out.append(clean(a.get("name") or a.get("display_name") or a.get("full_name")))
            else: out.append(clean(a))
    return [x for x in out if x]
def record_doi(r):
    c=canonical(r); p=payload(r)
    for v in (c.get("doi"),p.get("doi")):
        d=norm_doi(v)
        if d:return d
    for e in p.get("external_ids") or []:
        if isinstance(e,dict) and str(e.get("type","")).lower()=="doi":
            d=norm_doi(e.get("value"))
            if d:return d
    return None

def fetch(url, accept="text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":accept,"Accept-Language":"en-GB,en;q=0.8"})
    with urllib.request.urlopen(req,timeout=25) as resp:
        data=resp.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES: raise ValueError("response_too_large")
        return data.decode("utf-8",errors="replace"),resp.geturl(),getattr(resp,"status",None),str(resp.headers.get("Content-Type") or "")

def search_bing(title):
    q='"'+title+'"'
    url="https://www.bing.com/search?count=10&q="+urllib.parse.quote(q)
    body,final,status,ctype=fetch(url)
    soup=BeautifulSoup(body,"html.parser")
    out=[]
    for a in soup.select("li.b_algo h2 a"):
        href=clean(a.get("href")); txt=clean(a.get_text(" ",strip=True))
        if href.startswith("http") and href not in [x[0] for x in out]: out.append((href,txt))
    return out[:MAX_RESULTS],{"engine":"bing","url":final,"status":status,"results":len(out)}

def search_ddg(title):
    q='"'+title+'"'
    url="https://html.duckduckgo.com/html/?q="+urllib.parse.quote(q)
    body,final,status,ctype=fetch(url)
    soup=BeautifulSoup(body,"html.parser")
    out=[]
    for a in soup.select("a.result__a"):
        href=clean(a.get("href")); txt=clean(a.get_text(" ",strip=True))
        if href.startswith("//duckduckgo.com/l/?"):
            qs=urllib.parse.parse_qs(urllib.parse.urlparse("https:"+href).query); href=(qs.get("uddg") or [href])[0]
        elif "duckduckgo.com/l/?" in href:
            qs=urllib.parse.parse_qs(urllib.parse.urlparse(href).query); href=(qs.get("uddg") or [href])[0]
        href=urllib.parse.unquote(href)
        if href.startswith("http") and href not in [x[0] for x in out]: out.append((href,txt))
    return out[:MAX_RESULTS],{"engine":"duckduckgo","url":final,"status":status,"results":len(out)}

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
    y,yk=meta(soup,["citation_publication_date","citation_date","dc.date","article:published_time"])
    authors=[]
    for tag in soup.find_all("meta"):
        if clean(tag.get("name")).lower() in {"citation_author","dc.creator"}:
            v=clean(tag.get("content"));
            if v: authors.append(v)
    return {"title":t,"title_key":tk,"doi":norm_doi(d),"doi_key":dk,"date":y,"date_key":yk,"authors":authors}

def extract_abstract(soup):
    v,k=meta(soup,["citation_abstract","dc.description","dcterms.description","eprints.abstract","bepress_citation_abstract","prism.teaser"])
    if len(v)>=MIN_ABSTRACT_CHARS:return v,f"meta:{k}"
    for script in soup.find_all("script"):
        if "ld+json" not in clean(script.get("type")).lower(): continue
        try:data=json.loads(script.string or script.get_text() or "")
        except Exception:continue
        stack=data if isinstance(data,list) else [data]
        while stack:
            obj=stack.pop()
            if isinstance(obj,list): stack.extend(obj); continue
            if not isinstance(obj,dict): continue
            for key in ("abstract","description"):
                v=clean(obj.get(key))
                if len(v)>=MIN_ABSTRACT_CHARS:return v[:MAX_ABSTRACT_CHARS],f"jsonld:{key}"
            stack.extend(v for v in obj.values() if isinstance(v,(dict,list)))
    candidates=[]
    for sel in ("section.abstract","div.abstract","article .abstract","[id*='abstract' i]","[class*='abstract' i]"):
        try:candidates.extend(soup.select(sel))
        except Exception:pass
    best=""
    for c in candidates:
        t=clean(c.get_text(" ",strip=True)); t=re.sub(r"^abstract\s*[:.-]?\s*","",t,flags=re.I)
        if MIN_ABSTRACT_CHARS<=len(t)<=MAX_ABSTRACT_CHARS and len(t)>len(best):best=t
    return (best,"dom_abstract_container") if best else ("",None)

def author_support(target_authors,page_authors):
    if not target_authors or not page_authors:return None
    ta={norm_title(x).split()[-1] for x in target_authors if norm_title(x)}
    pa={norm_title(x).split()[-1] for x in page_authors if norm_title(x)}
    return bool(ta & pa)

def validate(target_title,target_doi,target_year,target_authors,ident):
    sim=title_sim(target_title,ident.get("title"))
    pd=ident.get("doi"); doi_match=None if not pd or not target_doi else pd==target_doi
    if doi_match is False:return False,{"title_similarity":sim,"doi_match":False,"author_support":author_support(target_authors,ident.get("authors"))}
    auth=author_support(target_authors,ident.get("authors"))
    page_year=re.search(r"(?:19|20)\d{2}",ident.get("date") or "")
    year_match=None if not target_year or not page_year else page_year.group(0)==str(target_year)
    if target_doi and doi_match is True and sim is not None and sim>=TITLE_WITH_DOI:
        return True,{"title_similarity":sim,"doi_match":True,"author_support":auth,"year_match":year_match}
    if sim is not None and sim>=TITLE_STRICT and auth is not False and year_match is not False:
        return True,{"title_similarity":sim,"doi_match":doi_match,"author_support":auth,"year_match":year_match}
    return False,{"title_similarity":sim,"doi_match":doi_match,"author_support":auth,"year_match":year_match}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--records",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); ap.add_argument("--max-records",type=int,default=10); ap.add_argument("--delay",type=float,default=1.5); a=ap.parse_args()
    records=[json.loads(x) for x in Path(a.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    missing=[r for r in records if record_title(r) and not record_abstract(r)][:a.max_records]
    results=[]
    for r in missing:
        lid=lens_id(r); title=record_title(r); doi=record_doi(r); year=record_year(r); authors=record_authors(r)
        item={"lens_id":lid,"title":title,"doi":doi,"year":year,"status":"not_recovered","abstract":None,"source_url":None,"extraction_method":None,"search_attempts":[],"candidate_attempts":[],"retrieved_at":now()}
        discovered=[]
        for fn in (search_bing,search_ddg):
            try:
                rows,meta_search=fn(title); item["search_attempts"].append({**meta_search,"outcome":"ok"})
                for u,t in rows:
                    if u not in [x[0] for x in discovered]: discovered.append((u,t,meta_search["engine"]))
            except Exception as e:item["search_attempts"].append({"engine":fn.__name__.replace("search_",""),"outcome":"error","error":f"{type(e).__name__}:{e}"})
            time.sleep(a.delay)
        for url,result_title,engine in discovered[:MAX_RESULTS*2]:
            att={"engine":engine,"url":url,"search_result_title":result_title}
            try:
                body,final,status,ctype=fetch(url)
                att.update({"final_url":final,"http_status":status,"content_type":ctype})
                soup=BeautifulSoup(body,"html.parser")
                ident=page_identity(soup); ok,evidence=validate(title,doi,year,authors,ident)
                att.update({"identity":ident,"validation":evidence})
                if not ok: att["outcome"]="identity_not_strict_enough"
                else:
                    abstract,method=extract_abstract(soup); att.update({"abstract_chars":len(abstract),"extraction_method":method})
                    if abstract:
                        att["outcome"]="abstract_recovered"; item.update({"status":"abstract_recovered","abstract":abstract,"source_url":final,"extraction_method":method,"identity_evidence":evidence}); item["candidate_attempts"].append(att); break
                    att["outcome"]="validated_page_no_abstract"
            except urllib.error.HTTPError as e:att.update({"outcome":"http_error","error":f"HTTPError:{e.code}"})
            except Exception as e:att.update({"outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
            item["candidate_attempts"].append(att); time.sleep(a.delay)
        results.append(item)
    Path(a.output).write_text("".join(json.dumps(x,ensure_ascii=False)+"\n" for x in results),encoding="utf-8")
    counts={}
    for x in results: counts[x["status"]]=counts.get(x["status"],0)+1
    report={"created_at":now(),"input_record_count":len(records),"missing_abstract_count":sum(1 for r in records if record_title(r) and not record_abstract(r)),"attempted_count":len(results),"recovered_count":sum(x["status"]=="abstract_recovered" for x in results),"status_counts":counts,"identity_policy":{"doi_match":"if page exposes DOI it must not conflict; exact DOI plus title similarity >= 0.86 accepted","no_doi":"title similarity >= 0.94 with no contradictory author/year evidence","search_snippets_used_as_abstracts":False},"canonical_mutated":False,"records":results}
    Path(a.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:report[k] for k in ("input_record_count","missing_abstract_count","attempted_count","recovered_count","status_counts","identity_policy","canonical_mutated")},indent=2))
if __name__=="__main__": main()
