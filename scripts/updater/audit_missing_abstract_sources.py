#!/usr/bin/env python3
"""Audit source coverage for canonical records still missing abstracts.

Read-only: never mutates canonical. Produces per-record JSONL, hostname and
publisher summaries, and a compact JSON report suitable for planning
publisher/repository abstract recovery adapters.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

URL_RE = re.compile(r"https?://[^\s\]\[\)\(<>\"']+", re.I)
DOI_RE = re.compile(r"10\.\d{4,9}/[-._;()/:A-Z0-9]+", re.I)


def clean(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()


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


def norm_doi(value):
    if isinstance(value, list):
        value = next((x for x in value if x), None)
    value = clean(value).lower()
    value = re.sub(r"^https?://(dx\.)?doi\.org/", "", value)
    value = re.sub(r"^doi:\s*", "", value)
    m = DOI_RE.search(value)
    return m.group(0).rstrip(".,;)").lower() if m else None


def doi_of(record):
    return norm_doi(getv(record, ("canonical", "doi"), ("doi",), ("identifiers", "doi"), ("raw", "doi")))


def publisher_of(record):
    value = getv(
        record,
        ("canonical", "publisher"),
        ("publisher",),
        ("raw", "publisher"),
        ("source", "publisher"),
        ("canonical", "source", "publisher"),
    )
    if isinstance(value, list):
        value = "; ".join(clean(x) for x in value if clean(x))
    return clean(value) or None


def all_urls(obj):
    out = set()
    def walk(x):
        if isinstance(x, dict):
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
        elif isinstance(x, str):
            for match in URL_RE.findall(x):
                out.add(match.rstrip(".,;"))
    walk(obj)
    return sorted(out)


def host_of(url):
    try:
        host = (urlparse(url).hostname or "").lower().strip(".")
        if host.startswith("www."):
            host = host[4:]
        return host or None
    except Exception:
        return None


def classify_host(host):
    if not host:
        return "none"
    if host in {"doi.org", "dx.doi.org"}:
        return "doi_resolver"
    if host.endswith("openalex.org"):
        return "openalex"
    if host.endswith("lens.org"):
        return "lens"
    if host.endswith("crossref.org"):
        return "crossref"
    if host.endswith("semanticscholar.org"):
        return "semantic_scholar"
    return "publisher_or_repository"


def write_csv(path, counter, key_name):
    with path.open("w", newline="", encoding="utf-8") as h:
        w = csv.writer(h)
        w.writerow([key_name, "record_count"])
        for key, count in counter.most_common():
            w.writerow([key, count])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    rows = []
    hosts = Counter()
    actionable_hosts = Counter()
    publishers = Counter()
    host_publisher = Counter()

    total = missing = with_doi = without_doi = 0
    with_any_url = without_any_url = 0
    with_actionable_url = 0

    with open(args.records, encoding="utf-8") as h:
        for line in h:
            if not line.strip():
                continue
            r = json.loads(line)
            total += 1
            if abstract_of(r):
                continue
            missing += 1
            doi = doi_of(r)
            if doi:
                with_doi += 1
            else:
                without_doi += 1

            urls = all_urls(r)
            host_list = sorted({host_of(u) for u in urls if host_of(u)})
            actionable = sorted({x for x in host_list if classify_host(x) == "publisher_or_repository"})
            publisher = publisher_of(r)

            if urls:
                with_any_url += 1
            else:
                without_any_url += 1
            if actionable:
                with_actionable_url += 1

            for host in host_list:
                hosts[host] += 1
            for host in actionable:
                actionable_hosts[host] += 1
            if publisher:
                publishers[publisher] += 1
                for host in actionable:
                    host_publisher[(host, publisher)] += 1

            rows.append({
                "record_id": record_id(r),
                "title": title_of(r),
                "doi": doi,
                "publisher": publisher,
                "urls": urls,
                "hosts": host_list,
                "actionable_hosts": actionable,
                "has_doi": bool(doi),
                "has_any_url": bool(urls),
                "has_actionable_url": bool(actionable),
                "canonical_mutated": False,
            })

    with (outdir / "missing_abstract_source_audit.jsonl").open("w", encoding="utf-8") as h:
        for row in rows:
            h.write(json.dumps(row, ensure_ascii=False) + "\n")

    write_csv(outdir / "hostnames.csv", hosts, "hostname")
    write_csv(outdir / "actionable_hostnames.csv", actionable_hosts, "hostname")
    write_csv(outdir / "publishers.csv", publishers, "publisher")

    with (outdir / "hostname_publisher.csv").open("w", newline="", encoding="utf-8") as h:
        w = csv.writer(h)
        w.writerow(["hostname", "publisher", "record_count"])
        for (host, publisher), count in host_publisher.most_common():
            w.writerow([host, publisher, count])

    top_actionable = [{"hostname": k, "record_count": v} for k, v in actionable_hosts.most_common(30)]
    top_publishers = [{"publisher": k, "record_count": v} for k, v in publishers.most_common(30)]
    report = {
        "canonical_record_count": total,
        "missing_abstract_count": missing,
        "missing_with_doi_count": with_doi,
        "missing_without_doi_count": without_doi,
        "missing_with_any_stored_url_count": with_any_url,
        "missing_without_any_stored_url_count": without_any_url,
        "missing_with_publisher_or_repository_url_count": with_actionable_url,
        "unique_host_count": len(hosts),
        "unique_actionable_host_count": len(actionable_hosts),
        "unique_publisher_count": len(publishers),
        "top_actionable_hostnames": top_actionable,
        "top_publishers": top_publishers,
        "canonical_mutated": False,
    }
    (outdir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
