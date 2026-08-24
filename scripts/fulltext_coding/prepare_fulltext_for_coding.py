#!/usr/bin/env python3
"""Prepare GROBID TEI XML into compact, section-aware text for coding.

Fails closed when usable article text cannot be extracted: an empty intermediary
must never be sent to a paid model. Namespace handling is tolerant of TEI/XML
variants produced by different GROBID/OpenAlex records.
"""
from __future__ import annotations
import argparse, json, re, xml.etree.ElementTree as ET
from pathlib import Path


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def clean_text(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def first_element(root: ET.Element, names: tuple[str, ...]) -> ET.Element | None:
    for el in root.iter():
        if local_name(el.tag) in names:
            return el
    return None


def collect_divisions(root: ET.Element) -> list[dict]:
    sections: list[dict] = []
    for div in root.iter():
        if local_name(div.tag) != "div":
            continue
        head = next((x for x in div if local_name(x.tag) == "head"), None)
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
    title_el = first_element(root, ("title",))
    title = clean_text(" ".join(title_el.itertext())) if title_el is not None else None
    sections = collect_divisions(root)

    # Some GROBID records have usable paragraphs but no <div> structure.
    if not sections:
        paragraphs = []
        for p in root.iter():
            if local_name(p.tag) == "p":
                txt = clean_text(" ".join(p.itertext()))
                if txt:
                    paragraphs.append(txt)
        if paragraphs:
            sections = [{"section": "unlabelled", "text": "\n\n".join(paragraphs)}]

    if not sections:
        raise ValueError(f"No usable article text extracted from {path.name}; refusing to send empty content to the model")

    methods, results, intro_tail = [], [], []
    for sec in sections:
        heading = sec["section"].lower()
        if any(k in heading for k in ("method", "material", "study area", "experimental", "sampling", "statistical")):
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
        "preferred_evidence": {"methods": methods, "results": results, "introduction_tail": intro_tail[-2:]},
        "preparation_diagnostics": {
            "section_count": len(sections),
            "methods_section_count": len(methods),
            "results_section_count": len(results),
            "introduction_tail_count": len(intro_tail[-2:]),
            "text_character_count": sum(len(s["text"]) for s in sections),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); parser.add_argument("--output", type=Path, required=True); args = parser.parse_args()
    data = prepare(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0

if __name__ == "__main__": raise SystemExit(main())
