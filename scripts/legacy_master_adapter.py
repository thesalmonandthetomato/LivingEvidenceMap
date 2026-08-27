#!/usr/bin/env python3
"""Convert the current master CSV to a lossless deduplication JSONL view.

This is an adapter, not a migration of the master data. Every CSV row is
retained verbatim under ``raw_csv`` and a small canonical bibliographic view
is added for JSON-native deduplication. Missing historical information remains
missing; the adapter never reconstructs Lens fields or historical decisions.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

ALIASES = {
    "record_id": ["record_id", "id", "item_id", "study_id", "reference_id"],
    "lens_id": ["lens_id", "lens id", "lensid"],
    "title": ["title", "article_title", "publication_title"],
    "authors": ["authors", "author", "author_list"],
    "year": ["year", "publication_year", "published_year", "date_year"],
    "source": ["source", "journal", "journal_title", "publication_source", "container_title"],
    "doi": ["doi", "doi_url", "digital_object_identifier"],
    "abstract": ["abstract", "abstract_text", "summary"],
}


def key(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")


def resolve_headers(headers: list[str]) -> dict[str, str | None]:
    keyed = {key(h): h for h in headers}
    resolved: dict[str, str | None] = {}
    for canonical, candidates in ALIASES.items():
        resolved[canonical] = next((keyed[key(c)] for c in candidates if key(c) in keyed), None)
    return resolved


def value(row: dict[str, str], column: str | None) -> str | None:
    if not column:
        return None
    raw = row.get(column)
    if raw is None:
        return None
    raw = raw.strip()
    return raw or None


def convert(input_csv: Path, output_jsonl: Path) -> dict:
    count = 0
    headers: list[str] = []
    mapping: dict[str, str | None] = {}

    with input_csv.open("r", encoding="utf-8-sig", newline="") as src, output_jsonl.open("w", encoding="utf-8", newline="\n") as dst:
        reader = csv.DictReader(src)
        headers = reader.fieldnames or []
        mapping = resolve_headers(headers)

        for row_number, row in enumerate(reader, start=1):
            # Keep the complete historical row exactly as parsed from CSV.
            record = {
                "schema": "legacy_master_adapter/v1",
                "legacy_row_number": row_number,
                "canonical": {
                    "record_id": value(row, mapping["record_id"]),
                    "lens_id": value(row, mapping["lens_id"]),
                    "title": value(row, mapping["title"]),
                    "authors": value(row, mapping["authors"]),
                    "year": value(row, mapping["year"]),
                    "source": value(row, mapping["source"]),
                    "doi": value(row, mapping["doi"]),
                    "abstract": value(row, mapping["abstract"]),
                },
                "provenance": {
                    "source": "current_master_csv",
                    "source_file": input_csv.name,
                    "row_number": row_number,
                    "field_mapping": mapping,
                },
                "raw_csv": row,
            }
            dst.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1

    return {"rows": count, "headers": headers, "field_mapping": mapping}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    summary = convert(args.input, args.output)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
