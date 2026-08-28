#!/usr/bin/env python3
"""Test generic abstract extraction from Lens-provided source URLs.

Targets only DOI-bearing records that Europe PMC could not match. The scraper
never invents URLs, never overwrites an existing Lens abstract, and records the
source URL, final URL, extraction method, identity checks, and structured
sections where detectable.
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
MAX_BYTES = 5_000_000
MIN_ABSTRACT_CHARS = 80
MAX_ABSTRACT_CHARS = 12_000


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(record):
    return record.get("lens", {}).get("raw_payload", {}) if isinstance(record.get("lens"), dict) else {}


def lens_id(record):
    return str(record.get("identity", {}).get("lens_id") or payload(record).get("lens_id") or "")


def normalise_doi(value):
    if not value:
        return None
    s = str(value).strip().lower()
    for prefix in ("https://doi.org/", "http://doi.org/", "http://dx.doi.org/", "doi:"):
        if s.startswith(prefix):
            s = s[len(prefix):].strip()
    return s or None


def doi(record):
    for item in payload(record).get("external_ids") or []:
        if isinstance(item, dict) and str(item.get("type", "")).lower() == "doi" and item.get("value"):
            return normalise_doi(item.get("value"))
    return None


def clean_text(value):
    if value is None:
        return None
    text = re.sub(r"\s+", " ", str(value)).strip()
    text = re.sub(r"^abstract\s*[:.-]?\s*", "", text, flags=re.I)
    return text[:MAX_ABSTRACT_CHARS] if text else None


def normalise_title(value):
    if not value:
        return ""
    return re.sub(r"[^a-z0-9]+", " ", str(value).lower()).strip()


def title_similarity(a, b):
    a, b = normalise_title(a), normalise_title(b)
    if not a or not b:
        return None
    return round(SequenceMatcher(None, a, b).ratio(), 4)


def add_url(candidate, out):
    if isinstance(candidate, str):
        candidate = candidate.strip()
        if candidate.startswith(("http://", "https://")) and candidate not in out:
            out.append(candidate)
    elif isinstance(candidate, dict):
        for key in ("url", "source_url", "link", "value", "href"):
            if candidate.get(key):
                add_url(candidate.get(key), out)
        for value in candidate.values():
            if isinstance(value, (list, dict)):
                add_url(value, out)
    elif isinstance(candidate, list):
        for value in candidate:
            add_url(value, out)


def source_urls(record):
    p = payload(record)
    out = []
    # Only inspect URL-bearing fields already supplied by Lens.
    for key in ("source_urls", "urls", "url", "links"):
        if key in p:
            add_url(p.get(key), out)
    return out


def fetch_html(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        ctype = str(resp.headers.get("Content-Type") or "")
        final_url = resp.geturl()
        status = getattr(resp, "status", None)
        data = resp.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("response_too_large")
    if "html" not in ctype.lower() and not data.lstrip().startswith(b"<"):
        raise ValueError("not_html")
    return data.decode("utf-8", errors="replace"), final_url, status, ctype


def meta_content(soup, names):
    wanted = {n.lower() for n in names}
    for tag in soup.find_all("meta"):
        key = str(tag.get("name") or tag.get("property") or "").strip().lower()
        if key in wanted and tag.get("content"):
            value = clean_text(tag.get("content"))
            if value:
                return value, key
    return None, None


def page_identity(soup):
    page_doi, doi_key = meta_content(
        soup,
        ["citation_doi", "dc.identifier", "dc.identifier.doi", "prism.doi", "doi"],
    )
    page_title, title_key = meta_content(
        soup,
        ["citation_title", "dc.title", "dcterms.title", "og:title", "twitter:title"],
    )
    if not page_title and soup.title:
        page_title = clean_text(soup.title.get_text(" ", strip=True))
        title_key = "html_title"
    return normalise_doi(page_doi), doi_key, page_title, title_key


def structured_from_container(container):
    sections = []
    current_label = None
    current_parts = []

    def flush():
        nonlocal current_label, current_parts
        text = clean_text(" ".join(current_parts))
        if text and len(text) >= 20:
            sections.append({"label": current_label, "text": text})
        current_label, current_parts = None, []

    for node in container.find_all(["h2", "h3", "h4", "h5", "strong", "b", "p", "div", "li"], recursive=True):
        text = clean_text(node.get_text(" ", strip=True))
        if not text or text.lower() == "abstract":
            continue
        name = node.name.lower()
        looks_label = name in {"h2", "h3", "h4", "h5"} or (
            name in {"strong", "b"} and len(text) <= 80 and len(text.split()) <= 10
        )
        if looks_label:
            if current_parts:
                flush()
            current_label = text.rstrip(":")
        elif name in {"p", "li"}:
            current_parts.append(text)
    if current_parts:
        flush()

    # De-duplicate nested-container repeats.
    deduped = []
    seen = set()
    for item in sections:
        key = (item.get("label") or "", item["text"])
        if key not in seen:
            seen.add(key)
            deduped.append(item)
    return deduped


def abstract_from_jsonld(soup):
    for script in soup.find_all("script", attrs={"type": re.compile(r"ld\+json", re.I)}):
        try:
            data = json.loads(script.string or script.get_text() or "")
        except Exception:
            continue
        stack = data if isinstance(data, list) else [data]
        for item in stack:
            if not isinstance(item, dict):
                continue
            for key in ("abstract", "description"):
                value = clean_text(item.get(key))
                if value and len(value) >= MIN_ABSTRACT_CHARS:
                    return value, f"jsonld:{key}"
    return None, None


def abstract_from_dom(soup):
    selectors = [
        "section.abstract", "div.abstract", "article .abstract", "[id*='abstract' i]",
        "[class*='abstract' i]", "section[aria-labelledby*='abstract' i]",
    ]
    candidates = []
    for selector in selectors:
        try:
            candidates.extend(soup.select(selector))
        except Exception:
            continue

    # Also support an Abstract heading followed by paragraphs/structured blocks.
    for heading in soup.find_all(re.compile(r"^h[1-6]$")):
        if clean_text(heading.get_text(" ", strip=True) or "").lower() == "abstract":
            parent = heading.parent
            if parent is not None:
                candidates.append(parent)
            block = []
            for sib in heading.find_all_next(limit=30):
                if sib is heading:
                    continue
                if sib.name and re.match(r"^h[1-6]$", sib.name, re.I):
                    break
                if sib.name in {"p", "div", "li"}:
                    t = clean_text(sib.get_text(" ", strip=True))
                    if t:
                        block.append(t)
            if block:
                joined = clean_text(" ".join(block))
                if joined and len(joined) >= MIN_ABSTRACT_CHARS:
                    return joined, [], "heading_following"

    best = None
    for container in candidates:
        text = clean_text(container.get_text(" ", strip=True))
        if not text:
            continue
        text = re.sub(r"^abstract\s*", "", text, flags=re.I).strip()
        if len(text) < MIN_ABSTRACT_CHARS or len(text) > MAX_ABSTRACT_CHARS:
            continue
        sections = structured_from_container(container)
        score = len(text)
        if best is None or score > best[0]:
            best = (score, text, sections)
    if best:
        _, text, sections = best
        return text, sections, "dom_abstract_container"
    return None, [], None


def extract_abstract(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        if tag.name != "script" or str(tag.get("type") or "").lower() != "application/ld+json":
            tag.decompose()

    meta, meta_key = meta_content(
        soup,
        [
            "citation_abstract", "dc.description", "dcterms.description",
            "eprints.abstract", "prism.teaser", "bepress_citation_abstract",
        ],
    )
    if meta and len(meta) >= MIN_ABSTRACT_CHARS:
        return meta, [], f"meta:{meta_key}", soup

    jsonld, jsonld_key = abstract_from_jsonld(soup)
    if jsonld:
        return jsonld, [], jsonld_key, soup

    text, sections, method = abstract_from_dom(soup)
    return text, sections, method, soup


def identity_ok(target_doi, target_title, soup):
    page_doi, doi_key, page_title, title_key = page_identity(soup)
    doi_match = None if not page_doi else page_doi == target_doi
    title_sim = title_similarity(target_title, page_title)

    if doi_match is False:
        return False, {"page_doi": page_doi, "doi_meta_key": doi_key, "doi_match": False,
                       "page_title": page_title, "title_meta_key": title_key, "title_similarity": title_sim}
    if doi_match is None and title_sim is not None and title_sim < 0.72:
        return False, {"page_doi": page_doi, "doi_meta_key": doi_key, "doi_match": None,
                       "page_title": page_title, "title_meta_key": title_key, "title_similarity": title_sim}
    return True, {"page_doi": page_doi, "doi_meta_key": doi_key, "doi_match": doi_match,
                  "page_title": page_title, "title_meta_key": title_key, "title_similarity": title_sim}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True, help="Workflow 04 200-record JSONL")
    ap.add_argument("--europepmc-results", required=True, help="Europe PMC result JSONL")
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--delay", type=float, default=0.5)
    args = ap.parse_args()

    records = [json.loads(x) for x in Path(args.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    by_id = {lens_id(r): r for r in records}
    epmc = [json.loads(x) for x in Path(args.europepmc_results).read_text(encoding="utf-8").splitlines() if x.strip()]
    targets = [x for x in epmc if x.get("status") == "no_exact_match" and x.get("doi")]

    results = []
    for target in targets:
        lid = str(target.get("lens_id") or "")
        record = by_id.get(lid)
        d = normalise_doi(target.get("doi"))
        p = payload(record or {})
        title = p.get("title")
        urls = source_urls(record or {})
        item = {
            "lens_id": lid,
            "doi": d,
            "title": title,
            "lens_source_urls": urls,
            "status": None,
            "abstract": None,
            "abstract_sections": [],
            "recovered_from_url": None,
            "extraction_method": None,
            "attempts": [],
            "retrieved_at": now(),
        }

        if not record:
            item["status"] = "record_not_found"
            results.append(item)
            continue
        if not urls:
            item["status"] = "no_lens_source_urls"
            results.append(item)
            continue

        for url in urls:
            attempt = {"source_url": url}
            try:
                html, final_url, status, ctype = fetch_html(url)
                attempt.update({"final_url": final_url, "http_status": status, "content_type": ctype})
                abstract, sections, method, soup = extract_abstract(html)
                ok, identity = identity_ok(d, title, soup)
                attempt["identity"] = identity
                attempt["extraction_method"] = method
                attempt["abstract_chars"] = len(abstract or "")
                if not ok:
                    attempt["outcome"] = "identity_mismatch"
                elif abstract and len(abstract) >= MIN_ABSTRACT_CHARS:
                    attempt["outcome"] = "abstract_recovered"
                    item["status"] = "abstract_recovered"
                    item["abstract"] = abstract
                    item["abstract_sections"] = sections
                    item["recovered_from_url"] = final_url
                    item["source_url"] = url
                    item["extraction_method"] = method
                    item["identity"] = identity
                    item["attempts"].append(attempt)
                    break
                else:
                    attempt["outcome"] = "no_abstract_detected"
            except urllib.error.HTTPError as e:
                attempt.update({"outcome": "http_error", "error": f"HTTPError:{e.code}"})
            except urllib.error.URLError as e:
                attempt.update({"outcome": "url_error", "error": f"URLError:{e.reason}"})
            except Exception as e:
                attempt.update({"outcome": "technical_error", "error": f"{type(e).__name__}:{e}"})
            item["attempts"].append(attempt)
            time.sleep(args.delay)

        if item["status"] is None:
            outcomes = [a.get("outcome") for a in item["attempts"]]
            if outcomes and all(x in {"http_error", "url_error"} for x in outcomes):
                item["status"] = "all_urls_inaccessible"
            elif "identity_mismatch" in outcomes and not any(x == "no_abstract_detected" for x in outcomes):
                item["status"] = "identity_mismatch"
            else:
                item["status"] = "no_abstract_recovered"
        results.append(item)

    Path(args.output).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in results), encoding="utf-8")
    counts = {}
    methods = {}
    for x in results:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
        if x.get("extraction_method"):
            methods[x["extraction_method"]] = methods.get(x["extraction_method"], 0) + 1
    report = {
        "created_at": now(),
        "target_policy": "Only the DOI-bearing Europe PMC no_exact_match records; only Lens-provided source URLs; no generated URLs; no access-control bypass.",
        "target_count": len(targets),
        "status_counts": counts,
        "recovered": sum(x["status"] == "abstract_recovered" for x in results),
        "structured_recovered": sum(bool(x.get("abstract_sections")) for x in results if x["status"] == "abstract_recovered"),
        "extraction_methods": methods,
        "records": results,
    }
    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("target_count", "status_counts", "recovered", "structured_recovered", "extraction_methods")}, indent=2))


if __name__ == "__main__":
    main()
