#!/usr/bin/env python3
"""Workflow 02 duplicate resolution by lossless annotation.

Every input record remains a top-level record in the canonical JSONL. Duplicate
resolution uses bibliographic evidence from the full Lens payload as well as the
candidate similarity evidence. Strong evidence that two published records are distinct
outranks abstract similarity and removes those pairs from the human duplicate queue.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from deduplicate_jsonl import canonical, extract_dois, load_records, norm

PREPRINT_TERMS = {"preprint", "biorxiv", "medrxiv", "arxiv", "repository", "thesis", "dissertation"}


def raw_payload(record):
    p = record.get("lens", {}).get("raw_payload", {})
    return p if isinstance(p, dict) else {}


def source_metadata(record):
    s = raw_payload(record).get("source")
    return s if isinstance(s, dict) else {}


def source_title(record):
    c = canonical(record)
    return str(c.get("source") or source_metadata(record).get("title") or "")


def publication_type(record):
    return str(raw_payload(record).get("publication_type") or "")


def page_int(value):
    m = re.search(r"\d+", str(value or ""))
    return int(m.group(0)) if m else None


def author_count(record):
    authors = canonical(record).get("authors") or []
    if isinstance(authors, str):
        return len([x for x in re.split(r"\s*\|\s*|\s*;\s*", authors) if x.strip()])
    return len(authors) if isinstance(authors, list) else 0


def year_value(record):
    m = re.search(r"(?:19|20)\d{2}", str(canonical(record).get("year") or ""))
    return int(m.group(0)) if m else 0


def survivor_score(record):
    c = canonical(record)
    return (
        4 if norm(source_title(record)) else 0,
        3 if extract_dois(record) else 0,
        2 if raw_payload(record).get("volume") not in (None, "") else 0,
        2 if raw_payload(record).get("start_page") not in (None, "") else 0,
        min(author_count(record), 10),
        min(len(norm(c.get("abstract"))), 5000),
        min(len(norm(c.get("title"))), 1000),
        year_value(record),
    )


def is_preprint_like(record):
    text = " ".join((norm(publication_type(record)), norm(source_title(record))))
    return any(term in text for term in PREPRINT_TERMS) or not norm(source_title(record))


def bibliographic_fields(record):
    p = raw_payload(record)
    s = source_metadata(record)
    return {
        "publication_type": p.get("publication_type"),
        "publication_supplementary_type": p.get("publication_supplementary_type"),
        "source": source_title(record),
        "publisher": s.get("publisher"),
        "source_type": s.get("type"),
        "issn": s.get("issn") or [],
        "volume": p.get("volume"),
        "issue": p.get("issue"),
        "start_page": p.get("start_page"),
        "end_page": p.get("end_page"),
        "date_published": p.get("date_published"),
        "year_published": p.get("year_published"),
        "external_ids": p.get("external_ids"),
        "source_urls": p.get("source_urls"),
    }


def page_ranges_nonoverlap(a, b):
    pa, pb = raw_payload(a), raw_payload(b)
    sa, sb = page_int(pa.get("start_page")), page_int(pb.get("start_page"))
    if sa is None or sb is None or sa == sb:
        return False
    ea = page_int(pa.get("end_page")) or sa
    eb = page_int(pb.get("end_page")) or sb
    return ea < sb or eb < sa


def different_nonempty(a, b):
    na, nb = norm(a), norm(b)
    return bool(na and nb and na != nb)


def strong_distinct_work_evidence(a, b, candidate):
    """Return (reason_code, evidence) when published records are clearly distinct.

    The hierarchy is deliberately conservative: DOI disagreement is never sufficient
    alone, and preprint/repository manifestations are exempt. Once several independent
    bibliographic fields positively indicate separate published articles, abstract
    similarity cannot keep the pair in duplicate adjudication.
    """
    if is_preprint_like(a) or is_preprint_like(b):
        return None, []

    ca, cb = canonical(a), canonical(b)
    title_a, title_b = norm(ca.get("title")), norm(cb.get("title"))
    if title_a and title_a == title_b:
        return None, []

    pa, pb = raw_payload(a), raw_payload(b)
    source_a, source_b = norm(source_title(a)), norm(source_title(b))
    same_source = bool(source_a and source_a == source_b)
    different_source = bool(source_a and source_b and source_a != source_b)
    same_volume = bool(norm(pa.get("volume")) and norm(pa.get("volume")) == norm(pb.get("volume")))
    different_volume = different_nonempty(pa.get("volume"), pb.get("volume"))
    same_issue = bool(norm(pa.get("issue")) and norm(pa.get("issue")) == norm(pb.get("issue")))
    different_issue = different_nonempty(pa.get("issue"), pb.get("issue"))
    start_a, start_b = page_int(pa.get("start_page")), page_int(pb.get("start_page"))
    different_start_page = bool(start_a is not None and start_b is not None and start_a != start_b)
    nonoverlap = page_ranges_nonoverlap(a, b)
    title_sim = float(candidate.get("title_similarity") or 0.0)
    dois_a, dois_b = set(extract_dois(a)), set(extract_dois(b))
    disjoint_dois = bool(dois_a and dois_b and not (dois_a & dois_b))

    evidence = []

    # Strongest common false-positive pattern: related articles by the same team in
    # different journals. Different source + different DOI + materially different
    # title is sufficient published-work evidence; pagination/volume strengthen it.
    if different_source and disjoint_dois and title_sim < 0.985:
        evidence.extend([
            "different journal/source",
            "different DOI values",
            "materially different titles",
        ])
        if different_volume:
            evidence.append("different volume")
        if different_start_page or nonoverlap:
            evidence.append("different pagination")
        return "reject_different_journal_doi_title", evidence

    # Same journal context but clearly separate article locations.
    if same_source and same_volume and nonoverlap and title_sim < 0.985:
        evidence.extend([
            "same journal and volume",
            "non-overlapping pagination",
            "materially different titles",
        ])
        if disjoint_dois:
            evidence.append("different DOI values")
        if different_issue:
            evidence.append("different issue")
        return "reject_distinct_pagination", evidence

    # Same journal/issue, but distinct article locations plus distinct DOI/title.
    if same_source and same_issue and disjoint_dois and different_start_page and title_sim < 0.985:
        return "reject_same_issue_distinct_article", [
            "same journal and issue",
            "different DOI values",
            "different start pages/article locations",
            "materially different titles",
        ]

    return None, []


def auto_resolvable(candidate, a_record, b_record):
    reject_rule, evidence = strong_distinct_work_evidence(a_record, b_record, candidate)
    if reject_rule:
        return "not_duplicate", reject_rule, evidence

    status = candidate.get("status")
    if status == "duplicate":
        return "duplicate", "deterministic_duplicate", []
    if status != "probable_duplicate":
        return "queue", "requires_adjudication", []

    manifestation = candidate.get("manifestation_pattern") or ""
    asim = float(candidate.get("abstract_similarity") or 0.0)
    tsim = float(candidate.get("title_similarity") or 0.0)
    if manifestation == "preprint_or_repository_to_later_manifestation" and asim >= 0.90:
        return "duplicate", "high_confidence_preprint_version", []
    if manifestation == "same_work_manifestation" and asim >= 0.95 and tsim >= 0.85:
        return "duplicate", "very_high_confidence_same_work_version", []
    return "queue", "requires_adjudication", []


class UnionFind:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, x):
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def record_summary(record, index):
    c = canonical(record)
    return {
        "index": index,
        "record_id": c.get("record_id"),
        "lens_id": c.get("lens_id"),
        "title": c.get("title"),
        "authors": c.get("authors"),
        "year": c.get("year"),
        "doi": extract_dois(record),
        "abstract": c.get("abstract"),
        "bibliographic": bibliographic_fields(record),
    }


def lens_id(record):
    return str(canonical(record).get("lens_id") or "")


def dedup_with_history(record, value):
    previous = record.get("deduplication")
    result = dict(value)
    if isinstance(previous, dict) and previous.get("workflow") not in (None, "02_deduplication"):
        result["prior_deduplication"] = previous
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--queue", required=True)
    ap.add_argument("--audit", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    records = load_records(Path(args.canonical))
    candidates = load_records(Path(args.candidates))
    n = len(records)

    auto_pairs, queued_pairs, rejected_pairs = [], [], []
    for candidate in candidates:
        c = dict(candidate)
        a, b = c.get("record_index"), c.get("matched_index")
        if not isinstance(a, int) or not isinstance(b, int) or not (0 <= a < n and 0 <= b < n):
            c["resolution_rule"] = "invalid_pair_indices"
            queued_pairs.append(c)
            continue
        disposition, rule, evidence = auto_resolvable(c, records[a], records[b])
        c["resolution_rule"] = rule
        if evidence:
            c["bibliographic_conflict_evidence"] = evidence
        if disposition == "duplicate":
            auto_pairs.append(c)
        elif disposition == "not_duplicate":
            rejected_pairs.append(c)
        else:
            queued_pairs.append(c)

    uf = UnionFind(n)
    for c in auto_pairs:
        uf.union(c["record_index"], c["matched_index"])

    touched = set()
    for c in auto_pairs:
        touched.update((c["record_index"], c["matched_index"]))
    groups = defaultdict(list)
    for i in touched:
        groups[uf.find(i)].append(i)
    group_candidates = defaultdict(list)
    for c in auto_pairs:
        group_candidates[uf.find(c["record_index"])].append(c)

    representative_by_index = {}
    members_by_representative = defaultdict(list)
    group_rules = defaultdict(set)
    resolved_groups = []
    for root, indices in sorted(groups.items()):
        indices = sorted(set(indices))
        rep = max(indices, key=lambda i: survivor_score(records[i]))
        for i in indices:
            representative_by_index[i] = rep
            if i != rep:
                members_by_representative[rep].append(i)
        group_rules[rep].update(c["resolution_rule"] for c in group_candidates[root])
        resolved_groups.append({
            "representative_index": rep,
            "representative": record_summary(records[rep], rep),
            "duplicate_indices": sorted(i for i in indices if i != rep),
            "duplicates": [record_summary(records[i], i) for i in indices if i != rep],
            "resolution_rules": sorted(group_rules[rep]),
            "candidate_evidence": group_candidates[root],
        })

    review_refs = defaultdict(list)
    for c in queued_pairs:
        a, b = c.get("record_index"), c.get("matched_index")
        if isinstance(a, int) and isinstance(b, int) and 0 <= a < n and 0 <= b < n:
            link = {
                "status": c.get("status"), "basis": c.get("basis"),
                "title_similarity": c.get("title_similarity"),
                "abstract_similarity": c.get("abstract_similarity"),
                "manifestation_pattern": c.get("manifestation_pattern"),
            }
            review_refs[a].append(dict(link, other_index=b, other_lens_id=lens_id(records[b])))
            review_refs[b].append(dict(link, other_index=a, other_lens_id=lens_id(records[a])))

    output_records = []
    counts = defaultdict(int)
    for i, original in enumerate(records):
        r = copy.deepcopy(original)
        if i in review_refs:
            value = {"workflow":"02_deduplication","status":"adjudication_required","downstream_eligible":False,"candidate_links":review_refs[i]}
        elif i in representative_by_index:
            rep = representative_by_index[i]
            if i == rep:
                value = {"workflow":"02_deduplication","status":"canonical","downstream_eligible":True,
                         "duplicate_members":[lens_id(records[j]) for j in sorted(members_by_representative[rep])],
                         "resolution_rules":sorted(group_rules[rep])}
            else:
                value = {"workflow":"02_deduplication","status":"duplicate","downstream_eligible":False,
                         "duplicate_of":lens_id(records[rep]),"representative_index":rep,
                         "resolution_rules":sorted(group_rules[rep])}
        else:
            value = {"workflow":"02_deduplication","status":"unique","downstream_eligible":True}
        r["deduplication"] = dedup_with_history(r, value)
        counts[value["status"]] += 1
        output_records.append(r)

    outp = Path(args.output)
    outp.parent.mkdir(parents=True, exist_ok=True)
    with outp.open("w", encoding="utf-8") as f:
        for r in output_records:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    unique_queue = {}
    for c in queued_pairs:
        a, b = c.get("record_index"), c.get("matched_index")
        key = tuple(sorted((a,b))) if isinstance(a,int) and isinstance(b,int) else (str(a),str(b),c.get("lens_id"))
        old = unique_queue.get(key)
        if old is None or float(c.get("abstract_similarity") or 0) > float(old.get("abstract_similarity") or 0):
            unique_queue[key] = c

    queue_rows = []
    for c in unique_queue.values():
        a, b = c.get("record_index"), c.get("matched_index")
        row = dict(c)
        if isinstance(a,int) and 0 <= a < n:
            row["incoming_record"] = record_summary(records[a],a)
        if isinstance(b,int) and 0 <= b < n:
            row["matched_record"] = record_summary(records[b],b)
        queue_rows.append(row)
    with Path(args.queue).open("w", encoding="utf-8") as f:
        for row in sorted(queue_rows,key=lambda x:(str(x.get("status")),x.get("record_index",-1))):
            f.write(json.dumps(row,ensure_ascii=False)+"\n")

    rejection_reason_counts = Counter(c.get("resolution_rule") for c in rejected_pairs)
    audit = {
        "resolved_groups": resolved_groups,
        "bibliographically_rejected_pairs": [dict(c,
            incoming_record=record_summary(records[c["record_index"]],c["record_index"]),
            matched_record=record_summary(records[c["matched_index"]],c["matched_index"])) for c in rejected_pairs],
        "bibliographic_rejection_reason_counts": dict(sorted(rejection_reason_counts.items())),
    }
    Path(args.audit).write_text(json.dumps(audit,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    summary = {
        "input_records":n,"output_records":len(output_records),"candidate_pairs":len(candidates),
        "auto_candidate_pairs":len(auto_pairs),"bibliographically_rejected_pairs":len(rejected_pairs),
        "bibliographic_rejection_reason_counts":dict(sorted(rejection_reason_counts.items())),
        "resolved_groups":len(resolved_groups),"canonical_representatives":counts["canonical"],
        "duplicates_flagged":counts["duplicate"],"unique_records":counts["unique"],
        "adjudication_records":counts["adjudication_required"],"adjudication_pairs":len(queue_rows),
        "records_removed":0,"records_nested":0,"canonical_source_modified":False,
        "output_is_annotated_single_jsonl":True,
    }
    assert len(output_records)==n
    Path(args.summary).write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(summary,indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
