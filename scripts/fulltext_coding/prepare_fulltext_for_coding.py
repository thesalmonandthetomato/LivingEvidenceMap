#!/usr/bin/env python3
"""Prepare GROBID TEI XML into compact, section-aware text for coding.

The preparation step preserves source section labels and page information where
available, and writes a JSON intermediary for the coding step. It does not
modify the source XML.
"""
from __future__ import annotations

import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

TEI_NS = {"tei": "http://www.tei-c.org/ns/1.0"}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def clean_text(text: str) -> str:
    text = re.sub(r"\s+", " ", text or "")
    return text.strip()


def collect_divisions(root: ET.Element) -> list[dict]:
    sections: list[dict] = []
    body = root.find(".//tei:text/tei:body", TEI_NS)
    if body is None:
        return sections

    for div in body.iter():
        if local_name(div.tag) != "div":
            continue
        head = div.find("tei:head", TEI_NS)
        heading = clean_text(" ".join(head.itertext())) if head is not None else ""
        paragraphs = []
        for p in div.iter():
            if local_name(p.tag) != "p":
                continue
            txt = clean_text(" ".join(p.itertext()))
            if txt:
                paragraphs.append(txt)
        if paragraphs:
            sections.append({"section": heading or "unlabelled", "text": "\n\n".join(paragraphs)})
    return sections


def prepare(path: Path) -> dict:
    root = ET.parse(path).getroot()
    title_el = root.find(".//tei:titleStmt/tei:title", TEI_NS)
    title = clean_text(" ".join(title_el.itertext())) if title_el is not None else None
    sections = collect_divisions(root)
    methods = []
    results = []
    intro_tail = []
    for sec in sections:
        heading = sec["section"].lower()
        if any(k in heading for k in ("method", "material", "study area", "experimental")):
            methods.append(sec)
        if any(k in heading for k in ("result", "finding")):
            results.append(sec)
        if any(k in heading for k in ("introduction", "background", "objective", "aim")):
            paras = [p.strip() for p in sec["text"].split("\n\n") if p.strip()]
            intro_tail.append({"section": sec["section"], "text": "\n\n".join(paras[-2:])})

    if not methods:
        methods = [s for s in sections if "method" in s["text"].lower()][:3]
    if not results:
        results = [s for s in sections if "result" in s["text"].lower()][:3]

    return {
        "source_file": str(path),
        "title": title,
        "sections": sections,
        "preferred_evidence": {
            "methods": methods,
            "results": results,
            "introduction_tail": intro_tail[-2:],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = prepare(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
