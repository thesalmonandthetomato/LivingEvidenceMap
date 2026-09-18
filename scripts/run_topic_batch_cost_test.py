#!/usr/bin/env python3
import csv
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


API_ROOT = "https://api.openai.com/v1"
OUT = Path(os.getenv("COST_TEST_OUTPUT_DIR", "outputs/workflow06_topic_cost_test_100"))
QUEUE = OUT / "validation_queue_100.csv"
MASTER = Path("data/master/current/living_evidence_map_master.csv")
BENCHMARK = Path("/tmp/ranked/topic_consistency_queue.csv")
ONTOLOGY = Path(os.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3_4.csv"))
SYSTEM_PROMPT_PATH = Path(os.getenv("TOPIC_SYSTEM_PROMPT_PATH", "/tmp/prior_batch/luna_a/topic_v4_system_prompt.txt"))
ADDITIONAL_EXCLUSIONS = os.getenv("COST_TEST_ADDITIONAL_EXCLUSIONS", "")
SALT = os.getenv("COST_TEST_SELECTION_SALT", "topic-v3.4-cost-test-100-2026-09|")
SAMPLE_SIZE = int(os.getenv("COST_TEST_SAMPLE_SIZE", "100"))
POLL_SECONDS = int(os.getenv("BATCH_POLL_SECONDS", "20"))
MAX_WAIT_SECONDS = int(os.getenv("BATCH_MAX_WAIT_SECONDS", "18000"))
LUNA_MODEL = "gpt-5.6-luna"
TERRA_MODEL = "gpt-5.6-terra"

# Batch prices per 1M tokens, verified from the OpenAI pricing page on 2026-09-18.
PRICES = {
    LUNA_MODEL: {"input": 0.10, "cached": 0.01, "cache_write": 0.125, "output": 0.60},
    TERRA_MODEL: {"input": 1.00, "cached": 0.10, "cache_write": 1.25, "output": 6.00},
}


def read_csv(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, fields):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def api_request(method, route, payload=None, raw_body=None, headers=None, timeout=300, expect_bytes=False):
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is required")
    request_headers = {"Authorization": f"Bearer {api_key}"}
    if headers:
        request_headers.update(headers)
    data = raw_body
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API_ROOT + route, data=data, headers=request_headers, method=method)
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read()
                if expect_bytes:
                    return body
                content_type = response.headers.get("Content-Type", "")
                return json.loads(body) if "json" in content_type else body
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code not in {408, 409, 429, 500, 502, 503, 504} or attempt == 4:
                raise RuntimeError(f"OpenAI API {exc.code}: {detail}") from exc
        except urllib.error.URLError:
            if attempt == 4:
                raise
        time.sleep(2 ** attempt)


def upload_batch_file(path):
    boundary = "----cost-test-" + uuid.uuid4().hex
    file_bytes = Path(path).read_bytes()
    chunks = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{Path(path).name}\"\r\nContent-Type: application/jsonl\r\n\r\n".encode(),
        file_bytes,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    return api_request(
        "POST", "/files", raw_body=b"".join(chunks),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, timeout=300,
    )


def submit_and_wait(jsonl_path, label):
    uploaded = upload_batch_file(jsonl_path)
    batch = api_request("POST", "/batches", payload={
        "input_file_id": uploaded["id"],
        "endpoint": "/v1/responses",
        "completion_window": "24h",
        "metadata": {"description": label},
    })
    started = time.time()
    while batch["status"] not in {"completed", "failed", "expired", "cancelled"}:
        if time.time() - started > MAX_WAIT_SECONDS:
            raise RuntimeError(f"Batch {batch['id']} did not finish within {MAX_WAIT_SECONDS} seconds")
        time.sleep(POLL_SECONDS)
        batch = api_request("GET", f"/batches/{batch['id']}")
        print(f"{label}: {batch['status']} {batch.get('request_counts')}", flush=True)
    if batch["status"] != "completed":
        raise RuntimeError(f"Batch {batch['id']} ended with status {batch['status']}: {batch.get('errors')}")
    raw = api_request("GET", f"/files/{batch['output_file_id']}/content", expect_bytes=True)
    output_path = OUT / f"{label}_output.jsonl"
    output_path.write_bytes(raw)
    if batch.get("error_file_id"):
        errors = api_request("GET", f"/files/{batch['error_file_id']}/content", expect_bytes=True)
        (OUT / f"{label}_errors.jsonl").write_bytes(errors)
    (OUT / f"{label}_batch.json").write_text(json.dumps(batch, indent=2) + "\n", encoding="utf-8")
    return [json.loads(line) for line in raw.decode("utf-8").splitlines() if line.strip()]


