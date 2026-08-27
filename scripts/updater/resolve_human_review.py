#!/usr/bin/env python3
"""Resolve a human-review case as a new immutable JSONL record."""
import argparse, json
from datetime import datetime, timezone
from pathlib import Path

VALID = {"duplicate", "not_duplicate", "uncertain"}

def now():
    return datetime.now(timezone.utc).isoformat()

def resolve(queue_record, decision, rationale, reviewer):
    if decision not in VALID:
        raise ValueError("Human decision must be duplicate, not_duplicate, or uncertain")
    if not rationale.strip():
        raise ValueError("Human rationale is required")
    if not reviewer.strip():
        raise ValueError("Reviewer is required")
    result = dict(queue_record)
    result.update({
        "status": "resolved",
        "human_decision": decision,
        "human_rationale": rationale,
        "reviewer": reviewer,
        "resolved_at": now(),
    })
    return result

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--decision", required=True, choices=sorted(VALID))
    p.add_argument("--rationale", required=True)
    p.add_argument("--reviewer", required=True)
    a = p.parse_args()
    rows = [json.loads(x) for x in Path(a.input).read_text(encoding='utf-8').splitlines() if x.strip()]
    if len(rows) != 1:
        raise ValueError("Resolution input must contain exactly one review case")
    result = resolve(rows[0], a.decision, a.rationale, a.reviewer)
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    with Path(a.output).open('w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')

if __name__ == '__main__':
    main()
