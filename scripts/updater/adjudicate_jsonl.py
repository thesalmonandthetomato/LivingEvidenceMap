#!/usr/bin/env python3
"""Workflow 03: adjudicate residual duplicate candidates with full provenance."""
import argparse, json, os
from datetime import datetime, timezone
from pathlib import Path

DECISIONS = {"duplicate", "not_duplicate", "uncertain"}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def adjudication_schema():
    return {
        "type": "object",
        "properties": {
            "decision": {"type": "string", "enum": ["duplicate", "not_duplicate", "uncertain"]},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "rationale": {"type": "string"},
        },
        "required": ["decision", "confidence", "rationale"],
        "additionalProperties": False,
    }


def system_prompt():
    return (
        "You adjudicate whether two bibliographic records represent the same publication. "
        "Use the supplied evidence. DOI is supporting evidence only and may be wrong. "
        "Never treat lens_id as duplicate evidence. If evidence is insufficient or conflicting, return uncertain."
    )


def build_request(candidate, model):
    return {
        "model": model,
        "input": [
            {"role": "system", "content": system_prompt()},
            {"role": "user", "content": json.dumps(candidate, ensure_ascii=False, sort_keys=True)},
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "duplicate_adjudication",
                "strict": True,
                "schema": adjudication_schema(),
            }
        },
    }


def safe_model_dump(value):
    if value is None:
        return None
    if hasattr(value, "model_dump"):
        try:
            return value.model_dump(mode="json")
        except TypeError:
            return value.model_dump()
    if isinstance(value, (dict, list, str, int, float, bool)):
        return value
    return str(value)


def mock_adjudication(candidate, model):
    if candidate.get("duplicate_basis") == "doi_conflict_review":
        parsed = {
            "decision": "uncertain",
            "confidence": 0.5,
            "rationale": "Mock mode: DOI conflict requires adjudication and is not auto-resolved.",
        }
    else:
        parsed = {
            "decision": "uncertain",
            "confidence": 0.0,
            "rationale": "Mock mode: no production adjudication performed.",
        }
    return parsed, {
        "request": build_request(candidate, model),
        "response_id": None,
        "resolved_model": None,
        "usage": None,
        "raw_response": None,
        "parsed_response": parsed,
    }


def openai_adjudication(candidate, model):
    from openai import OpenAI

    client = OpenAI()
    request = build_request(candidate, model)
    response = client.responses.create(**request)
    parsed = json.loads(response.output_text)
    provenance = {
        "request": request,
        "response_id": getattr(response, "id", None),
        "resolved_model": getattr(response, "model", None),
        "usage": safe_model_dump(getattr(response, "usage", None)),
        "raw_response": safe_model_dump(response),
        "parsed_response": parsed,
    }
    return parsed, provenance


def validate_result(result):
    if result["decision"] not in DECISIONS:
        raise ValueError("Invalid adjudication decision")
    if not isinstance(result["confidence"], (int, float)) or not 0 <= result["confidence"] <= 1:
        raise ValueError("Invalid adjudication confidence")
    if not isinstance(result["rationale"], str) or not result["rationale"]:
        raise ValueError("Empty adjudication rationale")


def adjudicate(candidate, mode, model):
    started_at = utc_now()
    request = build_request(candidate, model)
    try:
        result, provenance = (
            mock_adjudication(candidate, model)
            if mode == "mock"
            else openai_adjudication(candidate, model)
        )
        validate_result(result)
        error = None
    except Exception as exc:
        result = {
            "decision": "uncertain",
            "confidence": 0.0,
            "rationale": "Adjudication failed; human review required.",
        }
        provenance = {
            "request": request,
            "response_id": None,
            "resolved_model": None,
            "usage": None,
            "raw_response": None,
            "parsed_response": None,
        }
        error = type(exc).__name__ + ": " + str(exc)

    provenance.update(
        {
            "requested_model": model if mode == "openai" else None,
            "mode": mode,
            "started_at": started_at,
            "completed_at": utc_now(),
            "adjudication_error": error,
        }
    )
    return result, provenance


def run(input_path, output_path, audit_path, mode, model):
    candidates = [
        json.loads(x)
        for x in input_path.read_text(encoding="utf-8").splitlines()
        if x.strip()
    ]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    audit_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as out, audit_path.open("w", encoding="utf-8") as audit:
        for candidate in candidates:
            result, provenance = adjudicate(candidate, mode, model)

            # Preserve every upstream candidate field rather than reducing the record.
            record = dict(candidate)
            record.update(
                {
                    "workflow": "03_adjudication",
                    "decision": result["decision"],
                    "confidence": result["confidence"],
                    "rationale": result["rationale"],
                    "mode": mode,
                    "model": model if mode == "openai" else None,
                    "resolved_model": provenance.get("resolved_model"),
                    "response_id": provenance.get("response_id"),
                    "usage": provenance.get("usage"),
                    "adjudication_error": provenance.get("adjudication_error"),
                    "created_at": provenance["completed_at"],
                }
            )

            # Audit is the authoritative trace: exact candidate, exact API request,
            # parsed decision and the complete serialisable API response.
            audit_record = {
                "workflow": "03_adjudication",
                "candidate_id": candidate.get("candidate_id"),
                "candidate_evidence": candidate,
                "decision_record": record,
                "adjudication_provenance": provenance,
            }

            out.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            audit.write(json.dumps(audit_record, ensure_ascii=False, separators=(",", ":")) + "\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--audit", required=True)
    p.add_argument("--mode", choices=["mock", "openai"], default="mock")
    p.add_argument("--model", default="gpt-5-mini")
    a = p.parse_args()
    if a.mode == "openai" and not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("OPENAI_API_KEY is required for openai mode")
    run(Path(a.input), Path(a.output), Path(a.audit), a.mode, a.model)


if __name__ == "__main__":
    main()