def ontology_prompt(rows):
    labels = [
        ("Definition", "definition"), ("Include when", "include_when"),
        ("Exclude when", "exclude_when"), ("Subject concept cues", "required_subject_terms"),
        ("Focus concept cues", "required_focus_terms"),
        ("Alternative specific cues", "alternative_standalone_cues"),
        ("Supporting lexical cues", "supporting_terms_from_old_ontology"),
        ("Interpretation note", "prompt_logic_note"),
    ]
    entries = []
    for row in rows:
        lines = [f"{row['path_id']} | {row['hierarchy_path']}"]
        for label, field in labels:
            value = (row.get(field) or "").strip()
            if value:
                lines.append(f"{label}: {value}")
        entries.append("\n".join(lines))
    return "\n\n".join(entries)


def topic_schema(path_ids):
    return {
        "type": "object",
        "properties": {
            "assignments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "path_id": {"type": "string", "enum": path_ids},
                        "role": {"type": "string", "enum": ["PRIMARY", "SECONDARY"]},
                        "reason": {"type": "string"},
                    },
                    "required": ["path_id", "role", "reason"],
                    "additionalProperties": False,
                },
            },
            "review_required": {"type": "boolean"},
            "review_reason": {"type": ["string", "null"]},
        },
        "required": ["assignments", "review_required", "review_reason"],
        "additionalProperties": False,
    }


def extract_output_text(response):
    for item in response.get("output", []):
        if item.get("type") == "message":
            for content in item.get("content", []):
                if content.get("type") == "output_text":
                    return content["text"]
    raise RuntimeError("No output_text returned")


def usage_row(label, custom_id, model, response):
    usage = response.get("usage") or {}
    details = usage.get("input_tokens_details") or {}
    input_tokens = int(usage.get("input_tokens") or 0)
    cached = int(details.get("cached_tokens") or 0)
    cache_write = int(details.get("cache_write_tokens") or 0)
    ordinary = input_tokens - cached - cache_write
    output = int(usage.get("output_tokens") or 0)
    reasoning = int((usage.get("output_tokens_details") or {}).get("reasoning_tokens") or 0)
    prices = PRICES[model]
    cost = (
        ordinary * prices["input"] + cached * prices["cached"] +
        cache_write * prices["cache_write"] + output * prices["output"]
    ) / 1_000_000
    return {
        "stage": label, "custom_id": custom_id, "model": model,
        "input_tokens": input_tokens, "ordinary_input_tokens": ordinary,
        "cached_input_tokens": cached, "cache_write_tokens": cache_write,
        "output_tokens": output, "reasoning_tokens": reasoning,
        "total_tokens": int(usage.get("total_tokens") or input_tokens + output),
        "estimated_batch_cost_usd": f"{cost:.9f}",
    }


def stable_key(record_id):
    return hashlib.sha256((SALT + record_id).encode()).hexdigest()


