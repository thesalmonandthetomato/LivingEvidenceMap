#!/usr/bin/env python3
"""Test DOI-only OpenAlex abstract enrichment on JSONL records.

Only records with a missing Lens abstract are queried. DOI is the sole lookup
key. Existing Lens abstracts are never modified. OpenAlex data are retained
separately with provenance; recovered abstracts are also exposed under
canonical.abstract for inspection.
"""
import argparse, json, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path


def now(): return datetime.now(timezone.utc).isoformat()

def payload(r):
    return r.get("lens", {}).get("raw_payload", {}) if isinstance(r.get("lens"), dict) else {}

def doi(r):
    for x in payload(r).get("external_ids") or []:
        if isinstance(x, dict) and str(x.get("type", "")).lower() == "doi" and x.get("value"):
            return str(x["value"]).strip().lower().removeprefix("https://doi.org/").removeprefix("http://doi.org/")
    return None

def reconstruct(inv):
    if not inv: return None
    positions = []
    for word, locs in inv.items():
        for pos in locs: positions.append((int(pos), word))
    if not positions: return None
    positions.sort()
    return " ".join(word for _, word in positions).strip() or None

def lookup_openalex(d):
    url = "https://api.openalex.org/works/https://doi.org/" + urllib.parse.quote(d, safe="")
    req = urllib.request.Request(url, headers={"User-Agent": "LivingEvidenceMap abstract enrichment test (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = json.load(resp)
        return raw, None
    except urllib.error.HTTPError as e:
        if e.code == 404: return None, "not_found"
        return None, f"HTTPError:{e.code}"
    except Exception as e:
        return None, type(e).__name__ + ":" + str(e)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--input",required=True); ap.add_argument("--output",required=True); ap.add_argument("--report",required=True); ap.add_argument("--delay",type=float,default=0.12); a=ap.parse_args()
    rows=[json.loads(x) for x in Path(a.input).read_text(encoding="utf-8").splitlines() if x.strip()]
    stats={"total":len(rows),"lens_abstract_present":0,"lens_abstract_missing":0,"missing_with_doi":0,"missing_without_doi":0,"openalex_found":0,"openalex_not_found":0,"openalex_errors":0,"abstract_recovered":0,"openalex_found_without_abstract":0}
    out=[]; detail=[]
    for i,r in enumerate(rows,1):
        p=payload(r); existing=p.get("abstract")
        enriched=dict(r)
        if existing:
            stats["lens_abstract_present"]+=1; out.append(enriched); continue
        stats["lens_abstract_missing"]+=1; d=doi(r)
        entry={"lens_id":r.get("identity",{}).get("lens_id"),"title":p.get("title"),"doi":d,"status":None,"abstract_recovered":False}
        if not d:
            stats["missing_without_doi"]+=1; entry["status"]="no_doi"; detail.append(entry); out.append(enriched); continue
        stats["missing_with_doi"]+=1
        raw,err=lookup_openalex(d)
        if err:
            if err=="not_found": stats["openalex_not_found"]+=1
            else: stats["openalex_errors"]+=1
            entry["status"]=err; detail.append(entry); out.append(enriched); time.sleep(a.delay); continue
        stats["openalex_found"]+=1
        abstract=reconstruct(raw.get("abstract_inverted_index"))
        entry.update({"status":"found","openalex_id":raw.get("id"),"openalex_title":raw.get("title"),"abstract_recovered":bool(abstract)})
        enriched["enrichment"]={**(enriched.get("enrichment") or {}),"openalex_abstract_test":{"lookup":"doi_exact","doi":d,"retrieved_at":now(),"openalex_id":raw.get("id"),"abstract":abstract,"raw_payload":raw}}
        if abstract:
            stats["abstract_recovered"]+=1
            canonical=dict(enriched.get("canonical") or {})
            if not canonical.get("abstract"):
                canonical["abstract"]=abstract; canonical["abstract_source"]="openalex"; canonical["abstract_source_id"]=raw.get("id")
            enriched["canonical"]=canonical
        else: stats["openalex_found_without_abstract"]+=1
        detail.append(entry); out.append(enriched); time.sleep(a.delay)
        if i%20==0: print(f"processed {i}/{len(rows)}", flush=True)
    Path(a.output).write_text("".join(json.dumps(r,ensure_ascii=False,separators=(",",":"))+"\n" for r in out),encoding="utf-8")
    report={"created_at":now(),"lookup_policy":"Only Lens records missing abstract; exact DOI lookup in OpenAlex; no title fallback; no overwrite of Lens abstract.","stats":stats,"records":detail}
    Path(a.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(stats,indent=2))
if __name__=="__main__": main()
