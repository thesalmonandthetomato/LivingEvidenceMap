#!/usr/bin/env python3
"""Test abstract recovery from URLs already stored in canonical records.

Selects a deterministic random sample of records with missing abstracts, walks
HTTP(S) URLs already present in each record, validates source identity, and only
then accepts an extracted abstract. Supports ordinary HTML pages plus stored
JSON API URLs. Exact matching DOI is sufficient identity evidence unless a
conflicting DOI is exposed. Does not mutate canonical data.
"""
from __future__ import annotations
import argparse, json, random, re, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from bs4 import BeautifulSoup

UA="Mozilla/5.0 (compatible; LivingEvidenceMap abstract-repair/1.1; +https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
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

def collect_urls(obj,out):
    if isinstance(obj,dict):
        for v in obj.values(): collect_urls(v,out)
    elif isinstance(obj,list):
        for v in obj: collect_urls(v,out)
    elif isinstance(obj,str):
        for u in re.findall(r"https?://[^\s\"'<>]+",obj):
            u=u.rstrip(".,;:)]}")
            if u not in out: out.append(u)

def fetch(url):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.1","Accept-Language":"en-GB,en;q=0.8"})
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
    if dm is False:return False,{"title_similarity":sim,"doi_match":False,"rule":"conflicting_doi"}
    if dm is True:return True,{"title_similarity":sim,"doi_match":True,"rule":"exact_doi"}
    if sim is not None and sim>=0.94:return True,{"title_similarity":sim,"doi_match":dm,"rule":"strict_title"}
    return False,{"title_similarity":sim,"doi_match":dm,"rule":"insufficient_identity"}

def extract_html(soup):
    v,k=meta(soup,["citation_abstract","dc.description","dc.description.abstract","dcterms.description","dcterms.abstract","eprints.abstract","bepress_citation_abstract","prism.teaser","description","og:description"])
    if len(v)>=MIN_CHARS:return v[:MAX_CHARS],f"meta:{k}"
    for script in soup.find_all("script"):
        typ=clean(script.get("type")).lower()
        if "ld+json" not in typ and "application/json" not in typ:continue
        try:data=json.loads(script.string or script.get_text() or "")
        except Exception:continue
        ab,method=extract_json(data)
        if ab:return ab,f"embedded_{method}"
    best=""
    selectors=("section.abstract","div.abstract","article .abstract","[id*='abstract' i]","[class*='abstract' i]","[itemprop='description']","[data-testid*='abstract' i]")
    for sel in selectors:
        try:nodes=soup.select(sel)
        except Exception:nodes=[]
        for n in nodes:
            v=re.sub(r"^abstract\s*[:.-]?\s*","",clean(n.get_text(" ",strip=True)),flags=re.I)
            if MIN_CHARS<=len(v)<=MAX_CHARS and len(v)>len(best):best=v
    if best:return best,"dom_abstract_container"
    # Common repository pages often expose a labelled Abstract row without an abstract class.
    for label in soup.find_all(string=re.compile(r"^\s*Abstract\s*$",re.I)):
        node=label.parent
        for _ in range(4):
            if not node:break
            sib=node.find_next_sibling()
            if sib:
                v=clean(sib.get_text(" ",strip=True))
                if MIN_CHARS<=len(v)<=MAX_CHARS:return v,"labelled_abstract_field"
            node=node.parent
    return "",None

def extract_json(obj):
    candidates=[]
    def walk(x,path="root"):
        if isinstance(x,dict):
            for k,v in x.items():
                kp=f"{path}.{k}"; kl=str(k).lower()
                if kl in {"abstract","abstracttext","abstract_text","description","dc.description","dc.description.abstract"} and isinstance(v,(str,list)):
                    if isinstance(v,list): vv=" ".join(clean(z) for z in v if isinstance(z,(str,int,float)))
                    else: vv=clean(v)
                    vv=re.sub(r"^abstract\s*[:.-]?\s*","",vv,flags=re.I)
                    if MIN_CHARS<=len(vv)<=MAX_CHARS:candidates.append((vv,kp))
                walk(v,kp)
        elif isinstance(x,list):
            for i,v in enumerate(x):walk(v,f"{path}[{i}]")
    walk(obj)
    if not candidates:return "",None
    candidates.sort(key=lambda z:len(z[0]),reverse=True)
    return candidates[0][0][:MAX_CHARS],f"json:{candidates[0][1]}"

