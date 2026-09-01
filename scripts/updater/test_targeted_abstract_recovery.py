#!/usr/bin/env python3
"""Small, read-only tests of publisher/repository abstract recovery routes.

Selects up to N canonical records that still lack an abstract and have a URL for
one named provider. It attempts a provider-specific structured route first where
available, then structured HTML metadata. Nothing is written back to canonical.
"""
from __future__ import annotations

import argparse
import html
import json
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import urlparse

UA = "LivingEvidenceMap/1.0 (targeted abstract recovery test; contact via GitHub repository)"
MIN_ABSTRACT_CHARS = 80
MAX_ABSTRACT_CHARS = 12000
DOI_RE = re.compile(r"10\.\d{4,9}/[-._;()/:A-Z0-9]+", re.I)
URL_RE = re.compile(r"https?://[^\s\]\[\)\(<>\"']+", re.I)

PROVIDERS = {
    "europepmc": ["ebi.ac.uk", "europepmc.org"],
    "sciencedirect": ["sciencedirect.com"],
    "cabdirect": ["cabdirect.org"],
    "ncbi": ["ncbi.nlm.nih.gov"],
    "wiley": ["onlinelibrary.wiley.com"],
    "doaj": ["doaj.org"],
    "bibsys": ["brage.bibsys.no", "bibsys.no"],
    "ecite": ["ecite.utas.edu.au"],
    "pubag": ["pubag.nal.usda.gov"],
    "core": ["core.ac.uk"],
}


def clean(v):
    return re.sub(r"\s+", " ", html.unescape(str(v or ""))).strip()


def getv(d, *paths):
    for path in paths:
        cur = d
        ok = True
        for key in path:
            if not isinstance(cur, dict) or key not in cur:
                ok = False
                break
            cur = cur[key]
        if ok and cur not in (None, "", []):
            return cur
    return None


def title_of(r):
    return clean(getv(r, ("canonical", "title"), ("title",), ("raw", "title")))


def abstract_of(r):
    return clean(getv(r, ("canonical", "abstract"), ("abstract",), ("raw", "abstract")))


def record_id(r):
    return str(getv(r, ("identity", "lens_id"), ("record_id",), ("lens_id",), ("canonical", "lens_id")) or "")


def norm_doi(v):
    if isinstance(v, list):
        v = next((x for x in v if x), None)
    s = clean(v).lower()
    s = re.sub(r"^https?://(dx\.)?doi\.org/", "", s)
    s = re.sub(r"^doi:\s*", "", s)
    m = DOI_RE.search(s)
    return m.group(0).rstrip(".,;)").lower() if m else None


def doi_of(r):
    return norm_doi(getv(r, ("canonical", "doi"), ("doi",), ("identifiers", "doi"), ("raw", "doi")))


def all_urls(obj):
    out = set()
    def walk(x):
        if isinstance(x, dict):
            for v in x.values(): walk(v)
        elif isinstance(x, list):
            for v in x: walk(v)
        elif isinstance(x, str):
            for m in URL_RE.findall(x): out.add(m.rstrip(".,;"))
    walk(obj)
    return sorted(out)


