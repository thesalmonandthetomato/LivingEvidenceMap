#!/usr/bin/env python3
"""Seed Workflow 06 topic assignments from the repaired historical master.

No LLM calls are made here. Existing v3 topic assignments are inherited only
when the current included record has a unique, unambiguous exact match by
record_id, normalised DOI, or normalised title. Records without non-empty v3
paths remain in the residual queue for later classification.
"""

import argparse
import csv
import json
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path


def clean(value):
    return str(value or "").strip()


def normalise_doi(value):
    value = clean(value).lower()
    value = re.sub(r"^https?://(dx\.)?doi\.org/", "", value)
    value = re.sub(r"^doi:\s*", "", value)
    return value.rstrip(" .;,")


def normalise_title(value):
    value = unicodedata.normalize("NFKD", clean(value)).encode("ascii", "ignore").decode().lower()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


def split_multi(value):
    value = clean(value)
    if not value:
        return []
    return [x.strip() for x in re.split(r"\s*;\s*", value) if x.strip()]


def bool_or_none(value):
    value = clean(value).lower()
    if value in {"true", "t", "1", "yes"}:
        return True
    if value in {"false", "f", "0", "no"}:
        return False
    return None


def record_id(rec):
    identity = rec.get("identity") or {}
    return clean(identity.get("record_id") or identity.get("lens_id"))


def record_doi(rec):
    canonical = rec.get("canonical") or {}
    if canonical.get("doi"):
        return normalise_doi(canonical.get("doi"))
    raw = ((rec.get("lens") or {}).get("raw_payload") or {})
    for item in raw.get("external_ids") or []:
        if clean(item.get("type")).lower() == "doi" and item.get("value"):
            return normalise_doi(item.get("value"))
    return ""


def record_title(rec):
    canonical = rec.get("canonical") or {}
    if canonical.get("title"):
        return clean(canonical.get("title"))
    return clean(((rec.get("lens") or {}).get("raw_payload") or {}).get("title"))


def load_included_ids(path):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    ids = []
    for row in rows:
        decision = clean(row.get("screening_decision")).lower()
        if decision == "include":
            rid = clean(row.get("record_id"))
            if not rid:
                raise RuntimeError("Included Workflow 05 row has no record_id")
            ids.append(rid)
    if len(ids) != len(set(ids)):
        raise RuntimeError("Workflow 05 include record_id values are not unique")
    return ids


def load_historical(path):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = reader.fieldnames or []
        required = {"record_id", "doi", "title", "topic_path_ids", "topic_hierarchy_paths"}
        missing = required - set(fields)
        if missing:
            raise RuntimeError(f"Historical topic source missing columns: {sorted(missing)}")
        rows = []
        indexes = {key: defaultdict(list) for key in ("record_id", "doi", "title")}
        for source_row, row in enumerate(reader, start=2):
            item = {
                "source_row": source_row,
                "record_id": clean(row.get("record_id")),
                "doi": normalise_doi(row.get("doi")),
                "title": clean(row.get("title")),
                "title_norm": normalise_title(row.get("title")),
                "path_ids": split_multi(row.get("topic_path_ids")),
                "hierarchy_paths": split_multi(row.get("topic_hierarchy_paths")),
                "assignment_sources": split_multi(row.get("topic_assignment_sources")),
                "review_required": bool_or_none(row.get("topic_review_required")),
                "review_reason": clean(row.get("topic_review_reason")) or None,
            }
            if len(item["path_ids"]) != len(item["hierarchy_paths"]):
                raise RuntimeError(
                    f"Historical row {source_row}: topic_path_ids and topic_hierarchy_paths lengths differ"
                )
            idx = len(rows)
            rows.append(item)
            if item["record_id"]:
                indexes["record_id"][item["record_id"]].append(idx)
            if item["doi"]:
                indexes["doi"][item["doi"]].append(idx)
            if item["title_norm"]:
                indexes["title"][item["title_norm"]].append(idx)
    return rows, indexes


def topic_signature(row):
    return (
        tuple(row["path_ids"]),
        tuple(row["hierarchy_paths"]),
        tuple(row["assignment_sources"]),
        row["review_required"],
        row["review_reason"],
    )


