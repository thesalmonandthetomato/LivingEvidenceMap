#!/usr/bin/env python3
"""Select a small reproducible test set of existing GROBID full texts.

This script does not call an LLM. It identifies candidate TEI files for manual
or downstream coding tests and writes a deterministic manifest.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--n", type=int, default=10)
    args = parser.parse_args()

    files = sorted(args.input_dir.rglob("*.tei.xml"))
    if not files:
        raise RuntimeError(f"No GROBID TEI XML files found under {args.input_dir}")
    selected = files[: args.n]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["source_file", "openalex_id"])
        writer.writeheader()
        for path in selected:
            writer.writerow({"source_file": str(path), "openalex_id": path.name.removesuffix(".tei.xml")})

    print(json.dumps({"available": len(files), "selected": len(selected), "manifest": str(args.output)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
