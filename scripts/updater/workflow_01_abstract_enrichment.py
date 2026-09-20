#!/usr/bin/env python3
"""Workflow 01: source-independent external abstract enrichment.

Each Workflow 00 source is handled independently. Existing source-native abstracts
are retained unchanged and are not treated as enrichment. Records still missing
abstracts are queried against Europe PMC by exact normalised DOI, and an abstract is accepted only when the
record's own title is compatible with the Europe PMC title (Jaro-Winkler >= 0.90).

A DOI lookup cache is shared only to avoid repeated Europe PMC requests. No
cross-source record matching, abstract transfer, or deduplication is performed.
Source payloads and the canonical store remain immutable.
"""
from __future__ import annotations

import argparse
import html
import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

EPMC="https://www.ebi.ac.uk/europepmc/webservices/rest/search"
UA="LivingEvidenceMap Workflow 01 abstract enrichment"
MAX_CHARS=12000
TITLE_THRESHOLD=0.90
SHORT_ABSTRACT_CHARS=300
ELLIPSIS_RE=re.compile(r"(?:\.{3,}|…)[\s\]\)\}"']*$")

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

def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")

def read_jsonl(path):
    rows=[]
    with open(path,encoding="utf-8") as f:
        for n,line in enumerate(f,1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except Exception as e:
                raise RuntimeError(f"{path}:{n}: invalid JSON: {e}") from e
    return rows

def write_jsonl(path,rows):
    Path(path).parent.mkdir(parents=True,exist_ok=True)
    with open(path,"w",encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row,ensure_ascii=True,separators=(",",":"))+"\n")

def clean_abstract(value):
    if value is None:
        return None
    s=unicodedata.normalize("NFKC",str(value))
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

def norm_doi(value):
    if not value:
        return None
    s=str(value).strip().lower()
    for prefix in ("https://doi.org/","http://doi.org/","http://dx.doi.org/","doi:"):
        if s.startswith(prefix):
            s=s[len(prefix):].strip()
    return s.rstrip(".") or None

def kind(record):
    if isinstance(record.get("lens"),dict):
        return "lens"
    provider=(record.get("source") or {}).get("provider")
    if provider=="scopus":
        return "scopus"
    if provider=="openalex":
        return "openalex"
    if provider=="agricola_via_europe_pmc":
        return "agricola"
    raise RuntimeError(f"Unknown source record shape: provider={provider!r}")

def record_id(record):
    if kind(record)=="lens":
        identity=record.get("identity") or {}
        return str(identity.get("lens_id") or identity.get("record_id") or "")
    return str((record.get("sidecar_identity") or {}).get("sidecar_record_id") or "")

def record_doi(record):
    if kind(record)=="lens":
        canonical=record.get("canonical") if isinstance(record.get("canonical"),dict) else {}
        if canonical.get("doi"):
            return norm_doi(canonical.get("doi"))
        payload=(record.get("lens") or {}).get("raw_payload") or {}
        for item in payload.get("external_ids") or []:
            if isinstance(item,dict) and str(item.get("type","")).lower()=="doi" and item.get("value"):
                return norm_doi(item.get("value"))
        return None
    return norm_doi(
        (record.get("mapped_fields") or {}).get("doi")
        or (record.get("sidecar_identity") or {}).get("doi")
    )

def record_title(record):
    if kind(record)=="lens":
        canonical=record.get("canonical") if isinstance(record.get("canonical"),dict) else {}
        payload=(record.get("lens") or {}).get("raw_payload") or {}
        return canonical.get("title") or payload.get("title")
    return (record.get("mapped_fields") or {}).get("title")

def existing_abstract(record):
    if kind(record)=="lens":
        canonical=record.get("canonical") if isinstance(record.get("canonical"),dict) else {}
        payload=(record.get("lens") or {}).get("raw_payload") or {}
        return canonical.get("abstract") or payload.get("abstract")
    return (record.get("mapped_fields") or {}).get("abstract")

def norm_title(value):
    if not value:
        return None
    s=html.unescape(str(value))
    s=unicodedata.normalize("NFKD",s)
    s="".join(ch for ch in s if not unicodedata.combining(ch))
    s=s.casefold()
    s=re.sub(r"[^a-z0-9]+"," ",s)
    s=re.sub(r"\s+"," ",s).strip()
    return s or None

def jaro_winkler(a,b):
    a=norm_title(a)
    b=norm_title(b)
    if not a or not b:
        return None
    if a==b:
        return 1.0
    la,lb=len(a),len(b)
    match_distance=max(0,max(la,lb)//2-1)
    a_match=[False]*la
    b_match=[False]*lb
    matches=0
    for i,ch in enumerate(a):
        start=max(0,i-match_distance)
        end=min(i+match_distance+1,lb)
        for j in range(start,end):
            if b_match[j] or b[j]!=ch:
                continue
            a_match[i]=True
            b_match[j]=True
            matches+=1
            break
    if not matches:
        return 0.0
    a_chars=[a[i] for i in range(la) if a_match[i]]
    b_chars=[b[j] for j in range(lb) if b_match[j]]
    transpositions=sum(x!=y for x,y in zip(a_chars,b_chars))/2
    jaro=(matches/la + matches/lb + (matches-transpositions)/matches)/3
    prefix=0
    for x,y in zip(a,b):
        if x!=y or prefix==4:
            break
        prefix+=1
    return jaro + prefix*0.1*(1-jaro)

def abstract_query_reason(value):
    cleaned=clean_abstract(value)
    if not cleaned:
        return "missing"
    if ELLIPSIS_RE.search(cleaned):
        return "ellipsis_truncated"
    if len(cleaned)<SHORT_ABSTRACT_CHARS:
        return "very_short"
    return None

def replacement_is_more_complete(existing,candidate,reason):
    old=clean_abstract(existing) or ""
    new=clean_abstract(candidate) or ""
    if not new:
        return False
    if reason=="missing":
        return True
    if reason=="ellipsis_truncated":
        return len(new)>len(old)+20
    if reason=="very_short":
        return len(new)>=SHORT_ABSTRACT_CHARS and len(new)>=max(len(old)+100,int(len(old)*1.5))
    return False

def annotate(record,meta):
    out=dict(record)
    out["abstract_enrichment"]=meta
    return out

def set_abstract(record,text,meta):
    out=dict(record)
    cleaned=clean_abstract(text)
    if kind(record)=="lens":
        canonical=dict(out.get("canonical") or {})
        payload=(out.get("lens") or {}).get("raw_payload") or {}
        source=payload.get("source")
        source_title=source.get("title") if isinstance(source,dict) else source
        defaults={
            "record_id":(out.get("identity") or {}).get("record_id") or record_id(out),
            "lens_id":(out.get("identity") or {}).get("lens_id") or record_id(out),
            "title":payload.get("title"),
            "authors":payload.get("authors"),
            "year":payload.get("year_published") or payload.get("date_published"),
            "source":source_title,
            "doi":record_doi(out),
        }
        for key,value in defaults.items():
            if canonical.get(key) in (None,"") and value not in (None,""):
                canonical[key]=value
        canonical["abstract"]=cleaned
        out["canonical"]=canonical
    else:
        mapped=dict(out.get("mapped_fields") or {})
        mapped["abstract"]=cleaned
        out["mapped_fields"]=mapped
    out["abstract_enrichment"]=meta
    return out

def epmc_lookup(doi):
    query=urllib.parse.urlencode({
        "query":f'DOI:"{doi}"',
        "format":"json",
        "resultType":"core",
        "pageSize":5,
    })
    req=urllib.request.Request(
        EPMC+"?"+query,
        headers={"User-Agent":UA,"Accept":"application/json"},
    )
    errors=[]
    for attempt in range(1,5):
        try:
            with urllib.request.urlopen(req,timeout=30) as resp:
                data=json.load(resp)
                status=getattr(resp,"status",None)
                url=resp.geturl()
            hits=data.get("resultList",{}).get("result",[])
            exact=[hit for hit in hits if norm_doi(hit.get("doi"))==doi]
            candidates=[
                {
                    "title":hit.get("title"),
                    "abstract":clean_abstract(hit.get("abstractText")),
                    "pmid":hit.get("pmid"),
                    "pmcid":hit.get("pmcid"),
                }
                for hit in exact
                if clean_abstract(hit.get("abstractText"))
            ]
            return {
                "candidates":candidates,
                "attempt":{
                    "method":"europe_pmc_exact_doi_title_compatible",
                    "http_status":status,
                    "url":url,
                    "hit_count":data.get("hitCount"),
                    "exact_doi_hits":len(exact),
                    "outcome":"candidate_abstracts_found" if candidates else (
                        "matched_no_abstract" if exact else "no_exact_match"
                    ),
                    "request_attempts":attempt,
                    "retry_errors":errors,
                },
            }
        except Exception as e:
            errors.append(f"{type(e).__name__}: {e}")
            transient=(
                isinstance(e,(TimeoutError,urllib.error.URLError))
                or (isinstance(e,urllib.error.HTTPError) and (e.code==429 or e.code>=500))
            )
            if attempt==4 or not transient:
                return {
                    "candidates":[],
                    "attempt":{
                        "method":"europe_pmc_exact_doi_title_compatible",
                        "outcome":"technical_error",
                        "errors":errors,
                        "request_attempts":attempt,
                    },
                }
            time.sleep((1,2,4)[attempt-1])
    raise RuntimeError("Unreachable Europe PMC lookup state")

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--lens",required=True)
    ap.add_argument("--scopus",required=True)
    ap.add_argument("--openalex",required=True)
    ap.add_argument("--agricola",required=True)
    ap.add_argument("--output-dir",required=True)
    ap.add_argument("--no-external",action="store_true")
    ap.add_argument("--delay",type=float,default=0.08)
    args=ap.parse_args()

    source_names=("lens","scopus","openalex","agricola")
    sources={name:read_jsonl(getattr(args,name)) for name in source_names}
    expected={name:len(rows) for name,rows in sources.items()}

    prepared={}
    targets_by_doi=defaultdict(list)
    per_source={}

    for source,rows in sources.items():
        out=[]
        stats={
            "input_records":len(rows),
            "existing_complete_abstracts_not_queried":0,
            "missing_abstract_targets":0,
            "ellipsis_truncated_targets":0,
            "very_short_targets":0,
            "targets_without_doi":0,
            "targets_without_title":0,
            "external_enrichment_targets":0,
            "abstracts_recovered_from_europe_pmc":0,
            "truncated_or_short_abstracts_replaced":0,
            "compatible_result_not_more_complete":0,
            "no_compatible_abstract_recovered":0,
            "external_technical_errors":0,
        }
        for record in rows:
            doi=record_doi(record)
            title=record_title(record)
            old=existing_abstract(record)
            reason=abstract_query_reason(old)

            if reason is None:
                stats["existing_complete_abstracts_not_queried"]+=1
                meta={
                    "workflow":"01",
                    "provider":source,
                    "status":"existing_complete_abstract_not_queried",
                    "doi":doi,
                    "enriched_at":None,
                    "method":None,
                    "canonical_store_modified":False,
                }
                out.append(annotate(record,meta))
                continue

            stats[{
                "missing":"missing_abstract_targets",
                "ellipsis_truncated":"ellipsis_truncated_targets",
                "very_short":"very_short_targets",
            }[reason]]+=1

            if not doi:
                stats["targets_without_doi"]+=1
                meta={
                    "workflow":"01",
                    "provider":source,
                    "status":f"{reason}_no_doi",
                    "doi":None,
                    "query_reason":reason,
                    "enriched_at":None,
                    "method":None,
                    "canonical_store_modified":False,
                }
                out.append(annotate(record,meta))
                continue

            if not norm_title(title):
                stats["targets_without_title"]+=1
                meta={
                    "workflow":"01",
                    "provider":source,
                    "status":f"{reason}_no_title",
                    "doi":doi,
                    "query_reason":reason,
                    "enriched_at":None,
                    "method":None,
                    "canonical_store_modified":False,
                }
                out.append(annotate(record,meta))
                continue

            stats["external_enrichment_targets"]+=1
            idx=len(out)
            meta={
                "workflow":"01",
                "provider":source,
                "status":"pending_external_enrichment" if not args.no_external else "external_enrichment_not_run",
                "doi":doi,
                "query_reason":reason,
                "existing_abstract_chars":len(clean_abstract(old) or ""),
                "enriched_at":None,
                "method":None,
                "canonical_store_modified":False,
            }
            out.append(annotate(record,meta))
            targets_by_doi[doi].append((source,idx,title,reason,old))
        prepared[source]=out
        per_source[source]=stats

    lookup_cache={}
    if not args.no_external:
        dois=sorted(targets_by_doi)
        for n,doi in enumerate(dois,1):
            lookup_cache[doi]=epmc_lookup(doi)
            if n==1 or n%250==0 or n==len(dois):
                print(f"Europe PMC progress: {n}/{len(dois)} unique DOI lookups",flush=True)
            if args.delay and n<len(dois):
                time.sleep(args.delay)

        for doi,targets in targets_by_doi.items():
            lookup=lookup_cache[doi]
            attempt=lookup["attempt"]
            for source,idx,target_title,reason,existing_text in targets:
                record=prepared[source][idx]
                if attempt.get("outcome")=="technical_error":
                    per_source[source]["external_technical_errors"]+=1
                    meta={
                        "workflow":"01",
                        "provider":source,
                        "status":"external_technical_error",
                        "doi":doi,
                        "enriched_at":None,
                        "method":"europe_pmc_exact_doi_title_compatible",
                        "attempt":attempt,
                        "canonical_store_modified":False,
                    }
                    prepared[source][idx]=annotate(record,meta)
                    continue

                compatible=[]
                for candidate in lookup["candidates"]:
                    similarity=jaro_winkler(target_title,candidate.get("title"))
                    if similarity is not None and similarity>=TITLE_THRESHOLD:
                        compatible.append((similarity,candidate))
                compatible.sort(key=lambda item:-item[0])

                if compatible:
                    similarity,candidate=compatible[0]
                    candidate_text=candidate["abstract"]
                    if replacement_is_more_complete(existing_text,candidate_text,reason):
                        per_source[source]["abstracts_recovered_from_europe_pmc"]+=1
                        if reason in {"ellipsis_truncated","very_short"}:
                            per_source[source]["truncated_or_short_abstracts_replaced"]+=1
                        meta={
                            "workflow":"01",
                            "provider":source,
                            "status":"abstract_enriched_europe_pmc" if reason=="missing" else "abstract_repaired_europe_pmc",
                            "doi":doi,
                            "query_reason":reason,
                            "existing_abstract_chars":len(clean_abstract(existing_text) or ""),
                            "replacement_abstract_chars":len(clean_abstract(candidate_text) or ""),
                            "enriched_at":now(),
                            "method":"europe_pmc_exact_doi_title_compatible",
                            "title_similarity":round(similarity,6),
                            "europe_pmc_id":{
                                "pmid":candidate.get("pmid"),
                                "pmcid":candidate.get("pmcid"),
                            },
                            "attempt":attempt,
                            "canonical_store_modified":False,
                        }
                        prepared[source][idx]=set_abstract(record,candidate_text,meta)
                    else:
                        per_source[source]["compatible_result_not_more_complete"]+=1
                        meta={
                            "workflow":"01",
                            "provider":source,
                            "status":"compatible_europe_pmc_abstract_not_more_complete",
                            "doi":doi,
                            "query_reason":reason,
                            "existing_abstract_chars":len(clean_abstract(existing_text) or ""),
                            "candidate_abstract_chars":len(clean_abstract(candidate_text) or ""),
                            "enriched_at":None,
                            "method":"europe_pmc_exact_doi_title_compatible",
                            "title_similarity":round(similarity,6),
                            "attempt":attempt,
                            "canonical_store_modified":False,
                        }
                        prepared[source][idx]=annotate(record,meta)
                else:
                    per_source[source]["no_compatible_abstract_recovered"]+=1
                    meta={
                        "workflow":"01",
                        "provider":source,
                        "status":"no_compatible_abstract_recovered",
                        "doi":doi,
                        "query_reason":reason,
                        "enriched_at":None,
                        "method":"europe_pmc_exact_doi_title_compatible",
                        "attempt":attempt,
                        "canonical_store_modified":False,
                    }
                    prepared[source][idx]=annotate(record,meta)

    outdir=Path(args.output_dir)
    outdir.mkdir(parents=True,exist_ok=True)

    for source,rows in prepared.items():
        if len(rows)!=expected[source]:
            raise RuntimeError(f"{source}: cardinality changed")
        ids=[record_id(record) for record in rows]
        if not all(ids):
            raise RuntimeError(f"{source}: blank record ID after enrichment")
        if len(ids)!=len(set(ids)):
            raise RuntimeError(f"{source}: duplicate record IDs after enrichment")
        write_jsonl(outdir/f"{source}_records_for_deduplication.jsonl",rows)

    cache_rows=[{"doi":doi,**value} for doi,value in sorted(lookup_cache.items())]
    write_jsonl(outdir/"europe_pmc_lookup_cache.jsonl",cache_rows)

    report={
        "workflow":"01_abstract_enrichment",
        "status":"success",
        "created_at":now(),
        "methodology":{
            "source_processing":"independent",
            "complete_existing_abstracts":"retained unchanged and not queried",
            "missing_abstracts":"queried against Europe PMC when DOI and title are available",
            "ellipsis_truncated_abstracts":"queried against Europe PMC and replaced only by a longer title-compatible abstract",
            "very_short_abstracts":f"existing abstracts under {SHORT_ABSTRACT_CHARS} cleaned characters are queried and replaced only by a substantially fuller title-compatible abstract",
            "cross_source_matching_performed":False,
            "cross_source_abstract_transfer_performed":False,
            "deduplication_performed":False,
            "external_provider":"Europe PMC",
            "external_match_rule":"exact normalised DOI plus Jaro-Winkler title similarity >= 0.90",
            "shared_doi_lookup_cache":"efficiency only; every target record is title-matched independently",
        },
        "inputs":expected,
        "per_source":per_source,
        "unique_doi_targets_for_external_enrichment":len(targets_by_doi),
        "unique_external_doi_queries":0 if args.no_external else len(lookup_cache),
        "external_lookup_skipped":args.no_external,
        "outputs":{source:f"{source}_records_for_deduplication.jsonl" for source in prepared},
        "canonical_store_modified":False,
        "source_payloads_modified":False,
    }
    (outdir/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))

if __name__=="__main__":
    raise SystemExit(main())