def json_identity(obj):
    titles=[]; dois=[]
    def walk(x):
        if isinstance(x,dict):
            for k,v in x.items():
                kl=str(k).lower()
                if kl in {"title","articletitle","article_title"} and isinstance(v,str):titles.append(clean(v))
                if kl in {"doi","digitalobjectidentifier"} and isinstance(v,str):dois.append(norm_doi(v))
                walk(v)
        elif isinstance(x,list):
            for v in x:walk(v)
    walk(obj)
    return {"title":titles[0] if titles else "","title_key":"json","doi":next((d for d in dois if d),None),"doi_key":"json"}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--records",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); ap.add_argument("--max-records",type=int,default=10); ap.add_argument("--seed",default="canonical-source-url-random10-v2-2026-08-31"); ap.add_argument("--delay",type=float,default=.5); a=ap.parse_args()
    records=[json.loads(x) for x in Path(a.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    eligible=[]
    for r in records:
        if not title(r) or abstract(r):continue
        urls=[]; collect_urls(r,urls)
        urls=[u for u in urls if not u.startswith("https://doi.org/")]
        if urls:eligible.append((r,urls))
    rng=random.Random(a.seed); sample=rng.sample(eligible,min(a.max_records,len(eligible)))
    results=[]
    for r,urls in sample:
        item={"lens_id":lid(r),"title":title(r),"doi":doi(r),"stored_url_count":len(urls),"stored_urls":urls,"status":"not_recovered","abstract":None,"source_url":None,"attempts":[],"retrieved_at":now()}
        for url in urls:
            att={"url":url}
            try:
                body,final,status,ctype=fetch(url); att.update({"final_url":final,"http_status":status,"content_type":ctype})
                is_json="json" in ctype.lower() or body.lstrip().startswith(("{","["))
                if is_json:
                    data=json.loads(body); ident=json_identity(data); ok,evidence=valid(title(r),doi(r),ident); att.update({"identity":ident,"validation":evidence,"response_type":"json"})
                    if not ok:att["outcome"]="identity_not_strict_enough"
                    else:
                        ab,method=extract_json(data); att.update({"abstract_chars":len(ab),"extraction_method":method})
                        if ab:
                            att["outcome"]="abstract_recovered"; item.update({"status":"abstract_recovered","abstract":ab,"source_url":final,"extraction_method":method,"identity_evidence":evidence}); item["attempts"].append(att);break
                        att["outcome"]="validated_json_no_abstract"
                else:
                    soup=BeautifulSoup(body,"html.parser"); ident=page_identity(soup); ok,evidence=valid(title(r),doi(r),ident); att.update({"identity":ident,"validation":evidence,"response_type":"html"})
                    if not ok:att["outcome"]="identity_not_strict_enough"
                    else:
                        ab,method=extract_html(soup); att.update({"abstract_chars":len(ab),"extraction_method":method})
                        if ab:
                            att["outcome"]="abstract_recovered"; item.update({"status":"abstract_recovered","abstract":ab,"source_url":final,"extraction_method":method,"identity_evidence":evidence}); item["attempts"].append(att);break
                        att["outcome"]="validated_page_no_abstract"
            except urllib.error.HTTPError as e:att.update({"outcome":"http_error","error":f"HTTPError:{e.code}"})
            except Exception as e:att.update({"outcome":"technical_error","error":f"{type(e).__name__}:{e}"})
            item["attempts"].append(att);time.sleep(a.delay)
        results.append(item)
    Path(a.output).parent.mkdir(parents=True,exist_ok=True); Path(a.output).write_text("".join(json.dumps(x,ensure_ascii=False)+"\n" for x in results),encoding="utf-8")
    counts={}; methods={}
    for x in results:
        counts[x["status"]]=counts.get(x["status"],0)+1
        if x.get("extraction_method"):methods[x["extraction_method"]]=methods.get(x["extraction_method"],0)+1
    report={"created_at":now(),"input_record_count":len(records),"missing_abstract_count":sum(1 for r in records if title(r) and not abstract(r)),"eligible_missing_with_stored_urls":len(eligible),"sample_seed":a.seed,"sample_count":len(results),"recovered_count":sum(x["status"]=="abstract_recovered" for x in results),"status_counts":counts,"extraction_methods":methods,"identity_policy":{"exact_doi":"accept regardless of truncated/missing title unless another DOI conflicts","without_doi":"title similarity >= 0.94"},"canonical_mutated":False,"records":results}
    Path(a.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"); print(json.dumps({k:report[k] for k in ("input_record_count","missing_abstract_count","eligible_missing_with_stored_urls","sample_seed","sample_count","recovered_count","status_counts","extraction_methods","canonical_mutated")},indent=2))
if __name__=="__main__":main()
