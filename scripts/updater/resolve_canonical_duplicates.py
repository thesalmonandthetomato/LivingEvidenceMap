#!/usr/bin/env python3
"""Workflow 02 duplicate resolution by annotation.

The canonical JSONL is permanent and lossless: no record is deleted, collapsed, or
nested inside another record. Workflow 02 assigns deduplication state so downstream
workflows can process one representative per resolved duplicate group while retaining
every original record in the same JSONL.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
from collections import defaultdict
from pathlib import Path

from deduplicate_jsonl import canonical, extract_dois, load_records, norm


def current_relevance_decision(record):
    screening = record.get("screening")
    if not isinstance(screening, dict):
        return ""
    relevance = screening.get("relevance")
    if isinstance(relevance, dict):
        return str(relevance.get("decision") or "").upper().strip()
    return ""


def author_count(record):
    authors = canonical(record).get("authors") or []
    if isinstance(authors, str):
        return len([x for x in re.split(r"\s*\|\s*|\s*;\s*", authors) if x.strip()])
    return len(authors) if isinstance(authors, list) else 0


def year_value(record):
    m = re.search(r"(?:19|20)\d{2}", str(canonical(record).get("year") or ""))
    return int(m.group(0)) if m else 0


def survivor_score(record):
    """Prefer the richer published manifestation; DOI is supportive, never decisive."""
    c = canonical(record)
    source = norm(c.get("source"))
    abstract = norm(c.get("abstract"))
    title = norm(c.get("title"))
    return (
        4 if source else 0,
        3 if extract_dois(record) else 0,
        min(author_count(record), 10),
        min(len(abstract), 5000),
        min(len(title), 1000),
        year_value(record),
    )


def auto_resolvable(candidate):
    status = candidate.get("status")
    if status == "duplicate":
        return True, "deterministic_duplicate"
    if status != "probable_duplicate":
        return False, "requires_adjudication"

    manifestation = candidate.get("manifestation_pattern") or ""
    asim = float(candidate.get("abstract_similarity") or 0.0)
    tsim = float(candidate.get("title_similarity") or 0.0)

    if manifestation == "preprint_or_repository_to_later_manifestation" and asim >= 0.90:
        return True, "high_confidence_preprint_version"
    if manifestation == "same_work_manifestation" and asim >= 0.95 and tsim >= 0.85:
        return True, "very_high_confidence_same_work_version"
    return False, "requires_adjudication"


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
        "year": c.get("year"),
        "source": c.get("source"),
        "doi": extract_dois(record),
        "authors": c.get("authors"),
        "screening_relevance_decision": current_relevance_decision(record),
    }


def lens_id(record):
    return str(canonical(record).get("lens_id") or "")


def dedup_with_history(record, value):
    previous = record.get("deduplication")
    result = dict(value)
    if previous is not None:
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

    auto_pairs = []
    queued_pairs = []
    for candidate in candidates:
        ok, rule = auto_resolvable(candidate)
        c = dict(candidate)
        c["resolution_rule"] = rule
        a, b = c.get("record_index"), c.get("matched_index")
        if not isinstance(a, int) or not isinstance(b, int) or not (0 <= a < n and 0 <= b < n):
            c["resolution_rule"] = "invalid_pair_indices"
            queued_pairs.append(c)
        elif ok:
            auto_pairs.append(c)
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

    resolved_groups = []
    conflict_groups = []
    representative_by_index = {}
    members_by_representative = defaultdict(list)
    group_rules = defaultdict(set)

    for root, indices in sorted(groups.items()):
        indices = sorted(set(indices))
        decisions = {current_relevance_decision(records[i]) for i in indices if current_relevance_decision(records[i])}
        if len(decisions) > 1:
            conflict_groups.append({
                "queue_reason": "conflicting_current_screening_decisions",
                "screening_decisions": sorted(decisions),
                "records": [record_summary(records[i], i) for i in indices],
                "candidate_evidence": group_candidates[root],
            })
            queued_pairs.extend(group_candidates[root])
            continue

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
            link_ab = {
                "other_index": b,
                "other_lens_id": lens_id(records[b]),
                "status": c.get("status"),
                "basis": c.get("basis"),
                "title_similarity": c.get("title_similarity"),
                "abstract_similarity": c.get("abstract_similarity"),
                "manifestation_pattern": c.get("manifestation_pattern"),
            }
            link_ba = dict(link_ab, other_index=a, other_lens_id=lens_id(records[a]))
            review_refs[a].append(link_ab)
            review_refs[b].append(link_ba)

    output_records = []
    unique_count = 0
    representative_count = 0
    duplicate_count = 0
    adjudication_record_count = 0

    for i, original in enumerate(records):
        r = copy.deepcopy(original)
        if i in review_refs:
            r["deduplication"] = dedup_with_history(r, {
                "workflow": "02_deduplication",
                "status": "adjudication_required",
                "downstream_eligible": False,
                "candidate_links": review_refs[i],
            })
            adjudication_record_count += 1
        elif i in representative_by_index:
            rep = representative_by_index[i]
            if i == rep:
                duplicate_members = [lens_id(records[j]) for j in sorted(members_by_representative[rep])]
                r["deduplication"] = dedup_with_history(r, {
                    "workflow": "02_deduplication",
                    "status": "canonical",
                    "downstream_eligible": True,
                    "duplicate_members": duplicate_members,
                    "resolution_rules": sorted(group_rules[rep]),
                })
                representative_count += 1
            else:
                r["deduplication"] = dedup_with_history(r, {
                    "workflow": "02_deduplication",
                    "status": "duplicate",
                    "downstream_eligible": False,
                    "duplicate_of": lens_id(records[rep]),
                    "representative_index": rep,
                    "resolution_rules": sorted(group_rules[rep]),
                })
                duplicate_count += 1
        else:
            r["deduplication"] = dedup_with_history(r, {
                "workflow": "02_deduplication",
                "status": "unique",
                "downstream_eligible": True,
            })
            unique_count += 1
        output_records.append(r)

    outp = Path(args.output)
    outp.parent.mkdir(parents=True, exist_ok=True)
    with outp.open("w", encoding="utf-8") as f:
        for r in output_records:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    unique_queue = {}
    for c in queued_pairs:
        a, b = c.get("record_index"), c.get("matched_index")
        key = tuple(sorted((a, b))) if isinstance(a, int) and isinstance(b, int) else (str(a), str(b), c.get("lens_id"))
        old = unique_queue.get(key)
        if old is None or float(c.get("abstract_similarity") or 0) > float(old.get("abstract_similarity") or 0):
            unique_queue[key] = c

    queue_rows = []
    for c in unique_queue.values():
        a, b = c.get("record_index"), c.get("matched_index")
        row = dict(c)
        if isinstance(a, int) and 0 <= a < n:
            row["incoming_record"] = record_summary(records[a], a)
        if isinstance(b, int) and 0 <= b < n:
            row["matched_record"] = record_summary(records[b], b)
        queue_rows.append(row)

    with Path(args.queue).open("w", encoding="utf-8") as f:
        for row in sorted(queue_rows, key=lambda x: (str(x.get("status")), x.get("record_index", -1))):
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    Path(args.audit).write_text(json.dumps({
        "resolved_groups": resolved_groups,
        "screening_conflict_groups": conflict_groups,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    summary = {
        "input_records": n,
        "output_records": len(output_records),
        "candidate_pairs": len(candidates),
        "auto_candidate_pairs_before_conflict_gate": len(auto_pairs),
        "resolved_groups": len(resolved_groups),
        "canonical_representatives": representative_count,
        "duplicates_flagged": duplicate_count,
        "unique_records": unique_count,
        "adjudication_records": adjudication_record_count,
        "screening_conflict_groups": len(conflict_groups),
        "adjudication_pairs": len(queue_rows),
        "records_removed": 0,
        "records_nested": 0,
        "canonical_source_modified": False,
        "output_is_annotated_single_jsonl": True,
    }
    assert len(output_records) == n
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
