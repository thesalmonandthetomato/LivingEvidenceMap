#!/usr/bin/env python3
"""Code prepared full texts with the OpenAI Responses API.

HARD RULE: every successful model response is checkpointed to durable output
before any validation or subsequent processing. Existing checkpoints are never
re-submitted to the model. A validation failure must never cause paid work to
be repeated.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_MODEL = os.getenv("FULLTEXT_CODING_MODEL", "gpt-5.6-luna")
CHECKPOINT_RULE = (
    "PAID CONTENT CHECKPOINT RULE: After every successful model response, "
    "write the raw model response and annotation to the per-paper output "
    "directory immediately, before validation, merging, or any other step. "
    "Never re-call the model when a checkpoint exists."
)


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def call_api(base_url: str, api_key: str, model: str, system: str, user: str) -> dict:
    payload = {
        "model": model,
        "input": [
            {"role": "system", "content": [{"type": "input_text", "text": system}]},
            {"role": "user", "content": [{"type": "input_text", "text": user}]},
        ],
    }
    req = Request(
        base_url.rstrip("/") + "/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urlopen(req, timeout=300) as response:
            return json.load(response)
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI API HTTP {exc.code}: {body}") from exc
    except URLError as exc:
        raise RuntimeError(f"OpenAI API connection error: {exc}") from exc


def response_text(data: dict) -> str:
    if data.get("output_text"):
        return data["output_text"]
    parts = []
    for item in data.get("output", []):
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") == "output_text":
                parts.append(content.get("text", ""))
    return "\n".join(parts).strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input-dir", type=Path, required=True)
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--ontology", type=Path, required=True)
    ap.add_argument("--schema", type=Path, required=True)
    ap.add_argument("--prompt", type=Path, required=True)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--max-papers", type=int, default=5)
    args = ap.parse_args()

    key = os.environ["OPENAI_API_KEY"]
    base = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    system = args.prompt.read_text(encoding="utf-8") + "\n\n" + CHECKPOINT_RULE
    ontology = args.ontology.read_text(encoding="utf-8")
    schema = load(args.schema)

    files = sorted(args.input_dir.glob("*.json"))[: args.max_papers]
    if not files:
        raise SystemExit("No prepared JSON files found")

    for i, path in enumerate(files, 1):
        out = args.output_dir / path.name
        raw_out = args.output_dir / (path.stem + ".raw_response.json")
        status_out = args.output_dir / (path.stem + ".checkpoint.json")
        if out.exists() and raw_out.exists() and status_out.exists():
            print(f"[{i}/{len(files)}] CHECKPOINT EXISTS {out.name}; skipping model call", flush=True)
            continue

        prepared = load(path)
        user = (
            "Code this article according to the supplied schema and ontology. "
            "Return a single valid JSON object only. Do not wrap it in markdown. "
            "Cite concise evidence for substantive extracted fields.\n\n"
            "CODING SCHEMA:\n" + json.dumps(schema, ensure_ascii=False, indent=2)
            + "\n\nONTOLOGY CSV:\n" + ontology
            + "\n\nPREPARED ARTICLE:\n" + json.dumps(prepared, ensure_ascii=False)
        )
        print(f"[{i}/{len(files)}] CODING {path.name}", flush=True)
        last = None
        for attempt in range(4):
            try:
                data = call_api(base, key, args.model, system, user)
                text = response_text(data)
                if not text:
                    raise RuntimeError("OpenAI API returned no output text")

                # HARD CHECKPOINT: durable writes happen BEFORE validation.
                raw_out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                annotation = json.loads(text)
                annotation["run_metadata"] = {
                    "model": args.model,
                    "schema": str(args.schema),
                    "ontology": str(args.ontology),
                    "prompt": str(args.prompt),
                    "source_prepared_file": path.name,
                    "checkpoint_status": "generated",
                }
                out.write_text(json.dumps(annotation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                status_out.write_text(json.dumps({
                    "source_prepared_file": path.name,
                    "annotation_file": out.name,
                    "raw_response_file": raw_out.name,
                    "status": "generated",
                    "checkpoint_rule": "checkpoint_before_validation",
                }, indent=2) + "\n", encoding="utf-8")
                print(f"  CHECKPOINTED {out.name} before validation", flush=True)
                break
            except json.JSONDecodeError as exc:
                # A successful API response is still checkpointed above before parsing;
                # do not retry it merely because downstream JSON parsing/validation fails.
                raise RuntimeError(f"Model response checkpointed but was not valid JSON: {exc}") from exc
            except Exception as exc:
                last = exc
                print(f"  attempt {attempt + 1}/4 failed before successful response: {exc}", flush=True)
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)
        else:
            raise last
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
