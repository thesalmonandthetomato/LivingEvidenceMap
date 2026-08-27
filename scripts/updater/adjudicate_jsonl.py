#!/usr/bin/env python3
"""Workflow 03: adjudicate residual duplicate candidates.

The first implementation is deliberately deterministic/testable. It accepts
Workflow 02 candidate records and produces one immutable decision record per
candidate. Real model invocation is enabled later without changing the I/O
contract.
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DECISIONS = {"duplicate", "not_duplicate", "uncertain"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def mock_adjudication(candidate: dict[str, Any]) -> dict[str, Any]:
    """Deterministic test adapter; never used as a production decision."""
    basis = candidate.get("duplicate_basis", "")
    if basis == "doi_conflict_review":
        return {
            "decision": "uncertain",
            "confidence": 0.5,
            "rationale": "Mock mode: DOI conflict requires adjudication and is not auto-resolved.",
        }
    return {
        "decision": "uncertain",
        "confidence": 0.0,
        "rationale": "Mock mode: no production adjudication performed.",
    }


def adjudicate(candidate: dict[str, Any], mode: str) -> dict[str, Any]:
    if mode != "mock":
        raise RuntimeError("Real model mode is not enabled in this incremental implementation")
    result = mock_adjudication(candidate)
    if result["decision"] not in DECISIONS:
        raise ValueError("Invalid adjudication decision")
    confidence = result["confidence"]
    if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        raise ValueError("Invalid adjudication confidence")
    if not isinstance(result["rationale"], str) or not result["rationale"]:
        raise ValueError("Empty adjudication rationale")
    return result


def run(input_path: Path, output_path: Path, audit_path: Path, mode: str) -> None:
    candidates = [json.loads(line) for line in input_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    decisions = []
    for candidate in candidates:
        result = adjudicate(candidate, mode)
        record = {
            "workflow": "03_adjudication",
            "candidate_id": candidate.get("candidate_id"),
            "incoming_record_id": candidate.get("incoming_record_id"),
            "matched_master_record_id": candidate.get("matched_master_record_id"),
            "duplicate_basis": candidate.get("duplicate_basis"),
            "title_similarity": candidate.get("title_similarity"),
            "decision": result["decision"],
            "confidence": result["confidence"],
            "rationale": result["rationale"],
            "mode": mode,
            "created_at": utc_now(),
        }
        decisions.append(record)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    audit_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="\n") as out, audit_path.open("w", encoding="utf-8", newline="\n") as audit:
        for record in decisions:
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            out.write(line + "\n")
            audit.write(line + "\n")

    if len(decisions) != len(candidates):
        raise RuntimeError("Adjudication count does not equal candidate count")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--audit", required=True)
    parser.add_argument("--mode", choices=["mock"], default="mock")
    args = parser.parse_args()
    run(Path(args.input), Path(args.output), Path(args.audit), args.mode)


if __name__ == "__main__":
    main()
