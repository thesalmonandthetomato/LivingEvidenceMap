#!/usr/bin/env python3
"""OpenAlex-only batch runner.

This deliberately imports the downloader's OpenAlex functions but does not
invoke its Zenodo mode. Zenodo credentials are therefore never required for
OpenAlex harvesting.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

from download_openalex_fulltext import batch_context, build_plan, download_batch

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "openalex_fulltext")
    args = parser.parse_args()

    if not os.environ.get("OPENALEX_API_KEY", "").strip():
        raise RuntimeError("OPENALEX_API_KEY is not set")

    plan = build_plan()
    total_batches, start, end, _, part = batch_context(plan, args.batch)
    batch_dir = args.output / f"batch_{args.batch}"
    batch_dir.mkdir(parents=True, exist_ok=True)

    print(f"OpenAlex full-text plan: {len(plan)} files in {total_batches} batches", flush=True)
    print(f"Batch {args.batch}/{total_batches}: files {start + 1}-{end}", flush=True)
    print("GROBID-first; PDF-only fallback; maximum 100 OpenAlex content downloads", flush=True)
    print(f"Zenodo storage is a separate downstream stage (private draft part {part})", flush=True)

    return download_batch(plan, args.batch, batch_dir)


if __name__ == "__main__":
    raise SystemExit(main())
