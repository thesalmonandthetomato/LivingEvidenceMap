#!/usr/bin/env python3
"""Prepare GROBID TEI/XML (including HTML-wrapped or imperfect TEI) for coding.

The preparation layer is deliberately loss-tolerant: it first uses a normal XML
parse, then attempts to recover embedded TEI, and finally extracts readable XML/
HTML text when a wrapper is malformed. It never sends an empty article to the
LLM and records how the recovery was performed.
"""
from __future__ import annotations
import argparse, html, json, re, xml.etree.ElementTree as ET
from pathlib import Path


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def clean_text(text: str) -> str:
    text = html.unescape(text or "")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def first_element(root: ET.Element, names: tuple[str, ...]) -> ET.Element | None:
    for el in root.iter():
        if local_name(el.tag) in names:
            return el
    return None


def collect_divisions(root: ET.Element) -> list[dict]:
    sections=[]
    for div in root.iter():
        if local_name(div.tag) != "div":
            continue
        head=next((x for x in div if local_name(x.tag) in ("head","title")),None)
        heading=clean_text(" ".join(head.itertext())) if head is not None else ""
        paragraphs=[]
        for p in div.iter():
            if local_name(p.tag) != "p":
                continue
            txt=clean_text(" ".join(p.itertext()))
            if txt:
                paragraphs.append(txt)
        if paragraphs:
            sections.append({"section":heading or "unlabelled","text":"\n\n".join(paragraphs)})
    return sections


def collect_flat_text(root: ET.Element) -> list[dict]:
    paragraphs=[]
    for p in root.iter():
        if local_name(p.tag)=="p":
            txt=clean_text(" ".join(p.itertext()))
            if txt:
                paragraphs.append(txt)
    return [{"section":"unlabelled","text":"\n\n".join(paragraphs)}] if paragraphs else []


def parse_recoverable(raw: str) -> tuple[ET.Element, str]:
    try:
        return ET.fromstring(raw), "xml"
    except ET.ParseError as original:
        # Some GROBID exports are wrapped in HTML or contain an outer wrapper
        # around an otherwise valid TEI document. Recover the embedded <TEI>.
        match=re.search(r"<TEI(?:\s[^>]*)?>.*?</TEI>\s*$", raw, flags=re.I|re.S)
        if not match:
            match=re.search(r"<tei:TEI(?:\s[^>]*)?>.*?</tei:TEI>\s*$", raw, flags=re.I|re.S)
        if match:
            candidate=match.group(0)
            try:
                return ET.fromstring(candidate), "embedded_tei_recovery"
            except ET.ParseError:
                candidate=re.sub(r"<\?xml[^>]*\?>", "", candidate)
                try:
                    return ET.fromstring(candidate), "embedded_tei_recovery_no_declaration"
                except ET.ParseError:
                    pass
        raise original


def regex_recovery(raw: str) -> tuple[str, list[dict]]:
    """Last-resort readable-text recovery for malformed XML/HTML wrappers."""
    title_match=re.search(r"<(?:title|tei:title)[^>]*>(.*?)</(?:title|tei:title)>", raw, flags=re.I|re.S)
    title=clean_text(re.sub(r"<[^>]+>", " ", title_match.group(1))) if title_match else None
    blocks=[]
    for m in re.finditer(r"<(?:p|tei:p)[^>]*>(.*?)</(?:p|tei:p)>", raw, flags=re.I|re.S):
        txt=clean_text(re.sub(r"<[^>]+>", " ", m.group(1)))
        if txt:
            blocks.append(txt)
    if not blocks:
        # Strip tags only as a final fallback, retaining enough readable text
        # to allow the completeness gate to identify a genuinely unusable file.
        stripped=clean_text(re.sub(r"<[^>]+>", " ", raw))
        if stripped:
            blocks=[stripped]
    sections=[{"section":"unlabelled","text":"\n\n".join(blocks)}] if blocks else []
    return title, sections


def classify_sections(sections: list[dict]) -> tuple[list[dict],list[dict],list[str]]:
    methods=[]; results=[]; intro_paragraphs=[]
    for sec in sections:
        h=sec["section"].lower()
        if any(k in h for k in ("method","material","study area","experimental","sampling","statistical")):
            methods.append(sec)
        if any(k in h for k in ("result","finding")):
            results.append(sec)
        if any(k in h for k in ("introduction","background","objective","aim")):
            intro_paragraphs.extend(p.strip() for p in sec["text"].split("\n\n") if p.strip())
    return methods, results, intro_paragraphs


def prepare(path: Path) -> dict:
    raw=path.read_text(encoding="utf-8",errors="replace")
    recovery="xml"
    title=None
    sections=[]
    try:
        root,recovery=parse_recoverable(raw)
        title_el=first_element(root,("title",))
        title=clean_text(" ".join(title_el.itertext())) if title_el is not None else None
        tei=first_element(root,("TEI","tei")) or root
        sections=collect_divisions(tei)
        if not sections:
            sections=collect_flat_text(tei)
    except ET.ParseError:
        title,sections=regex_recovery(raw)
        recovery="regex_text_recovery"

    if not sections:
        raise ValueError(f"No usable article text extracted from {path.name}; refusing to send empty content to the model")

    methods,results,intro_paragraphs=classify_sections(sections)
    intro_tail_text="\n\n".join(intro_paragraphs[-2:]) if intro_paragraphs else ""
    intro_tail=[{"section":"final_introduction_objectives_paragraphs","text":intro_tail_text}] if intro_tail_text else []
    text_character_count=sum(len(s["text"]) for s in sections)
    return {
        "source_file":str(path),
        "title":title,
        "sections":sections,
        "preferred_evidence":{"methods":methods,"results":results,"introduction_tail":intro_tail},
        "preparation_diagnostics":{
            "section_count":len(sections),
            "methods_section_count":len(methods),
            "results_section_count":len(results),
            "introduction_tail_paragraph_count":min(2,len(intro_paragraphs)),
            "text_character_count":text_character_count,
            "recovery_mode":recovery,
            "source_bytes":len(raw.encode("utf-8")),
        },
    }


def main()->int:
    p=argparse.ArgumentParser(); p.add_argument("--input",type=Path,required=True); p.add_argument("--output",type=Path,required=True)
    a=p.parse_args(); d=prepare(a.input); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding="utf-8"); return 0

if __name__=="__main__": raise SystemExit(main())
