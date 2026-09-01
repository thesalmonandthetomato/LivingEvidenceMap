#!/usr/bin/env python3
"""Recover missing abstracts from OpenAlex cached GROBID XML/PDF content.

This script never mutates canonical records. It writes:
- a per-record audit JSONL;
- a JSONL patch ledger containing only recovered abstracts;
- a summary report.

Matching is DOI-exact: a canonical DOI is resolved directly to an OpenAlex Work.
GROBID TEI XML is preferred. PDF extraction is used only for works with PDF
content but no GROBID XML.
"""
from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

UA = "LivingEvidenceMap/1.0 (OpenAlex abstract recovery)"
MIN_ABSTRACT_CHARS = 80
MAX_ABSTRACT_CHARS = 12000


def clean(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()


def norm_doi(value):
    value = clean(value).lower()
    value = re.sub(r"^https?://(dx\.)?doi\.org/", "", value)
    value = re.sub(r"^doi:\s*", "", value)
    return value or None


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


def record_id(record):
    return str(getv(record, ("identity", "lens_id"), ("record_id",), ("lens_id",), ("canonical", "lens_id")) or "")


def title_of(record):
    return clean(getv(record, ("canonical", "title"), ("title",), ("raw", "title")))


def abstract_of(record):
    return clean(getv(record, ("canonical", "abstract"), ("abstract",), ("raw", "abstract")))


def doi_of(record):
    value = getv(record, ("canonical", "doi"), ("doi",), ("identifiers", "doi"), ("raw", "doi"))
    if isinstance(value, list):
        value = next((x for x in value if x), None)
    return norm_doi(value)


def request_bytes(url, api_key, accept="*/*", timeout=90):
    separator = "&" if "?" in url else "?"
    url = f"{url}{separator}api_key={urllib.parse.quote(api_key)}"
    request = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(), response.status, dict(response.headers)


def fetch_work_by_doi(doi, api_key):
    url = "https://api.openalex.org/works/https://doi.org/" + urllib.parse.quote(doi, safe="")
    try:
        raw, status, headers = request_bytes(url, api_key, "application/json")
        return status, json.loads(raw.decode("utf-8")), headers
    except urllib.error.HTTPError as exc:
        return exc.code, None, dict(exc.headers)
    except Exception as exc:
        return None, None, {"error": f"{type(exc).__name__}: {exc}"}


def text_from_element(element):
    return clean(" ".join(element.itertext()))


def maybe_decompress_gzip(raw, headers=None):
    headers = headers or {}
    ctype = str(headers.get("Content-Type") or headers.get("content-type") or "").lower()
    cenc = str(headers.get("Content-Encoding") or headers.get("content-encoding") or "").lower()
    if raw[:2] == b"\x1f\x8b" or "gzip" in ctype or cenc == "gzip":
        return gzip.decompress(raw)
    return raw


def extract_tei_abstract(xml_bytes, headers=None):
    xml_bytes = maybe_decompress_gzip(xml_bytes, headers)
    # Fail clearly if OpenAlex returned a non-XML error document/body.
    stripped = xml_bytes.lstrip()
    if not stripped.startswith(b"<"):
        preview = stripped[:80].decode("utf-8", errors="replace")
        raise ValueError(f"OpenAlex GROBID response was not XML: {preview!r}")
    root = ET.fromstring(xml_bytes)
    candidates = []
    for element in root.iter():
        if element.tag.split("}")[-1].lower() == "abstract":
            text = text_from_element(element)
            if MIN_ABSTRACT_CHARS <= len(text) <= MAX_ABSTRACT_CHARS:
                candidates.append(text)
    return max(candidates, key=len) if candidates else None


def extract_pdf_abstract(pdf_bytes):
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(pdf_bytes))
    raw_text = "\n".join((page.extract_text() or "") for page in reader.pages[:6])
    raw_text = raw_text.replace("\r", "\n")
    patterns = [
        r"(?is)(?:^|\n)\s*abstract\s*[:.\-]?\s*(.{80,12000}?)(?=\n\s*(?:keywords?|key\s+words|index\s+terms|introduction|1\.?\s+introduction)\b)",
        r"(?is)(?:^|\n)\s*summary\s*[:.\-]?\s*(.{80,12000}?)(?=\n\s*(?:keywords?|key\s+words|introduction|1\.?\s+introduction)\b)",
    ]
    for pattern in patterns:
        match = re.search(pattern, raw_text)
        if match:
            text = clean(match.group(1))
            if MIN_ABSTRACT_CHARS <= len(text) <= MAX_ABSTRACT_CHARS:
                return text
    return None


