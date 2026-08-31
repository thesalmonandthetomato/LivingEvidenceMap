#!/usr/bin/env python3
"""Recover missing abstracts using Google Scholar title search as discovery.

The tool never overwrites an existing abstract. It searches Google Scholar by
quoted title, validates candidate titles, follows result links, extracts an
abstract from public HTML metadata/JSON-LD/DOM, and writes a separate repair
ledger. It does not bypass CAPTCHAs, rate limits, robots controls, paywalls or
access controls. On a Scholar block (429/403/CAPTCHA) it stops cleanly.

Intended use:
  python scripts/updater/repair_missing_abstracts_google_scholar.py \
    --records data/canonical/current/repair/records.jsonl \
    --output abstract_repairs.jsonl --report abstract_repairs_report.json \
    --max-records 50

The output is auditable and does not mutate the canonical JSONL. Apply accepted
repairs in a separate reviewed step.
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

UA = "LivingEvidenceMap abstract-repair (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"
MIN_ABSTRACT_CHARS = 80
MAX_ABSTRACT_CHARS = 12000
MAX_BYTES = 5_000_000
SCHOLAR_URL = "https://scholar.google.com/scholar?hl=en&q="


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(r):
    return r.get("lens", {}).get("raw_payload", {}) if isinstance(r.get("lens"), dict) else {}


def canonical(r):
    return r.get("canonical", {}) if isinstance(r.get("canonical"), dict) else {}


def lens_id(r):
    return str(r.get("identity", {}).get("lens_id") or payload(r).get("lens_id") or "")


def first(*vals):
    for v in vals:
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def title(r):
    return first(canonical(r).get("title"), payload(r).get("title"))


def existing_abstract(r):
    return first(canonical(r).get("abstract"), payload(r).get("abstract"))


def clean(v):
    if v is None:
        return None
    s = re.sub(r"\s+", " ", str(v)).strip()
    s = re.sub(r"^abstract\s*[:.\-]?\s*", "", s, flags=re.I)
    return s[:MAX_ABSTRACT_CHARS] if s else None


def norm_title(v):
    return re.sub(r"[^a-z0-9]+", " ", str(v or "").lower()).strip()


def similarity(a, b):
    a, b = norm_title(a), norm_title(b)
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


def fetch_html(url, timeout=30):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read(MAX_BYTES + 1)
        ctype = str(resp.headers.get("Content-Type") or "")
        final_url = resp.geturl()
        status = getattr(resp, "status", None)
    if len(data) > MAX_BYTES:
        raise ValueError("response_too_large")
    if "html" not in ctype.lower() and not data.lstrip().startswith(b"<"):
        raise ValueError("not_html")
    return data.decode("utf-8", errors="replace"), final_url, status, ctype


def scholar_blocked(html):
    t = html.lower()
    return any(x in t for x in (
        "unusual traffic from your computer network",
        "not a robot",
        "recaptcha",
        "/sorry/",
    ))


def scholar_candidates(target_title, html, max_results=5):
    soup = BeautifulSoup(html, "html.parser")
    out = []
    for block in soup.select("div.gs_ri"):
        h3 = block.select_one("h3.gs_rt")
        if not h3:
            continue
        a = h3.find("a")
        result_title = clean(h3.get_text(" ", strip=True))
        if result_title:
            result_title = re.sub(r"^\[[^\]]+\]\s*", "", result_title)
        url = a.get("href") if a else None
        sim = round(similarity(target_title, result_title), 4)
        if url and url.startswith(("http://", "https://")):
            out.append({"title": result_title, "url": url, "title_similarity": sim})
        if len(out) >= max_results:
            break
    return out


def meta(soup, names):
    wanted = {x.lower() for x in names}
    for tag in soup.find_all("meta"):
        key = str(tag.get("name") or tag.get("property") or "").strip().lower()
        if key in wanted:
            val = clean(tag.get("content"))
            if val:
                return val, key
    return None, None


def page_title(soup):
    v, _ = meta(soup, ["citation_title", "dc.title", "dcterms.title", "og:title", "twitter:title"])
    if v:
        return v
    return clean(soup.title.get_text(" ", strip=True)) if soup.title else None


def extract_abstract(html):
    soup = BeautifulSoup(html, "html.parser")
    v, k = meta(soup, [
        "citation_abstract", "dc.description", "dcterms.description",
        "eprints.abstract", "bepress_citation_abstract", "prism.teaser",
    ])
    if v and len(v) >= MIN_ABSTRACT_CHARS:
        return v, f"meta:{k}", soup

    for script in soup.find_all("script"):
        if "ld+json" not in str(script.get("type") or "").lower():
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
                if v and len(v) >= MIN_ABSTRACT_CHARS:
                    return v, f"jsonld:{key}", soup

    candidates = []
    for selector in ("section.abstract", "div.abstract", "article .abstract", "[id*='abstract' i]", "[class*='abstract' i]"):
        try:
            candidates.extend(soup.select(selector))
        except Exception:
            pass
    best = None
    for node in candidates:
        text = clean(node.get_text(" ", strip=True))
        if not text:
            continue
        text = re.sub(r"^abstract\s*", "", text, flags=re.I).strip()
        if MIN_ABSTRACT_CHARS <= len(text) <= MAX_ABSTRACT_CHARS:
            if best is None or len(text) > len(best):
                best = text
    return (best, "dom_abstract_container", soup) if best else (None, None, soup)


def attempt_record(record, delay, min_title_similarity, max_results):
    lid = lens_id(record)
    target_title = title(record)
    item = {
        "lens_id": lid,
        "title": target_title,
        "status": None,
        "abstract": None,
        "source_url": None,
        "scholar_search_url": None,
        "extraction_method": None,
        "attempts": [],
        "retrieved_at": now(),
    }
    if existing_abstract(record):
        item["status"] = "already_has_abstract"
        return item, False
    if not target_title:
        item["status"] = "missing_title"
        return item, False

    query = '"' + target_title.replace('"', '') + '"'
    search_url = SCHOLAR_URL + urllib.parse.quote(query)
    item["scholar_search_url"] = search_url
    try:
        html, final_url, status, ctype = fetch_html(search_url)
        item["attempts"].append({"method": "google_scholar_title_search", "url": search_url,
                                 "final_url": final_url, "http_status": status, "content_type": ctype})
    except urllib.error.HTTPError as e:
        item["status"] = "scholar_blocked" if e.code in (403, 429) else "scholar_http_error"
        item["attempts"].append({"method": "google_scholar_title_search", "url": search_url,
                                 "error": f"HTTPError:{e.code}"})
        return item, e.code in (403, 429)
    except Exception as e:
        item["status"] = "scholar_error"
        item["attempts"].append({"method": "google_scholar_title_search", "url": search_url,
                                 "error": f"{type(e).__name__}:{e}"})
        return item, False

    if scholar_blocked(html):
        item["status"] = "scholar_blocked"
        return item, True

    candidates = scholar_candidates(target_title, html, max_results=max_results)
    if not candidates:
        item["status"] = "no_scholar_result"
        return item, False

    for candidate in candidates:
        att = {"method": "scholar_result_landing_page", **candidate}
        if candidate["title_similarity"] < min_title_similarity:
            att["outcome"] = "scholar_title_mismatch"
            item["attempts"].append(att)
            continue
        try:
            page, final_url, status, ctype = fetch_html(candidate["url"])
            abstract, method, soup = extract_abstract(page)
            ptitle = page_title(soup)
            psim = round(similarity(target_title, ptitle), 4) if ptitle else None
            att.update({"final_url": final_url, "http_status": status, "content_type": ctype,
                        "page_title": ptitle, "page_title_similarity": psim,
                        "extraction_method": method, "abstract_chars": len(abstract or "")})
            if ptitle and psim is not None and psim < min_title_similarity:
                att["outcome"] = "landing_page_title_mismatch"
            elif abstract:
                att["outcome"] = "abstract_recovered"
                item.update({"status": "abstract_recovered", "abstract": abstract,
                             "source_url": final_url, "extraction_method": method,
                             "matched_title": ptitle or candidate["title"],
                             "title_similarity": psim if psim is not None else candidate["title_similarity"]})
                item["attempts"].append(att)
                return item, False
            else:
                att["outcome"] = "no_abstract_detected"
        except urllib.error.HTTPError as e:
            att.update({"outcome": "http_error", "error": f"HTTPError:{e.code}"})
        except Exception as e:
            att.update({"outcome": "technical_error", "error": f"{type(e).__name__}:{e}"})
        item["attempts"].append(att)
        time.sleep(delay)

    item["status"] = "no_abstract_recovered"
    return item, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--delay", type=float, default=8.0,
                    help="Seconds between requests; keep this conservative for Scholar")
    ap.add_argument("--max-records", type=int, default=50,
                    help="Maximum missing-abstract records to attempt in one run")
    ap.add_argument("--min-title-similarity", type=float, default=0.88)
    ap.add_argument("--max-scholar-results", type=int, default=5)
    args = ap.parse_args()

    records = [json.loads(x) for x in Path(args.records).read_text(encoding="utf-8").splitlines() if x.strip()]
    targets = [r for r in records if not existing_abstract(r)][:args.max_records]
    results = []
    stopped_for_block = False

    for i, record in enumerate(targets):
        item, blocked = attempt_record(record, args.delay, args.min_title_similarity, args.max_scholar_results)
        results.append(item)
        if blocked:
            stopped_for_block = True
            break
        if i < len(targets) - 1:
            time.sleep(args.delay)

    Path(args.output).write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in results), encoding="utf-8")
    counts = {}
    for x in results:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    report = {
        "created_at": now(),
        "input_record_count": len(records),
        "missing_abstract_count": sum(not existing_abstract(r) for r in records),
        "attempted_count": len(results),
        "recovered_count": sum(x["status"] == "abstract_recovered" for x in results),
        "status_counts": counts,
        "stopped_for_scholar_block": stopped_for_block,
        "policy": "No CAPTCHA/rate-limit/paywall/access-control bypass; canonical store not mutated.",
    }
    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