def host(url):
    h = (urlparse(url).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h


def matches_provider(url, provider):
    h = host(url)
    return any(h == p or h.endswith("." + p) for p in PROVIDERS[provider])


def request(url, accept="text/html,application/xhtml+xml,application/json,application/xml,text/xml;q=0.9,*/*;q=0.8", timeout=35):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        ctype = resp.headers.get("Content-Type", "")
        final_url = resp.geturl()
        return raw, ctype, final_url, resp.status


def title_similarity(a, b):
    a = re.sub(r"[^a-z0-9]+", " ", clean(a).lower()).strip()
    b = re.sub(r"[^a-z0-9]+", " ", clean(b).lower()).strip()
    return round(SequenceMatcher(None, a, b).ratio(), 4) if a and b else None


def valid_abstract(text):
    text = clean(text)
    if not (MIN_ABSTRACT_CHARS <= len(text) <= MAX_ABSTRACT_CHARS): return False
    bad = ["cookie policy", "javascript is disabled", "access denied", "sign in to", "subscribe to"]
    low = text.lower()
    return not any(x in low for x in bad)


def html_meta(raw):
    text = raw.decode("utf-8", errors="replace")
    metas = {}
    for tag in re.findall(r"<meta\b[^>]*>", text, re.I):
        attrs = {k.lower(): html.unescape(v) for k, _, v in re.findall(r"([\w:-]+)\s*=\s*([\"'])(.*?)\2", tag, re.I | re.S)}
        key = (attrs.get("name") or attrs.get("property") or "").lower().strip()
        val = attrs.get("content")
        if key and val and key not in metas:
            metas[key] = clean(val)
    page_title = metas.get("citation_title") or metas.get("dc.title") or metas.get("og:title")
    page_doi = norm_doi(metas.get("citation_doi") or metas.get("dc.identifier") or "")
    candidates = []
    for key in ["citation_abstract", "dc.description", "dcterms.abstract", "dcterms.description", "description", "og:description"]:
        if valid_abstract(metas.get(key)):
            candidates.append((key, metas[key]))
    # JSON-LD description as a fallback.
    if not candidates:
        for block in re.findall(r"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>", text, re.I | re.S):
            try:
                obj = json.loads(html.unescape(block))
            except Exception:
                continue
            objs = obj if isinstance(obj, list) else [obj]
            for x in objs:
                if isinstance(x, dict) and valid_abstract(x.get("description")):
                    candidates.append(("jsonld.description", clean(x["description"])))
                    page_title = page_title or clean(x.get("headline") or x.get("name"))
                    page_doi = page_doi or norm_doi(x.get("doi") or x.get("identifier"))
    return page_title, page_doi, max(candidates, key=lambda x: len(x[1])) if candidates else (None, None)


def europepmc_by_doi(doi):
    if not doi: return None
    q = urllib.parse.urlencode({"query": f'EXT_ID:{doi} OR DOI:{doi}', "format": "json", "pageSize": 5})
    raw, _, final, status = request("https://www.ebi.ac.uk/europepmc/webservices/rest/search?" + q, "application/json")
    data = json.loads(raw.decode("utf-8"))
    for item in ((data.get("resultList") or {}).get("result") or []):
        item_doi = norm_doi(item.get("doi"))
        if item_doi == doi and valid_abstract(item.get("abstractText")):
            return {"abstract": clean(item["abstractText"]), "source_url": final, "method": "europepmc_api", "source_title": clean(item.get("title")), "source_doi": item_doi, "http_status": status}
    return None


def ncbi_by_doi(doi):
    if not doi: return None
    term = urllib.parse.quote(f'{doi}[AID]')
    raw, _, _, _ = request(f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&retmode=json&term={term}", "application/json")
    ids = ((json.loads(raw.decode("utf-8")).get("esearchresult") or {}).get("idlist") or [])
    if not ids: return None
    pmid = ids[0]
    raw, _, final, status = request(f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id={pmid}&retmode=xml", "application/xml")
    root = ET.fromstring(raw)
    article = root.find(".//PubmedArticle")
    if article is None: return None
    title = clean(" ".join(article.find(".//ArticleTitle").itertext())) if article.find(".//ArticleTitle") is not None else ""
    parts = []
    for node in article.findall(".//Abstract/AbstractText"):
        txt = clean(" ".join(node.itertext()))
        label = clean(node.attrib.get("Label"))
        parts.append((label + ": " if label else "") + txt)
    abstract = clean(" ".join(parts))
    if not valid_abstract(abstract): return None
    return {"abstract": abstract, "source_url": final, "method": "pubmed_eutils", "source_title": title, "source_doi": doi, "http_status": status}


def doaj_by_doi(doi):
    if not doi: return None
    query = urllib.parse.quote(f'bibjson.identifier.id:"{doi}"')
    try:
        raw, _, final, status = request("https://doaj.org/api/search/articles/" + query + "?pageSize=5", "application/json")
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        return None
    for item in data.get("results", []):
        bib = item.get("bibjson") or {}
        abs_ = clean(bib.get("abstract"))
        ids = bib.get("identifier") or []
        dois = {norm_doi(x.get("id")) for x in ids if isinstance(x, dict) and str(x.get("type", "")).lower() == "doi"}
        if doi in dois and valid_abstract(abs_):
            return {"abstract": abs_, "source_url": final, "method": "doaj_api", "source_title": clean(bib.get("title")), "source_doi": doi, "http_status": status}
    return None


def html_route(url):
    raw, ctype, final, status = request(url)
    if "html" not in ctype.lower() and not raw.lstrip().lower().startswith((b"<!doctype html", b"<html")):
        return None
    ptitle, pdoi, (method, abstract) = html_meta(raw)
    if not abstract: return None
    return {"abstract": abstract, "source_url": final, "method": "html_meta:" + method, "source_title": ptitle, "source_doi": pdoi, "http_status": status}


def recover(record, provider, urls):
    doi = doi_of(record)
    title = title_of(record)
    attempts = []
    # Structured APIs first.
    funcs = []
    if provider == "europepmc": funcs = [europepmc_by_doi]
    elif provider == "ncbi": funcs = [ncbi_by_doi]
    elif provider == "doaj": funcs = [doaj_by_doi]
    for fn in funcs:
        try:
            hit = fn(doi)
            attempts.append({"route": fn.__name__, "ok": bool(hit)})
            if hit:
                sim = title_similarity(title, hit.get("source_title"))
                doi_ok = bool(doi and hit.get("source_doi") == doi)
                hit.update(title_similarity=sim, doi_exact=doi_ok, attempts=attempts)
                hit["identity_valid"] = doi_ok and (sim is None or sim >= 0.65)
                return hit
        except Exception as exc:
            attempts.append({"route": fn.__name__, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
    # Stored provider URLs next.
    for url in urls:
        try:
            hit = html_route(url)
            attempts.append({"route": "html", "url": url, "ok": bool(hit)})
            if not hit: continue
            sim = title_similarity(title, hit.get("source_title"))
            source_doi = hit.get("source_doi")
            doi_ok = bool(doi and source_doi and source_doi == doi)
            title_ok = sim is not None and sim >= 0.82
            hit.update(title_similarity=sim, doi_exact=doi_ok, attempts=attempts)
            hit["identity_valid"] = doi_ok or title_ok
            return hit
        except Exception as exc:
            attempts.append({"route": "html", "url": url, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
    return {"attempts": attempts, "identity_valid": False}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True)
    ap.add_argument("--provider", required=True, choices=sorted(PROVIDERS))
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()
    outdir = Path(args.outdir); outdir.mkdir(parents=True, exist_ok=True)

    selected = []
    with open(args.records, encoding="utf-8") as h:
        for line in h:
            if not line.strip(): continue
            r = json.loads(line)
            if abstract_of(r): continue
            urls = [u for u in all_urls(r) if matches_provider(u, args.provider)]
            if not urls: continue
            selected.append((r, urls))
            if len(selected) >= args.limit: break

    rows = []
    for i, (r, urls) in enumerate(selected, 1):
        hit = recover(r, args.provider, urls)
        row = {
            "provider": args.provider,
            "sample_index": i,
            "record_id": record_id(r),
            "canonical_title": title_of(r),
            "canonical_doi": doi_of(r),
            "stored_provider_urls": urls,
            "recovered": bool(hit.get("abstract")),
            "identity_valid": bool(hit.get("identity_valid")),
            "method": hit.get("method"),
            "source_url": hit.get("source_url"),
            "source_title": hit.get("source_title"),
            "source_doi": hit.get("source_doi"),
            "title_similarity": hit.get("title_similarity"),
            "doi_exact": hit.get("doi_exact"),
            "abstract": hit.get("abstract"),
            "attempts": hit.get("attempts", []),
            "canonical_mutated": False,
        }
        rows.append(row)
        time.sleep(0.35)

    recovered = sum(bool(r["recovered"]) for r in rows)
    validated = sum(bool(r["recovered"] and r["identity_valid"]) for r in rows)
    report = {
        "provider": args.provider,
        "requested_sample_size": args.limit,
        "selected_record_count": len(rows),
        "recovered_candidate_count": recovered,
        "identity_valid_candidate_count": validated,
        "canonical_mutated": False,
    }
    (outdir / "results.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    (outdir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
