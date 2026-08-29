#!/usr/bin/env python3
"""Repair likely truncated canonical abstracts using exact DOI lookups.

Targets records whose canonical abstract contains either ASCII (...) or Unicode
(…) ellipsis. Providers are tried in caller-specified order. A provider result
replaces the *entire* canonical abstract. Lens raw payloads are never modified.
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path

EPMC_BASE = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
OPENALEX_BASE = "https://api.openalex.org/works/https://doi.org/"
USER_AGENT = "LivingEvidenceMap abstract repair (https://github.com/thesalmonandthetomato/LivingEvidenceMap)"


def now():
    return datetime.now(timezone.utc).isoformat()


def payload(r):
    lens = r.get("lens")
    return lens.get("raw_payload", {}) if isinstance(lens, dict) else {}


def lens_id(r):
    ident = r.get("identity") if isinstance(r.get("identity"), dict) else {}
    return str(ident.get("lens_id") or payload(r).get("lens_id") or "")


def normalise_doi(v):
    if v is None:
        return None
    d = str(v).strip().lower()
    for prefix in ("https://doi.org/", "http://doi.org/", "doi:"):
        if d.startswith(prefix):
            d = d[len(prefix):].strip()
    return d or None


def doi(r):
    c = r.get("canonical") if isinstance(r.get("canonical"), dict) else {}
    d = normalise_doi(c.get("doi"))
    if d:
        return d
    for x in payload(r).get("external_ids") or []:
        if isinstance(x, dict) and str(x.get("type", "")).lower() == "doi":
            d = normalise_doi(x.get("value"))
            if d:
                return d
    return None


def abstract(r):
    c = r.get("canonical") if isinstance(r.get("canonical"), dict) else {}
    v = c.get("abstract")
    return v if isinstance(v, str) and v.strip() else None


def has_ellipsis(text):
    return bool(text and ("..." in text or "…" in text))


def ends_ellipsis(text):
    return bool(text and text.rstrip().endswith(("...", "…")))


def request_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def lookup_europe_pmc(d):
    q = urllib.parse.urlencode({
        "query": f'DOI:"{d}"', "format": "json", "resultType": "core", "pageSize": 5
    })
    data = request_json(EPMC_BASE + "?" + q)
    hits = data.get("resultList", {}).get("result", [])
    exact = [h for h in hits if normalise_doi(h.get("doi")) == d]
    abst = next((h.get("abstractText") for h in exact if isinstance(h.get("abstractText"), str) and h.get("abstractText").strip()), None)
    status = "abstract_recovered" if abst else ("matched_no_abstract" if exact else "no_exact_match")
    return abst, {
        "provider": "europe_pmc", "status": status,
        "hit_count": data.get("hitCount"), "exact_doi_hit_count": len(exact)
    }


def reconstruct_openalex(inv):
    if not isinstance(inv, dict) or not inv:
        return None
    positions = []
    for word, locs in inv.items():
        if isinstance(locs, list):
            positions.extend((int(pos), str(word)) for pos in locs)
    if not positions:
        return None
    positions.sort()
    return " ".join(word for _, word in positions).strip() or None


def lookup_openalex(d):
    try:
        data = request_json(OPENALEX_BASE + urllib.parse.quote(d, safe=""))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, {"provider": "openalex", "status": "not_found"}
        raise
    returned_doi = normalise_doi((data.get("ids") or {}).get("doi") or data.get("doi"))
    if returned_doi != d:
        return None, {
            "provider": "openalex", "status": "doi_mismatch",
            "openalex_id": data.get("id"), "returned_doi": returned_doi
        }
    abst = reconstruct_openalex(data.get("abstract_inverted_index"))
    return abst, {
        "provider": "openalex",
        "status": "abstract_recovered" if abst else "matched_no_abstract",
        "openalex_id": data.get("id"), "returned_doi": returned_doi
    }


def lookup(provider, d):
    if provider == "europe_pmc":
        return lookup_europe_pmc(d)
    if provider == "openalex":
        return lookup_openalex(d)
    raise ValueError(provider)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--audit", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--providers", default="europe_pmc,openalex")
    ap.add_argument("--delay", type=float, default=0.10)
    args = ap.parse_args()

    providers = [x.strip() for x in args.providers.split(",") if x.strip()]
    if not providers or any(x not in {"europe_pmc", "openalex"} for x in providers):
        raise SystemExit(f"Invalid providers: {providers}")

    rows = [json.loads(line) for line in Path(args.input).read_text(encoding="utf-8").splitlines() if line.strip()]
    out, audit = [], []
    targets = targets_with_doi = targets_without_doi = replaced = technical_errors = 0
    provider_queries = {p: 0 for p in providers}
    provider_replacements = {p: 0 for p in providers}
    provider_status_counts = {p: {} for p in providers}

    for i, original in enumerate(rows, 1):
        r = deepcopy(original)
        old = abstract(r)
        if not has_ellipsis(old):
            out.append(r)
            continue
        targets += 1
        d = doi(r)
        entry = {
            "lens_id": lens_id(r), "doi": d, "old_abstract": old,
            "old_abstract_chars": len(old or ""),
            "old_abstract_ends_ellipsis": ends_ellipsis(old),
            "status": None, "replacement_provider": None,
            "replacement_abstract": None, "replacement_abstract_chars": None,
            "replacement_contains_ellipsis": None, "replacement_ends_ellipsis": None,
            "attempts": []
        }
        if not d:
            targets_without_doi += 1
            entry["status"] = "no_doi"
            audit.append(entry); out.append(r)
            continue

        targets_with_doi += 1
        replacement = replacement_provider = None
        for provider in providers:
            provider_queries[provider] += 1
            try:
                abst, meta = lookup(provider, d)
            except Exception as e:
                technical_errors += 1
                abst = None
                meta = {"provider": provider, "status": "technical_error", "error": f"{type(e).__name__}: {e}"}
            status = meta.get("status", "unknown")
            provider_status_counts[provider][status] = provider_status_counts[provider].get(status, 0) + 1
            meta["retrieved_at"] = now()
            entry["attempts"].append(meta)
            if abst:
                replacement, replacement_provider = abst, provider
                break
            time.sleep(args.delay)

        if replacement is not None:
            c = r.setdefault("canonical", {})
            c["abstract"] = replacement
            c["abstract_source"] = replacement_provider
            c["abstract_source_id"] = d
            r.setdefault("abstract_repair", {})["ellipsis_repair"] = {
                "status": "replaced", "provider": replacement_provider,
                "lookup": "exact_doi", "doi": d, "repaired_at": now(),
                "previous_abstract": old
            }
            replaced += 1
            provider_replacements[replacement_provider] += 1
            entry.update({
                "status": "replaced", "replacement_provider": replacement_provider,
                "replacement_abstract": replacement,
                "replacement_abstract_chars": len(replacement),
                "replacement_contains_ellipsis": has_ellipsis(replacement),
                "replacement_ends_ellipsis": ends_ellipsis(replacement)
            })
        else:
            entry["status"] = "not_recovered"

        audit.append(entry); out.append(r)
        if i % 100 == 0:
            print(f"processed {i}/{len(rows)} targets={targets} replaced={replaced}", flush=True)
        time.sleep(args.delay)

    still = sum(has_ellipsis(abstract(r)) for r in out)
    still_end = sum(ends_ellipsis(abstract(r)) for r in out)
    replacement_still = sum(bool(a.get("replacement_contains_ellipsis")) for a in audit if a.get("status") == "replaced")
    replacement_end = sum(bool(a.get("replacement_ends_ellipsis")) for a in audit if a.get("status") == "replaced")

    Path(args.output).write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in out), encoding="utf-8")
    Path(args.audit).write_text("".join(json.dumps(a, ensure_ascii=False, separators=(",", ":")) + "\n" for a in audit), encoding="utf-8")
    summary = {
        "created_at": now(),
        "lookup_policy": "Canonical abstracts containing ... or … are queried by exact DOI only; a provider result replaces the entire canonical abstract; Lens raw payload is never changed.",
        "providers": providers, "total_corpus_records": len(rows),
        "ellipsis_target_records": targets, "targets_with_doi": targets_with_doi,
        "targets_without_doi": targets_without_doi, "abstracts_replaced": replaced,
        "provider_queries": provider_queries, "provider_replacements": provider_replacements,
        "provider_status_counts": provider_status_counts, "technical_errors": technical_errors,
        "replacement_abstracts_still_containing_ellipsis": replacement_still,
        "replacement_abstracts_ending_in_ellipsis": replacement_end,
        "records_still_containing_ellipsis_after_repair": still,
        "records_still_ending_in_ellipsis_after_repair": still_end
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