def choose_historical_match(current, rows, indexes):
    for method, value in (
        ("record_id", current["record_id"]),
        ("doi", current["doi"]),
        ("title", current["title_norm"]),
    ):
        if not value:
            continue
        hits = indexes[method].get(value, [])
        if not hits:
            continue
        # Topic reuse requires a non-empty v3 assignment.
        usable = [rows[i] for i in hits if rows[i]["path_ids"]]
        if len(usable) == 1:
            return method, usable[0]
        if len(usable) > 1:
            signatures = {topic_signature(row) for row in usable}
            if len(signatures) == 1:
                return method, usable[0]
            return None
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-jsonl", required=True)
    parser.add_argument("--workflow05-csv", required=True)
    parser.add_argument("--historical-master", required=True)
    parser.add_argument("--ontology", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    included_ids = load_included_ids(args.workflow05_csv)
    included_set = set(included_ids)

    with open(args.ontology, encoding="utf-8-sig", newline="") as handle:
        ontology_rows = list(csv.DictReader(handle))
    valid_paths = {clean(r.get("path_id")): clean(r.get("hierarchy_path")) for r in ontology_rows}
    if not valid_paths:
        raise RuntimeError("Topic ontology is empty")

    historical_rows, historical_indexes = load_historical(args.historical_master)
    matches = {}
    method_counts = Counter()
    canonical_records = []

    with open(args.input_jsonl, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            rec = json.loads(line)
            rid = record_id(rec)
            if not rid:
                raise RuntimeError("Canonical JSON record has no record_id/lens_id")
            current = {
                "record_id": rid,
                "doi": record_doi(rec),
                "title_norm": normalise_title(record_title(rec)),
            }
            if rid in included_set:
                selected = choose_historical_match(current, historical_rows, historical_indexes)
                if selected:
                    method, source = selected
                    unknown = [pid for pid in source["path_ids"] if pid not in valid_paths]
                    if unknown:
                        raise RuntimeError(f"Historical topic assignment contains unknown path_id(s) for {rid}: {unknown}")
                    expected_paths = [valid_paths[pid] for pid in source["path_ids"]]
                    if expected_paths != source["hierarchy_paths"]:
                        raise RuntimeError(f"Historical path ID/path text mismatch for {rid}")
                    matches[rid] = (method, source)
                    method_counts[method] += 1
            canonical_records.append(rec)

    canonical_ids = {record_id(rec) for rec in canonical_records}
    missing = sorted(included_set - canonical_ids)
    if missing:
        raise RuntimeError(f"{len(missing)} Workflow 05 includes are absent from canonical JSON")

    queue_rows = []
    assignment_rows = []
    output_jsonl = output_dir / "records.jsonl"
    with open(output_jsonl, "w", encoding="utf-8") as out:
        for rec in canonical_records:
            rid = record_id(rec)
            if rid not in included_set:
                rec["topics"] = {
                    "workflow": "workflow_06_topics",
                    "status": "not_applicable",
                    "reason": "record_not_in_workflow05_include_set",
                }
            elif rid in matches:
                method, source = matches[rid]
                rec["topics"] = {
                    "workflow": "workflow_06_topics",
                    "status": "historical_reuse",
                    "assignment_source": "historical_v3_repaired_master",
                    "source_file": "data/reference/living_evidence_map_master_topic_repaired.csv",
                    "match_method": method,
                    "source_record_id": source["record_id"] or None,
                    "source_row": source["source_row"],
                    "path_ids": source["path_ids"],
                    "hierarchy_paths": source["hierarchy_paths"],
                    "historical_assignment_sources": source["assignment_sources"],
                    "review_required": source["review_required"],
                    "review_reason": source["review_reason"],
                }
                for pid, path in zip(source["path_ids"], source["hierarchy_paths"]):
                    assignment_rows.append({
                        "record_id": rid,
                        "path_id": pid,
                        "hierarchy_path": path,
                        "assignment_source": "historical_v3_repaired_master",
                        "match_method": method,
                        "source_record_id": source["record_id"],
                        "source_row": source["source_row"],
                        "review_required": source["review_required"],
                        "review_reason": source["review_reason"] or "",
                    })
            else:
                rec["topics"] = {
                    "workflow": "workflow_06_topics",
                    "status": "pending_llm",
                }
                queue_rows.append({
                    "record_id": rid,
                    "title": record_title(rec),
                    "abstract": clean((rec.get("canonical") or {}).get("abstract")),
                    "doi": record_doi(rec),
                })
            out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")

    assignment_fields = [
        "record_id", "path_id", "hierarchy_path", "assignment_source", "match_method",
        "source_record_id", "source_row", "review_required", "review_reason"
    ]
    with open(output_dir / "topic_assignments_historical.csv", "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=assignment_fields)
        writer.writeheader()
        writer.writerows(assignment_rows)

    with open(output_dir / "topic_llm_queue.csv", "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["record_id", "title", "abstract", "doi"])
        writer.writeheader()
        writer.writerows(queue_rows)

    summary = {
        "workflow": "workflow_06_topics",
        "stage": "historical_seed_complete",
        "canonical_records": len(canonical_records),
        "workflow05_includes": len(included_ids),
        "records_with_reused_v3_topics": len(matches),
        "reused_v3_fraction": round(len(matches) / len(included_ids), 6) if included_ids else 0,
        "historical_topic_assignment_rows": len(assignment_rows),
        "records_queued_for_llm": len(queue_rows),
        "match_methods": dict(sorted(method_counts.items())),
        "historical_source": "data/reference/living_evidence_map_master_topic_repaired.csv",
        "ontology": args.ontology,
        "llm_calls_made": 0,
        "safety_rule": "Only non-empty v3 path assignments from unique exact matches, or duplicate exact matches with identical topic payloads, are reused.",
    }
    with open(output_dir / "workflow06_seed_summary.json", "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, ensure_ascii=False)

    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
