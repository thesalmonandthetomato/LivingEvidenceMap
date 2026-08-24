#!/usr/bin/env python3
"""Code prepared full texts with an OpenAI-compatible chat API.

This is deliberately a small, auditable test runner. It writes one JSON
annotation per paper and records the schema/ontology/prompt versions used.
No source files are modified.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from urllib.request import Request, urlopen

DEFAULT_MODEL = os.getenv("FULLTEXT_CODING_MODEL", "gpt-5.6-mini")


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def call_api(base_url: str, api_key: str, model: str, system: str, user: str) -> dict:
    payload = {
        "model": model,
        "input": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "text": {"format": {"type": "json_object"}},
    }
    req = Request(
        base_url.rstrip("/") + "/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(req, timeout=300) as response:
        return json.load(response)


def response_text(data: dict) -> str:
    if data.get("output_text"):
        return data["output_text"]
    parts = []
    for item in data.get("output", []):
        for content in item.get("content", []):
            if isinstance(content, dict) and content.get("type") == "output_text":
                parts.append(content.get("text", ""))
    return "\n".join(parts)


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
    system = args.prompt.read_text(encoding="utf-8")
    ontology = args.ontology.read_text(encoding="utf-8")
    schema = load(args.schema)

    files = sorted(args.input_dir.glob("*.json"))[: args.max_papers]
    if not files:
        raise SystemExit("No prepared JSON files found")

    for i, path in enumerate(files, 1):
        out = args.output_dir / path.name
        if out.exists():
            print(f"[{i}/{len(files)}] EXISTS {out.name}", flush=True)
            continue
        prepared = load(path)
        user = (
            "Code this article according to the supplied schema and ontology. "
            "Return JSON only. Cite concise evidence for substantive extracted fields.\n\n"
            "CODING SCHEMA:\n" + json.dumps(schema, ensure_ascii=False, indent=2) +
            "\n\nONTOLOGY CSV:\n" + ontology +
            "\n\nPREPARED ARTICLE:\n" + json.dumps(prepared, ensure_ascii=False)
        )
        print(f"[{i}/{len(files)}] CODING {path.name}", flush=True)
        last = None
        for attempt in range(4):
            try:
                data = call_api(base, key, args.model, system, user)
                text = response_text(data)
                annotation = json.loads(text)
                annotation["_run_metadata"] = {
                    "model": args.model,
                    "schema": str(args.schema),
                    "ontology": str(args.ontology),
                    "prompt": str(args.prompt),
                    "source_prepared_file": path.name,
                }
                out.write_text(json.dumps(annotation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                break
            except Exception as exc:
                last = exc
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)
        else:
            raise last
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
