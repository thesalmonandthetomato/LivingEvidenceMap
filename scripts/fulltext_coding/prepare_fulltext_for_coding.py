#!/usr/bin/env python3
"""Prepare GROBID TEI/XML (including HTML-wrapped TEI) for full-text coding."""
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
    sections=[]
    for div in root.iter():
        if local_name(div.tag) != "div": continue
        head=next((x for x in div if local_name(x.tag) in ("head","title")),None)
        heading=clean_text(" ".join(head.itertext())) if head is not None else ""
        paragraphs=[]
        for p in div.iter():
            if local_name(p.tag) != "p": continue
            txt=clean_text(" ".join(p.itertext()))
            if txt: paragraphs.append(txt)
        if paragraphs: sections.append({"section":heading or "unlabelled","text":"\n\n".join(paragraphs)})
    return sections

def prepare(path: Path) -> dict:
    root=ET.parse(path).getroot()
    title_el=first_element(root,("title",))
    title=clean_text(" ".join(title_el.itertext())) if title_el is not None else None
    tei=first_element(root,("TEI","tei")) or root
    sections=collect_divisions(tei)
    if not sections:
        paragraphs=[]
        for p in tei.iter():
            if local_name(p.tag)=="p":
                txt=clean_text(" ".join(p.itertext()))
                if txt: paragraphs.append(txt)
        if paragraphs: sections=[{"section":"unlabelled","text":"\n\n".join(paragraphs)}]
    if not sections:
        raise ValueError(f"No usable article text extracted from {path.name}; refusing to send empty content to the model")
    methods=[]; results=[]; intro_paragraphs=[]
    for sec in sections:
        h=sec["section"].lower()
        if any(k in h for k in ("method","material","study area","experimental","sampling","statistical")): methods.append(sec)
        if any(k in h for k in ("result","finding")): results.append(sec)
        if any(k in h for k in ("introduction","background","objective","aim")):
            intro_paragraphs.extend(p.strip() for p in sec["text"].split("\n\n") if p.strip())
    intro_tail_text="\n\n".join(intro_paragraphs[-2:]) if intro_paragraphs else ""
    intro_tail=[{"section":"final_introduction_objectives_paragraphs","text":intro_tail_text}] if intro_tail_text else []
    return {"source_file":str(path),"title":title,"sections":sections,"preferred_evidence":{"methods":methods,"results":results,"introduction_tail":intro_tail},"preparation_diagnostics":{"section_count":len(sections),"methods_section_count":len(methods),"results_section_count":len(results),"introduction_tail_paragraph_count":min(2,len(intro_paragraphs)),"text_character_count":sum(len(s["text"]) for s in sections)}}

def main()->int:
    p=argparse.ArgumentParser(); p.add_argument("--input",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args(); d=prepare(a.input); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding="utf-8"); return 0
if __name__=="__main__": raise SystemExit(main())