def build_queue():
    OUT.mkdir(parents=True, exist_ok=True)
    source = read_csv(MASTER)
    benchmark_ids = {r["record_id"] for r in read_csv(BENCHMARK)}
    if len(benchmark_ids) != 50:
        raise RuntimeError(f"Expected 50 benchmark exclusions, found {len(benchmark_ids)}")
    exclusion_sources = []
    additional_ids = set()
    for value in [x for x in ADDITIONAL_EXCLUSIONS.split(os.pathsep) if x]:
        ids = {r["record_id"] for r in read_csv(value)}
        if ids & benchmark_ids or ids & additional_ids:
            raise RuntimeError(f"Overlapping exclusion source: {value}")
        additional_ids |= ids
        exclusion_sources.append({"path": value, "records": len(ids)})
    excluded = benchmark_ids | additional_ids
    candidates = [
        r for r in source if r.get("record_id", "").strip() and r["record_id"] not in excluded
        and r.get("title", "").strip() and r.get("abstract", "").strip()
    ]
    candidates.sort(key=lambda r: (stable_key(r["record_id"]), r["record_id"]))
    selected = candidates[:SAMPLE_SIZE]
    if len(selected) != SAMPLE_SIZE:
        raise RuntimeError(f"Expected {SAMPLE_SIZE} selected records, found {len(selected)}")
    queue = [{"record_id": r["record_id"], "title": r["title"], "abstract": r["abstract"]} for r in selected]
    write_csv(QUEUE, queue, ["record_id", "title", "abstract"])
    write_csv(
        OUT / "historical_context_not_gold.csv",
        [{"record_id": r["record_id"], "historical_pathways_not_gold": r.get("topic_path_ids", "")} for r in selected],
        ["record_id", "historical_pathways_not_gold"],
    )
    manifest = {
        "source": str(MASTER), "source_sha256": hashlib.sha256(MASTER.read_bytes()).hexdigest(),
        "source_records": len(source), "excluded_original_benchmark_records": len(benchmark_ids),
        "additional_exclusion_sources": exclusion_sources,
        "excluded_additional_records": len(additional_ids), "excluded_total_unique_records": len(excluded),
        "eligible_records": len(candidates), "selected_records": len(selected), "selection_salt": SALT,
        "selection": f"First {SAMPLE_SIZE} after ascending SHA-256 of selection_salt plus record_id",
        "selected_record_ids": [r["record_id"] for r in selected],
        "queue_sha256": hashlib.sha256(QUEUE.read_bytes()).hexdigest(),
        "ontology": str(ONTOLOGY), "models": {"passes": LUNA_MODEL, "adjudicator": TERRA_MODEL},
        "reasoning_effort": "medium", "processing": "Batch API", "manual_gold_available": False,
    }
    (OUT / "selection_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


def run_luna():
    records = read_csv(QUEUE)
    ontology = read_csv(ONTOLOGY)
    system_prompt = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()
    stable_prefix = system_prompt + "\n\nONTOLOGY\n\n" + ontology_prompt(ontology)
    schema = topic_schema([r["path_id"] for r in ontology])
    input_path = OUT / "luna_batch_input.jsonl"
    with input_path.open("w", encoding="utf-8") as handle:
        for pass_name in ("a", "b"):
            for row in records:
                body = {
                    "model": LUNA_MODEL, "store": False, "reasoning": {"effort": "medium"},
                    "prompt_cache_key": "topic-v3.4-cost-test-luna",
                    "prompt_cache_options": {"mode": "explicit", "ttl": "30m"},
                    "input": [
                        {"role": "system", "content": [{"type": "input_text", "text": stable_prefix,
                            "prompt_cache_breakpoint": {"mode": "explicit"}}]},
                        {"role": "user", "content": [{"type": "input_text", "text":
                            f"RECORD\n\nTitle: {row['title']}\n\nAbstract: {row['abstract']}\n\nReturn the substantive ontology assignments."}]},
                    ],
                    "text": {"verbosity": "low", "format": {"type": "json_schema", "name": "topic_v4", "strict": True, "schema": schema}},
                }
                request = {"custom_id": f"luna-{pass_name}-{row['record_id']}", "method": "POST", "url": "/v1/responses", "body": body}
                handle.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
    results = submit_and_wait(input_path, "luna")
    record_by_id = {r["record_id"]: r for r in records}
    ontology_by_id = {r["path_id"]: r for r in ontology}
    per_pass = {"a": [], "b": []}
    usage_rows = []
    failures = []
    for item in results:
        custom_id = item["custom_id"]
        _, pass_name, record_id = custom_id.split("-", 2)
        response = (item.get("response") or {}).get("body")
        if not response or item.get("error"):
            failures.append({"custom_id": custom_id, "error": json.dumps(item.get("error") or item)})
            continue
        usage_rows.append(usage_row("luna", custom_id, LUNA_MODEL, response))
        parsed = json.loads(extract_output_text(response))
        assignments = []
        seen = set()
        for assignment in parsed["assignments"]:
            path_id = assignment["path_id"]
            if path_id not in ontology_by_id or path_id in seen:
                continue
            seen.add(path_id)
            assignments.append(assignment)
        per_pass[pass_name].append((record_id, parsed, assignments))
    if failures or any(len(per_pass[p]) != len(records) for p in ("a", "b")):
        write_csv(OUT / "luna_batch_failures.csv", failures, ["custom_id", "error"])
        raise RuntimeError(f"Luna batch failures or missing results: {len(failures)}")
    for pass_name in ("a", "b"):
        out_dir = OUT / f"luna_{pass_name}"
        long_rows, record_rows = [], []
        for record_id, parsed, assignments in per_pass[pass_name]:
            source = record_by_id[record_id]
            for assignment in assignments:
                long_rows.append({
                    "record_id": record_id, "title": source["title"], "abstract": source["abstract"],
                    "path_id": assignment["path_id"], "role": assignment["role"], "reason": assignment["reason"],
                    "hierarchy_path": ontology_by_id[assignment["path_id"]]["hierarchy_path"],
                })
            record_rows.append({
                "record_id": record_id, "title": source["title"], "abstract": source["abstract"],
                "assigned_path_ids": "; ".join(a["path_id"] for a in assignments),
                "assigned_path_roles": "; ".join(f"{a['path_id']}={a['role']}" for a in assignments),
                "assignment_count": len(assignments), "review_required": parsed["review_required"],
                "review_reason": parsed["review_reason"] or "", "status": "completed", "classification_error": "",
            })
        write_csv(out_dir / "topic_assignments.csv", long_rows, ["record_id", "title", "abstract", "path_id", "role", "reason", "hierarchy_path"])
        write_csv(out_dir / "topic_classification_records.csv", record_rows, list(record_rows[0]))
        write_csv(out_dir / "topic_classification_failures.csv", [], ["record_id", "classification_error"])
    write_csv(OUT / "luna_usage.csv", usage_rows, list(usage_rows[0]))
    print(f"Completed two Luna passes for {len(records)} records")


def split_paths(value):
    return {part.strip() for part in (value or "").split(";") if part.strip()}


def evaluate_luna():
    records = read_csv(QUEUE)
    historical = {r["record_id"]: split_paths(r["historical_pathways_not_gold"]) for r in read_csv(OUT / "historical_context_not_gold.csv")}
    assignments, reasons = {}, {}
    for pass_name in ("a", "b"):
        assignments[pass_name], reasons[pass_name] = {}, {}
        for row in read_csv(OUT / f"luna_{pass_name}" / "topic_assignments.csv"):
            assignments[pass_name].setdefault(row["record_id"], {})[row["path_id"]] = row["role"]
            reasons[pass_name].setdefault(row["record_id"], {})[row["path_id"]] = row["reason"]
    review = []
    exact = full = tp = fp = fn = 0
    jaccards = []
    for row in records:
        rid = row["record_id"]
        a, b = assignments["a"].get(rid, {}), assignments["b"].get(rid, {})
        aset, bset = set(a), set(b)
        exact += aset == bset
        full += a == b
        tp += len(aset & bset); fp += len(bset - aset); fn += len(aset - bset)
        jaccards.append(len(aset & bset) / len(aset | bset) if aset | bset else 1.0)
        review.append({
            "record_id": rid, "title": row["title"], "abstract": row["abstract"],
            "historical_pathways_not_gold": "; ".join(sorted(historical[rid])),
            "luna_a_coding": "; ".join(f"{p}={a[p]}" for p in sorted(a)),
            "luna_b_coding": "; ".join(f"{p}={b[p]}" for p in sorted(b)),
            "a_b_pathway_exact": int(aset == bset), "a_only": "; ".join(sorted(aset - bset)),
            "b_only": "; ".join(sorted(bset - aset)),
            "role_disagreements": "; ".join(f"{p}:{a[p]}->{b[p]}" for p in sorted(aset & bset) if a[p] != b[p]),
            "luna_a_reasons": " | ".join(f"{p}: {reasons['a'].get(rid, {}).get(p, '')}" for p in sorted(a)),
            "luna_b_reasons": " | ".join(f"{p}: {reasons['b'].get(rid, {}).get(p, '')}" for p in sorted(b)),
        })
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    summary = {
        "records": len(records), "exact_pathway_matches": exact, "exact_pathway_agreement": exact / len(records),
        "mean_jaccard": sum(jaccards) / len(jaccards), "pathway_precision": precision,
        "pathway_recall": recall, "pathway_f1": 2 * precision * recall / (precision + recall),
        "exact_full_ranked_matches": full, "exact_full_ranked_agreement": full / len(records),
        "pathway_disagreements": len(records) - exact,
    }
    write_csv(OUT / "validation_review_queue.csv", review, list(review[0]))
    (OUT / "validation_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


def run_terra():
    review = [r for r in read_csv(OUT / "validation_review_queue.csv") if r["a_b_pathway_exact"] == "0"]
    ontology = read_csv(ONTOLOGY)
    stable_prefix = "\n".join([
        "You are adjudicating conflicts between two independent Luna topic-classification passes for a salmon-aquaculture evidence map.",
        "Assess the title and abstract against the supplied ontology.",
        "Neither Luna pass is presumed correct. Do not select a pass wholesale and do not automatically take the union.",
        "Evaluate every proposed pathway independently and add a pathway missed by both passes if the record and ontology require it.",
        "Assign only pathways that represent substantive research questions, interventions, outcomes or conclusions.",
        "Exclude background concepts, incidental measurements and routine endpoints.",
        "A pathway labelled General is an exclusive fallback: do not assign it when a more specific sibling pathway applies.",
        "Historical coding and human final decisions are deliberately withheld.",
        "Return the final pathway IDs, one concise evidence-based rationale, and a review flag.",
        "\nFULL ONTOLOGY\n\n" + ontology_prompt(ontology),
    ])
    schema = {
        "type": "object", "properties": {
            "final_path_ids": {"type": "array", "items": {"type": "string", "enum": [r["path_id"] for r in ontology]}},
            "rationale": {"type": "string"}, "review_required": {"type": "boolean"},
            "review_reason": {"type": ["string", "null"]},
        }, "required": ["final_path_ids", "rationale", "review_required", "review_reason"], "additionalProperties": False,
    }
    input_path = OUT / "terra_batch_input.jsonl"
    with input_path.open("w", encoding="utf-8") as handle:
        for row in review:
            disputed = "; ".join(x for x in (row["a_only"], row["b_only"]) if x)
            dynamic = (
                f"RECORD\n\nRecord ID: {row['record_id']}\nTitle: {row['title']}\nAbstract: {row['abstract']}"
                f"\n\nLUNA PASS A\nAssignments: {row['luna_a_coding']}\nReasons: {row['luna_a_reasons']}"
                f"\n\nLUNA PASS B\nAssignments: {row['luna_b_coding']}\nReasons: {row['luna_b_reasons']}"
                f"\n\nDisputed pathway IDs: {disputed}\n\nAdjudicate the final pathway set."
            )
            body = {
                "model": TERRA_MODEL, "store": False, "reasoning": {"effort": "medium"},
                "prompt_cache_key": "topic-v3.4-cost-test-terra",
                "prompt_cache_options": {"mode": "explicit", "ttl": "30m"},
                "input": [
                    {"role": "system", "content": [{"type": "input_text", "text": stable_prefix,
                        "prompt_cache_breakpoint": {"mode": "explicit"}}]},
                    {"role": "user", "content": [{"type": "input_text", "text": dynamic}]},
                ],
                "text": {"verbosity": "low", "format": {"type": "json_schema", "name": "topic_conflict_adjudication", "strict": True, "schema": schema}},
            }
            request = {"custom_id": f"terra-{row['record_id']}", "method": "POST", "url": "/v1/responses", "body": body}
            handle.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
    if not review:
        write_csv(OUT / "terra_conflict_adjudication.csv", [], ["record_id", "terra_final_pathways", "terra_rationale", "terra_review_required", "terra_review_reason"])
        write_csv(OUT / "terra_usage.csv", [], ["stage", "custom_id", "model", "input_tokens", "ordinary_input_tokens", "cached_input_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "estimated_batch_cost_usd"])
        return
    results = submit_and_wait(input_path, "terra")
    rows, usage_rows = [], []
    review_by_id = {r["record_id"]: r for r in review}
    for item in results:
        record_id = item["custom_id"].split("-", 1)[1]
        response = (item.get("response") or {}).get("body")
        if not response or item.get("error"):
            raise RuntimeError(f"Terra batch failure for {record_id}: {item.get('error')}")
        usage_rows.append(usage_row("terra", item["custom_id"], TERRA_MODEL, response))
        parsed = json.loads(extract_output_text(response))
        source = review_by_id[record_id]
        rows.append({
            "record_id": record_id, "title": source["title"],
            "disputed_path_ids": "; ".join(x for x in (source["a_only"], source["b_only"]) if x),
            "luna_a_coding": source["luna_a_coding"], "luna_b_coding": source["luna_b_coding"],
            "terra_final_pathways": "; ".join(parsed["final_path_ids"]), "terra_rationale": parsed["rationale"],
            "terra_review_required": parsed["review_required"], "terra_review_reason": parsed["review_reason"] or "",
        })
    write_csv(OUT / "terra_conflict_adjudication.csv", rows, list(rows[0]))
    write_csv(OUT / "terra_usage.csv", usage_rows, list(usage_rows[0]))
    print(f"Completed Terra adjudication for {len(rows)} disagreements")


def summarise_cost():
    usage = []
    for name in ("luna_usage.csv", "terra_usage.csv"):
        usage.extend(read_csv(OUT / name))
    totals = {}
    for row in usage:
        stage = row["stage"]
        target = totals.setdefault(stage, {"requests": 0, "input_tokens": 0, "ordinary_input_tokens": 0,
            "cached_input_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})
        target["requests"] += 1
        for field in ("input_tokens", "ordinary_input_tokens", "cached_input_tokens", "cache_write_tokens", "output_tokens"):
            target[field] += int(row[field])
        target["cost_usd"] += float(row["estimated_batch_cost_usd"])
    total_cost = sum(x["cost_usd"] for x in totals.values())
    summary = {
        "pricing_basis": "OpenAI Batch API prices per 1M tokens verified 2026-09-18",
        "prices_usd_per_million": PRICES, "by_stage": totals, "total_cost_usd": total_cost,
        "cost_per_source_record_usd": total_cost / SAMPLE_SIZE,
        "projected_14738_record_cost_usd": total_cost / SAMPLE_SIZE * 14738,
        "projection_assumption": "The 100-record test is representative of abstract length, output length, cache performance and pathway-disagreement rate.",
    }
    (OUT / "cost_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2 or sys.argv[1] not in {"build", "luna", "evaluate", "terra", "summary"}:
        raise SystemExit("Usage: run_topic_batch_cost_test.py build|luna|evaluate|terra|summary")
    {"build": build_queue, "luna": run_luna, "evaluate": evaluate_luna,
     "terra": run_terra, "summary": summarise_cost}[sys.argv[1]]()