def content_url(work, kind):
    urls = work.get("content_urls") or {}
    if urls.get(kind):
        return urls[kind]
    work_id = str(work.get("id") or "").rsplit("/", 1)[-1]
    suffix = ".grobid-xml" if kind == "grobid_xml" else ".pdf"
    return f"https://content.openalex.org/works/{work_id}{suffix}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--patches", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--max-content-downloads", type=int, default=70)
    parser.add_argument("--delay", type=float, default=0.08)
    args = parser.parse_args()

    api_key = os.environ.get("OPENALEX_API_KEY")
    if not api_key:
        raise SystemExit("OPENALEX_API_KEY secret is required")

    output_path = Path(args.output)
    patches_path = Path(args.patches)
    report_path = Path(args.report)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    rows, patches = [], []
    content_downloads = 0
    counts = {k: 0 for k in [
        "input_record_count","missing_abstract_count","missing_with_doi_count","openalex_matched_count",
        "grobid_xml_available_count","pdf_only_available_count","grobid_download_attempt_count",
        "pdf_download_attempt_count","grobid_abstract_recovered_count","pdf_abstract_recovered_count",
        "content_checked_no_abstract_count","content_download_failure_count"]}

    with open(args.records, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            record = json.loads(line)
            counts["input_record_count"] += 1
            if abstract_of(record):
                continue
            counts["missing_abstract_count"] += 1
            doi = doi_of(record)
            if not doi:
                continue
            counts["missing_with_doi_count"] += 1
            result = {"record_id": record_id(record), "title": title_of(record), "doi": doi,
                      "openalex_matched": False, "grobid_xml": False, "pdf": False,
                      "status": "not_recovered", "canonical_mutated": False}
            status, work, _ = fetch_work_by_doi(doi, api_key)
            result["openalex_lookup_status"] = status
            if not work:
                rows.append(result); time.sleep(args.delay); continue
            counts["openalex_matched_count"] += 1
            result["openalex_matched"] = True
            result["openalex_id"] = work.get("id")
            openalex_doi = norm_doi((work.get("ids") or {}).get("doi") or work.get("doi"))
            result["openalex_doi"] = openalex_doi
            if openalex_doi and openalex_doi != doi:
                result["status"] = "doi_conflict"; rows.append(result); continue
            hc = work.get("has_content") or {}
            grobid, pdf = bool(hc.get("grobid_xml")), bool(hc.get("pdf"))
            result["grobid_xml"], result["pdf"] = grobid, pdf
            if grobid: counts["grobid_xml_available_count"] += 1
            if pdf and not grobid: counts["pdf_only_available_count"] += 1
            if not grobid and not pdf:
                result["status"] = "no_openalex_content"; rows.append(result); continue
            if content_downloads >= args.max_content_downloads:
                result["status"] = "content_download_limit_reached"; rows.append(result); continue

            recovered = source = None
            try:
                if grobid:
                    counts["grobid_download_attempt_count"] += 1
                    raw, _, headers = request_bytes(content_url(work, "grobid_xml"), api_key, "application/xml,text/xml,application/gzip,*/*")
                    content_downloads += 1
                    recovered = extract_tei_abstract(raw, headers)
                    source = "openalex_grobid_xml"
                    if recovered: counts["grobid_abstract_recovered_count"] += 1
                elif pdf:
                    counts["pdf_download_attempt_count"] += 1
                    raw, _, _ = request_bytes(content_url(work, "pdf"), api_key, "application/pdf,*/*")
                    content_downloads += 1
                    recovered = extract_pdf_abstract(raw)
                    source = "openalex_pdf"
                    if recovered: counts["pdf_abstract_recovered_count"] += 1
            except Exception as exc:
                counts["content_download_failure_count"] += 1
                result["status"] = "content_download_or_parse_failure"
                result["error"] = f"{type(exc).__name__}: {exc}"

            if recovered:
                result.update(status="abstract_recovered", abstract_source=source,
                              abstract_chars=len(recovered), abstract=recovered)
                patches.append({"record_id": record_id(record), "title": title_of(record), "doi": doi,
                                "openalex_id": work.get("id"), "abstract": recovered,
                                "abstract_source": source, "identity_basis": "exact_doi",
                                "canonical_mutated": False})
            elif result["status"] == "not_recovered":
                result["status"] = "content_checked_no_abstract"
                counts["content_checked_no_abstract_count"] += 1
            rows.append(result)
            time.sleep(args.delay)

    with output_path.open("w", encoding="utf-8") as h:
        for row in rows: h.write(json.dumps(row, ensure_ascii=False) + "\n")
    with patches_path.open("w", encoding="utf-8") as h:
        for patch in patches: h.write(json.dumps(patch, ensure_ascii=False) + "\n")
    report = {**counts, "content_download_count": content_downloads,
              "recovered_total_count": len(patches), "max_content_downloads": args.max_content_downloads,
              "canonical_mutated": False}
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
