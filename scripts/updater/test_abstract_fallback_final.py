#!/usr/bin/env python3
"""Final bounded abstract-recovery test for the 12 Europe PMC DOI misses.

Order:
1. Lens-provided source URLs only, using generic HTML/meta/JSON-LD extraction.
2. Exact-DOI Crossref metadata fallback when Lens URLs are blocked or unhelpful.

No access-control bypass, no title search, no generated publisher URLs, and no
overwrite of existing Lens abstracts. Full provenance is retained per attempt.
"""
from __future__ import annotations

import argparse
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

from bs4 import BeautifulSoup

UA = "LivingEvidenceMap abstract-enrichment test (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
MIN_CHARS = 80
MAX_CHARS = 12000
MAX_BYTES = 5_000_000


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(r):
    return r.get("lens", {}).get("raw_payload", {}) if isinstance(r.get("lens"), dict) else {}


def lens_id(r):
    return str(r.get("identity", {}).get("lens_id") or payload(r).get("lens_id") or "")


def clean(v):
    if v is None:
        return None
    s = re.sub(r"\s+", " ", str(v)).strip()
    s = re.sub(r"^abstract\s*[:.-]?\s*", "", s, flags=re.I)
    return s[:MAX_CHARS] if s else None


def norm_doi(v):
    if not v:
        return None
    s = str(v).strip().lower()
    for p in ("https://doi.org/", "http://doi.org/", "http://dx.doi.org/", "doi:"):
        if s.startswith(p):
            s = s[len(p):].strip()
    return s or None


def norm_title(v):
    return re.sub(r"[^a-z0-9]+", " ", str(v or "").lower()).strip()


def title_sim(a, b):
    a, b = norm_title(a), norm_title(b)
    if not a or not b:
        return None
    return round(SequenceMatcher(None, a, b).ratio(), 4)


def add_url(v, out):
    if isinstance(v, str):
        v = v.strip()
        if v.startswith(("http://", "https://")) and v not in out:
            out.append(v)
    elif isinstance(v, list):
        for x in v:
            add_url(x, out)
    elif isinstance(v, dict):
        for k in ("url", "source_url", "link", "value", "href"):
            if v.get(k):
                add_url(v.get(k), out)
        for x in v.values():
            if isinstance(x, (dict, list)):
                add_url(x, out)


def source_urls(r):
    p = payload(r)
    out = []
    for k in ("source_urls", "urls", "url", "links"):
        if k in p:
            add_url(p.get(k), out)
    return out


def meta(soup, keys):
    wanted = {k.lower() for k in keys}
    for tag in soup.find_all("meta"):
        key = str(tag.get("name") or tag.get("property") or "").strip().lower()
        if key in wanted:
            val = clean(tag.get("content"))
            if val:
                return val, key
    return None, None


