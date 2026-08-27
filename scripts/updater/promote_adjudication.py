#!/usr/bin/env python3
"""Apply the Workflow 03 promotion gate to adjudication decisions."""
import argparse, json
from pathlib import Path

ALLOWED = {"duplicate", "not_duplicate", "uncertain"}
DEFAULT_THRESHOLD = 0.80


def promote(record, threshold=DEFAULT_THRESHOLD):
    decision = record.get("decision")
    confidence = record.get("confidence")
    technical_error = record.get("technical_error")
    if technical_error:
        return "human_review", "technical_failure"
    if decision not in ALLOWED:
        return "human_review", "invalid_decision"
    if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        return "human_review", "invalid_confidence"
    if decision == "uncertain":
        return "human_review", "model_uncertain"
    if confidence < threshold:
        return "human_review", "below_confidence_threshold"
    return decision, "promoted"


def run(inp, out, threshold):
    rows = [json.loads(x) for x in Path(inp).read_text(encoding="utf-8").splitlines() if x.strip()]
    with Path(out).open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            promoted, reason = promote(row, threshold)
            result = dict(row)
            result["promotion"] = promoted
            result["promotion_reason"] = reason
            result["promotion_threshold"] = threshold
            f.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    a = p.parse_args()
    run(a.input, a.output, a.threshold)
