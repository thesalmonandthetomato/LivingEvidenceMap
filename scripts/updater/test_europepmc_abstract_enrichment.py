#!/usr/bin/env python3
"""Test Europe PMC DOI-only abstract recovery for Lens records missing abstracts.

This is a validation utility only. Existing Lens abstracts are never changed.
Only records with a missing Lens abstract and a Lens DOI are queried.
"""
from __future__ import annotations
import argparse, json, time, urllib.parse, urllib.request
from pathlib import Path

BASE="https://www.ebi.ac.uk/europepmc/webservices/rest/search"

def raw(r):
    return r.get("lens",{}).get("raw_payload",{}) if isinstance(r.get("lens"),dict) else {}

def first(v):
    if isinstance(v,list): return next((x for x in v if x),None)
    return v

def doi(r):
    p=raw(r)
    candidates=[p.get("doi"),p.get("DOI"),p.get("external_ids",{}).get("doi") if isinstance(p.get("external_ids"),dict) else None]
    for v in candidates:
        v=first(v)
        if v:
            s=str(v).strip()
            if s.lower().startswith("https://doi.org/"): s=s[16:]
            if s.lower().startswith("doi:"): s=s[4:].strip()
            return s
    return None

def abstract(r):
    p=raw(r); c=r.get("canonical",{}) if isinstance(r.get("canonical"),dict) else {}
    return c.get("abstract") or p.get("abstract")

def lens_id(r): return str(r.get("identity",{}).get("lens_id") or raw(r).get("lens_id") or "")

def epmc(d):
    q=urllib.parse.urlencode({"query":f'DOI:"{d}"',"format":"json","resultType":"core","pageSize":5})
    req=urllib.request.Request(BASE+"?"+q,headers={"User-Agent":"LivingEvidenceMap abstract-enrichment test"})
    with urllib.request.urlopen(req,timeout=30) as resp: return json.load(resp)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--input",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); a=ap.parse_args()
    rows=[json.loads(x) for x in Path(a.input).read_text(encoding="utf-8").splitlines() if x.strip()]
    results=[]
    for r in rows:
        if abstract(r): continue
        d=doi(r)
        item={"lens_id":lens_id(r),"doi":d,"status":None,"abstract":None,"europe_pmc":None}
        if not d:
            item["status"]="no_doi"; results.append(item); continue
        try:
            data=epmc(d); hits=data.get("resultList",{}).get("result",[])
            exact=[h for h in hits if str(h.get("doi") or "").lower()==d.lower()]
            item["europe_pmc"]={"hit_count":data.get("hitCount"),"exact_doi_hits":exact}
            if not exact: item["status"]="no_exact_match"
            else:
                abst=next((h.get("abstractText") for h in exact if h.get("abstractText")),None)
                if abst: item["status"]="abstract_recovered"; item["abstract"]=abst
                else: item["status"]="matched_no_abstract"
        except Exception as e:
            item["status"]="technical_error"; item["error"]=type(e).__name__+": "+str(e)
        results.append(item); time.sleep(0.08)
    Path(a.output).write_text("".join(json.dumps(x,ensure_ascii=False)+"\n" for x in results),encoding="utf-8")
    counts={}
    for x in results: counts[x["status"]]=counts.get(x["status"],0)+1
    report={"total_input_records":len(rows),"missing_abstract":len(results),"status_counts":counts,"recovered":sum(x["status"]=="abstract_recovered" for x in results)}
    Path(a.report).write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))
if __name__=="__main__": main()
