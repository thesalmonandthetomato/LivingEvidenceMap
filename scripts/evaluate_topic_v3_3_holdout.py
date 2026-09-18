#!/usr/bin/env python3
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path


OUT = Path("outputs/workflow06_luna_v3_3_validation")
SOURCE = Path("/tmp/ranked/topic_consistency_queue.csv")
REFERENCE = Path("/tmp/ranked/topic_consistency_reference.csv")
DEVELOPMENT = Path("docs/topic_adjudication_ranked_luna_2026-09.csv")


def read_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, fields):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def stable_key(record_id):
    return hashlib.sha256(("topic-v3.3-validation-2026-09|" + record_id).encode()).hexdigest()


def build_queue():
    OUT.mkdir(parents=True, exist_ok=True)
    source = read_csv(SOURCE)
    development_ids = {row["record_id"] for row in read_csv(DEVELOPMENT)}
    candidates = [row for row in source if row["record_id"] not in development_ids]
    candidates.sort(key=lambda row: (stable_key(row["record_id"]), row["record_id"]))
    selected = candidates[:20]
    if len(source) != 50:
        raise SystemExit(f"Expected 50 source records, found {len(source)}")
    if len(development_ids) != 22:
        raise SystemExit(f"Expected 22 previously considered records, found {len(development_ids)}")
    if len(candidates) != 28 or len(selected) != 20:
        raise SystemExit(f"Expected 28 eligible and 20 selected records, found {len(candidates)} and {len(selected)}")

    queue = [{"record_id": r["record_id"], "title": r.get("title", ""), "abstract": r.get("abstract", "")} for r in selected]
    write_csv(OUT / "validation_queue_20.csv", queue, ["record_id", "title", "abstract"])
    manifest = {
        "source_records": len(source),
        "excluded_previously_considered_records": len(development_ids),
        "eligible_held_out_records": len(candidates),
        "selected_records": len(selected),
        "selection": "First 20 after ascending SHA-256 of 'topic-v3.3-validation-2026-09|' plus record_id",
        "selected_record_ids": [r["record_id"] for r in selected],
        "queue_sha256": hashlib.sha256((OUT / "validation_queue_20.csv").read_bytes()).hexdigest(),
        "ontology": "data/reference/topic_ontology_v3_3.csv",
        "runner": "R/run_topic_v4_classifier_ranked_v3_1.R",
        "model": "gpt-5.6-luna",
        "reasoning_effort": "medium",
        "manual_gold_available": False,
        "interpretation": "A/B metrics measure reproducibility. Comparisons with historical assignments are diagnostic and are not accuracy estimates."
    }
    (OUT / "validation_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def load_assignments(path):
    assignments = defaultdict(dict)
    reasons = defaultdict(dict)
    for row in read_csv(path):
        assignments[row["record_id"]][row["path_id"]] = row["role"]
        reasons[row["record_id"]][row["path_id"]] = row.get("reason", "")
    return assignments, reasons


def load_reference():
    reference = defaultdict(set)
    for row in read_csv(REFERENCE):
        reference[row["record_id"]].add(row["path_id"])
    return reference


def metrics(left, right, ids):
    exact = tp = fp = fn = 0
    jaccards = []
    for record_id in ids:
        a, b = set(left[record_id]), set(right[record_id])
        exact += int(a == b)
        tp += len(a & b)
        fp += len(b - a)
        fn += len(a - b)
        union = a | b
        jaccards.append(len(a & b) / len(union) if union else 1.0)
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "records": len(ids),
        "exact_pathway_matches": exact,
        "exact_pathway_agreement": exact / len(ids),
        "pathway_precision": precision,
        "pathway_recall": recall,
        "pathway_f1": f1,
        "mean_jaccard": sum(jaccards) / len(jaccards),
        "tp": tp,
        "fp": fp,
        "fn": fn,
    }


def evaluate():
    queue = read_csv(OUT / "validation_queue_20.csv")
    ids = [row["record_id"] for row in queue]
    qby = {row["record_id"]: row for row in queue}
    a, ar = load_assignments(OUT / "luna_a" / "topic_assignments.csv")
    b, br = load_assignments(OUT / "luna_b" / "topic_assignments.csv")
    historical = load_reference()

    full_ranked_exact = sum(a[rid] == b[rid] for rid in ids)
    summary = {
        "validation_interpretation": "A/B comparison is reproducibility only. Historical assignments are not a manually adjudicated gold standard.",
        "a_b_reproducibility": metrics(a, b, ids),
        "a_b_exact_full_ranked_matches": full_ranked_exact,
        "a_b_exact_full_ranked_agreement": full_ranked_exact / len(ids),
        "luna_a_vs_historical_diagnostic": metrics(historical, a, ids),
        "luna_b_vs_historical_diagnostic": metrics(historical, b, ids),
    }
    (OUT / "validation_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    review = []
    for rid in ids:
        aset, bset, hset = set(a[rid]), set(b[rid]), set(historical[rid])
        review.append({
            "record_id": rid,
            "title": qby[rid]["title"],
            "abstract": qby[rid]["abstract"],
            "historical_pathways_not_gold": "; ".join(sorted(hset)),
            "luna_a_coding": "; ".join(f"{p}={a[rid][p]}" for p in sorted(a[rid])),
            "luna_b_coding": "; ".join(f"{p}={b[rid][p]}" for p in sorted(b[rid])),
            "a_b_pathway_exact": int(aset == bset),
            "a_only": "; ".join(sorted(aset - bset)),
            "b_only": "; ".join(sorted(bset - aset)),
            "role_disagreements": "; ".join(f"{p}:{a[rid][p]}->{b[rid][p]}" for p in sorted(aset & bset) if a[rid][p] != b[rid][p]),
            "luna_a_reasons": " | ".join(f"{p}: {ar[rid].get(p, '')}" for p in sorted(a[rid])),
            "luna_b_reasons": " | ".join(f"{p}: {br[rid].get(p, '')}" for p in sorted(b[rid])),
        })
    write_csv(OUT / "validation_review_queue.csv", review, list(review[0]))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2 or sys.argv[1] not in {"build", "evaluate"}:
        raise SystemExit("Usage: evaluate_topic_v3_3_holdout.py build|evaluate")
    build_queue() if sys.argv[1] == "build" else evaluate()
