#!/usr/bin/env python3
"""Workflow 02 deterministic duplicate resolution.

Consumes the read-only canonical duplicate audit and produces:
- a proposed deduplicated canonical JSONL (artifact only; never writes the source store),
- an adjudication queue for ambiguous pairs/groups,
- an audit trail and summary.

Automatic resolution is deliberately conservative. Exact bibliographic duplicates and
high-confidence preprint/version manifestations are resolved. Conflicting current
screening decisions always force human adjudication.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
from collections import defaultdict
from pathlib import Path

from deduplicate_jsonl import canonical, extract_dois, load_records, norm


def load_jsonl(path: Path):
    return load_records(path)


def current_relevance_decision(record):
    screening = record.get("screening")
    if not isinstance(screening, dict):
        return ""
    relevance = screening.get("relevance")
    if isinstance(relevance, dict):
        return str(relevance.get("decision") or "").upper().strip()
    return ""


def author_count(record):
    a = canonical(record).get("authors") or []
    if isinstance(a, str):
        return len([x for x in re.split(r"\s*\|\s*|\s*;\s*", a) if x.strip()])
    return len(a) if isinstance(a, list) else 0


def source_value(record):
    return norm(canonical(record).get("source"))


def year_value(record):
    value = canonical(record).get("year")
    m = re.search(r"(?:19|20)\d{2}", str(value or ""))
    return int(m.group(0)) if m else 0


def survivor_score(record):
    """Prefer richer, published manifestations without relying on DOI alone."""
    c = canonical(record)
    source = source_value(record)
    dois = extract_dois(record)
    abstract = norm(c.get("abstract"))
    title = norm(c.get("title"))
    return (
        4 if source else 0,
        3 if dois else 0,
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

    # Known preprint/repository failure mode: same first author and compatible year
    # have already been enforced by Workflow 02 classification. Require >=0.90
    # abstract similarity before automatic collapse.
    if manifestation == "preprint_or_repository_to_later_manifestation" and asim >= 0.90:
        return True, "high_confidence_preprint_version"

    # Same-work manifestations without explicit preprint evidence need a higher bar.
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


def merge_group(records, indices, candidate_rows):
    survivor_idx = max(indices, key=lambda i: survivor_score(records[i]))
    survivor = copy.deepcopy(records[survivor_idx])
    absorbed = [i for i in indices if i != survivor_idx]

    prior_dedup = survivor.get("deduplication")
    aliases = []
    merged_records = []
    for i in absorbed:
        c = canonical(records[i])
        lid = str(c.get("lens_id") or "")
        if lid and lid != str(canonical(survivor).get("lens_id") or ""):
            aliases.append(lid)
        # Preserve the complete absorbed source record exactly as evidence.
        merged_records.append({"source_index": i, "record": records[i]})

    bases = sorted({str(c.get("resolution_rule") or "") for c in candidate_rows if c.get("resolution_rule")})
    survivor["deduplication"] = {
        "workflow": "02_deduplication",
        "resolution_status": "auto_resolved",
        "canonical_survivor": True,
        "survivor_source_index": survivor_idx,
        "absorbed_count": len(absorbed),
        "alternate_lens_ids": sorted(set(aliases)),
        "resolution_rules": bases,
        "merged_records": merged_records,
    }
    if prior_dedup is not None:
        survivor["deduplication"]["prior_deduplication"] = prior_dedup
    return survivor_idx, survivor, absorbed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--queue", required=True)
    ap.add_argument("--audit", required=True)
    ap.add_argument("--summary", required=True)
    args = ap.parse_args()

    records = load_jsonl(Path(args.canonical))
    candidates = load_jsonl(Path(args.candidates))
    n = len(records)

    auto_pairs = []
    queued_pairs = []
    for c in candidates:
        ok, rule = auto_resolvable(c)
        enriched = dict(c)
        enriched["resolution_rule"] = rule
        a, b = c.get("record_index"), c.get("matched_index")
        if not isinstance(a, int) or not isinstance(b, int) or not (0 <= a < n and 0 <= b < n):
            enriched["resolution_rule"] = "invalid_pair_indices"
            queued_pairs.append(enriched)
            continue
        if ok:
            auto_pairs.append(enriched)
        else:
            queued_pairs.append(enriched)

    # Build candidate auto-resolution groups.
    uf = UnionFind(n)
    for c in auto_pairs:
        uf.union(c["record_index"], c["matched_index"])

    groups = defaultdict(list)
    touched = set()
    for c in auto_pairs:
        touched.update([c["record_index"], c["matched_index"]])
    for i in touched:
        groups[uf.find(i)].append(i)

    # Map auto-pair evidence to groups.
    group_candidates = defaultdict(list)
    for c in auto_pairs:
        group_candidates[uf.find(c["record_index"])].append(c)

    resolved_groups = []
    conflict_groups = []
    absorbed_indices = set()
    survivor_records = {}

    for root, indices in sorted(groups.items()):
        indices = sorted(set(indices))
        decisions = {current_relevance_decision(records[i]) for i in indices if current_relevance_decision(records[i])}
        if len(decisions) > 1:
            conflict = {
                "queue_reason": "conflicting_current_screening_decisions",
                "screening_decisions": sorted(decisions),
                "records": [record_summary(records[i], i) for i in indices],
                "candidate_evidence": group_candidates[root],
            }
            conflict_groups.append(conflict)
            # Every pair in the conflicted group becomes adjudication material.
            queued_pairs.extend(group_candidates[root])
            continue

        survivor_idx, survivor, absorbed = merge_group(records, indices, group_candidates[root])
        survivor_records[survivor_idx] = survivor
        absorbed_indices.update(absorbed)
        resolved_groups.append({
            "survivor_index": survivor_idx,
            "survivor": record_summary(records[survivor_idx], survivor_idx),
            "absorbed_indices": absorbed,
            "absorbed": [record_summary(records[i], i) for i in absorbed],
            "resolution_rules": sorted({c["resolution_rule"] for c in group_candidates[root]}),
            "candidate_evidence": group_candidates[root],
        })

    # Mark unresolved records in the proposed output without collapsing them.
    review_refs = defaultdict(list)
    for c in queued_pairs:
        a, b = c.get("record_index"), c.get("matched_index")
        if isinstance(a, int) and isinstance(b, int) and 0 <= a < n and 0 <= b < n:
            review_refs[a].append({"other_index": b, "status": c.get("status"), "basis": c.get("basis")})
            review_refs[b].append({"other_index": a, "status": c.get("status"), "basis": c.get("basis")})

    output_records = []
    for i, original in enumerate(records):
        if i in absorbed_indices:
            continue
        if i in survivor_records:
            output_records.append(survivor_records[i])
            continue
        r = copy.deepcopy(original)
        if review_refs.get(i):
            prior = r.get("deduplication")
            r["deduplication"] = {
                "workflow": "02_deduplication",
                "resolution_status": "adjudication_required",
                "candidate_links": review_refs[i],
            }
            if prior is not None:
                r["deduplication"]["prior_deduplication"] = prior
        output_records.append(r)

    outp = Path(args.output)
    outp.parent.mkdir(parents=True, exist_ok=True)
    with outp.open("w", encoding="utf-8") as f:
        for r in output_records:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    # Deduplicate queue pairs by record-index pair and retain strongest available evidence.
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

    qp = Path(args.queue)
    with qp.open("w", encoding="utf-8") as f:
        for r in sorted(queue_rows, key=lambda x: (str(x.get("status")), x.get("record_index", -1))):
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    audit = {
        "resolved_groups": resolved_groups,
        "screening_conflict_groups": conflict_groups,
    }
    Path(args.audit).write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    summary = {
        "input_records": n,
        "candidate_pairs": len(candidates),
        "auto_candidate_pairs_before_conflict_gate": len(auto_pairs),
        "resolved_groups": len(resolved_groups),
        "absorbed_records": len(absorbed_indices),
        "proposed_output_records": len(output_records),
        "screening_conflict_groups": len(conflict_groups),
        "adjudication_pairs": len(queue_rows),
        "canonical_source_modified": False,
        "output_is_proposed_artifact": True,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