def fetch_html(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        ctype = str(resp.headers.get("Content-Type") or "")
        data = resp.read(MAX_BYTES + 1)
        final_url = resp.geturl()
        status = getattr(resp, "status", None)
    if len(data) > MAX_BYTES:
        raise ValueError("response_too_large")
    if "html" not in ctype.lower() and not data.lstrip().startswith(b"<"):
        raise ValueError("not_html")
    return data.decode("utf-8", errors="replace"), final_url, status, ctype


def identity(soup, target_doi, target_title):
    pd, dk = meta(soup, ["citation_doi", "dc.identifier.doi", "prism.doi", "doi"])
    pt, tk = meta(soup, ["citation_title", "dc.title", "dcterms.title", "og:title", "twitter:title"])
    if not pt and soup.title:
        pt = clean(soup.title.get_text(" ", strip=True))
        tk = "html_title"
    nd = norm_doi(pd)
    dm = None if not nd else nd == target_doi
    ts = title_sim(target_title, pt)
    ok = dm is not False and not (dm is None and ts is not None and ts < 0.72)
    return ok, {"page_doi": nd, "doi_meta_key": dk, "doi_match": dm, "page_title": pt, "title_meta_key": tk, "title_similarity": ts}


def structured_sections(container):
    out = []
    for node in container.find_all(["h2", "h3", "h4", "h5", "strong", "b"], recursive=True):
        label = clean(node.get_text(" ", strip=True))
        if not label or label.lower() == "abstract" or len(label) > 100:
            continue
        parts = []
        for sib in node.next_siblings:
            name = getattr(sib, "name", None)
            if name and str(name).lower() in {"h2", "h3", "h4", "h5", "strong", "b"}:
                break
            if hasattr(sib, "get_text"):
                t = clean(sib.get_text(" ", strip=True))
                if t:
                    parts.append(t)
        text = clean(" ".join(parts))
        if text and len(text) >= 20:
            out.append({"label": label.rstrip(":"), "text": text})
    return out


def extract_html_abstract(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in list(soup.find_all(["style", "noscript"])):
        tag.decompose()

    v, k = meta(soup, ["citation_abstract", "dc.description", "dcterms.description", "eprints.abstract", "bepress_citation_abstract", "prism.teaser"])
    if v and len(v) >= MIN_CHARS:
        return v, [], f"meta:{k}", soup

    for script in soup.find_all("script"):
        typ = str(script.get("type") or "").lower()
        if "ld+json" not in typ:
            continue
        try:
            data = json.loads(script.string or script.get_text() or "")
        except Exception:
            continue
        stack = data if isinstance(data, list) else [data]
        for obj in stack:
            if not isinstance(obj, dict):
                continue
            for key in ("abstract", "description"):
                v = clean(obj.get(key))
                if v and len(v) >= MIN_CHARS:
                    return v, [], f"jsonld:{key}", soup

    candidates = []
    for sel in ("section.abstract", "div.abstract", "article .abstract", "[id*='abstract' i]", "[class*='abstract' i]"):
        try:
            candidates.extend(soup.select(sel))
        except Exception:
            pass
    for h in soup.find_all(re.compile(r"^h[1-6]$")):
        ht = clean(h.get_text(" ", strip=True))
        if ht and ht.lower() == "abstract" and h.parent is not None:
            candidates.append(h.parent)

    best = None
    for c in candidates:
        t = clean(c.get_text(" ", strip=True))
        if not t:
            continue
        t = re.sub(r"^abstract\s*", "", t, flags=re.I).strip()
        if MIN_CHARS <= len(t) <= MAX_CHARS:
            sections = structured_sections(c)
            if best is None or len(t) > len(best[0]):
                best = (t, sections)
    if best:
        return best[0], best[1], "dom_abstract_container", soup
    return None, [], None, soup


def crossref_lookup(d):
    url = "https://api.crossref.org/works/" + urllib.parse.quote(d, safe="")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp), resp.geturl(), getattr(resp, "status", None)


def crossref_abstract(data, target_doi, target_title):
    msg = data.get("message") or {}
    rd = norm_doi(msg.get("DOI"))
    titles = msg.get("title") or []
    rt = titles[0] if isinstance(titles, list) and titles else (titles if isinstance(titles, str) else None)
    ts = title_sim(target_title, rt)
    identity_ok = rd == target_doi and not (ts is not None and ts < 0.72)
    raw = msg.get("abstract")
    if not raw:
        return None, [], {"response_doi": rd, "doi_match": rd == target_doi, "response_title": rt, "title_similarity": ts}, None
    soup = BeautifulSoup(str(raw), "html.parser")
    sections = []
    for node in soup.find_all(["jats:title", "title", "h2", "h3", "h4", "strong", "b"]):
        label = clean(node.get_text(" ", strip=True))
        parent = node.parent
        if label and parent:
            body = clean(parent.get_text(" ", strip=True))
            if body and body.lower() != label.lower():
                body = re.sub(r"^" + re.escape(label) + r"\s*[:.-]?\s*", "", body, flags=re.I)
                if len(body) >= 20:
                    sections.append({"label": label.rstrip(":"), "text": body})
    text = clean(soup.get_text(" ", strip=True))
    if text:
        text = re.sub(r"^abstract\s*", "", text, flags=re.I).strip()
    if not identity_ok or not text or len(text) < MIN_CHARS:
        text = None
    return text, sections, {"response_doi": rd, "doi_match": rd == target_doi, "response_title": rt, "title_similarity": ts}, "crossref:message.abstract" if text else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True)
    ap.add_argument("--europepmc-results", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--delay", type=float, default=0.4)
    a = ap.parse_args()

    records = [json.loads(x) for x in Path(a.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    by_id = {lens_id(r): r for r in records}
    epmc = [json.loads(x) for x in Path(a.europepmc_results).read_text(encoding="utf-8").splitlines() if x.strip()]
    targets = [x for x in epmc if x.get("status") == "no_exact_match" and x.get("doi")]

    out = []
    for t in targets:
        lid = str(t.get("lens_id") or "")
        d = norm_doi(t.get("doi"))
        r = by_id.get(lid)
        title = payload(r or {}).get("title")
        item = {"lens_id": lid, "doi": d, "title": title, "status": None, "abstract": None, "abstract_sections": [], "source": None, "attempts": [], "retrieved_at": now()}
        if not r:
            item["status"] = "record_not_found"
            out.append(item)
            continue

        for url in source_urls(r):
            att = {"method": "lens_source_url", "source_url": url}
            try:
                html, final_url, status, ctype = fetch_html(url)
                abstract, sections, method, soup = extract_html_abstract(html)
                ok, ident = identity(soup, d, title)
                att.update({"final_url": final_url, "http_status": status, "content_type": ctype, "identity": ident, "extraction_method": method, "abstract_chars": len(abstract or "")})
                if not ok:
                    att["outcome"] = "identity_mismatch"
                elif abstract:
                    att["outcome"] = "abstract_recovered"
                    item.update({"status": "abstract_recovered", "abstract": abstract, "abstract_sections": sections, "source": final_url, "extraction_method": method})
                    item["attempts"].append(att)
                    break
                else:
                    att["outcome"] = "no_abstract_detected"
            except urllib.error.HTTPError as e:
                att.update({"outcome": "http_error", "error": f"HTTPError:{e.code}"})
            except urllib.error.URLError as e:
                att.update({"outcome": "url_error", "error": f"URLError:{e.reason}"})
            except Exception as e:
                att.update({"outcome": "technical_error", "error": f"{type(e).__name__}:{e}"})
            item["attempts"].append(att)
            time.sleep(a.delay)

        if item["status"] != "abstract_recovered":
            att = {"method": "crossref_exact_doi", "doi": d}
            try:
                data, final_url, status = crossref_lookup(d)
                abstract, sections, ident, method = crossref_abstract(data, d, title)
                att.update({"final_url": final_url, "http_status": status, "identity": ident, "extraction_method": method, "abstract_chars": len(abstract or ""), "raw_response": data})
                if abstract:
                    att["outcome"] = "abstract_recovered"
                    item.update({"status": "abstract_recovered", "abstract": abstract, "abstract_sections": sections, "source": final_url, "extraction_method": method})
                else:
                    att["outcome"] = "no_abstract_detected"
            except urllib.error.HTTPError as e:
                att.update({"outcome": "http_error", "error": f"HTTPError:{e.code}"})
            except Exception as e:
                att.update({"outcome": "technical_error", "error": f"{type(e).__name__}:{e}"})
            item["attempts"].append(att)

        if item["status"] is None:
            item["status"] = "no_abstract_recovered"
        out.append(item)

    Path(a.output).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in out), encoding="utf-8")
    counts = {}
    methods = {}
    for x in out:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
        if x.get("extraction_method"):
            methods[x["extraction_method"]] = methods.get(x["extraction_method"], 0) + 1
    report = {"created_at": now(), "target_count": len(out), "status_counts": counts, "recovered": sum(x["status"] == "abstract_recovered" for x in out), "structured_recovered": sum(bool(x.get("abstract_sections")) for x in out if x["status"] == "abstract_recovered"), "extraction_methods": methods, "records": out}
    Path(a.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("target_count", "status_counts", "recovered", "structured_recovered", "extraction_methods")}, indent=2))


if __name__ == "__main__":
    main()
