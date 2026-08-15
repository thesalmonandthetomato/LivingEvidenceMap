#!/usr/bin/env python3
"""Convert a Lens scholarly JSON harvest to the RIS input expected by the update pipeline."""
import json, sys
from pathlib import Path

def text(v):
    if v is None: return ""
    if isinstance(v, str): return v.strip()
    return str(v).strip()

def first_doi(rec):
    v = rec.get("doi")
    if text(v): return text(v)
    ids = rec.get("external_ids") or []
    if isinstance(ids, dict): ids = [ids]
    for item in ids:
        if isinstance(item, dict):
            for k in ("doi", "DOI"):
                if text(item.get(k)): return text(item[k])
        elif isinstance(item, str) and item.lower().startswith("10."):
            return item
    return ""

def authors(rec):
    v = rec.get("authors") or rec.get("author") or []
    if isinstance(v, str): return [v]
    out=[]
    for a in v if isinstance(v, list) else []:
        if isinstance(a, dict):
            name = a.get("display_name") or a.get("name") or a.get("full_name")
        else: name = a
        if text(name): out.append(text(name))
    return out

def main(src, dst):
    records = json.loads(Path(src).read_text(encoding="utf-8"))
    with Path(dst).open("w", encoding="utf-8", newline="") as f:
        for i, r in enumerate(records, 1):
            f.write("TY  - JOUR\n")
            f.write(f"ID  - {text(r.get('lens_id')) or i}\n")
            if text(r.get("title")): f.write(f"TI  - {text(r['title'])}\n")
            if text(r.get("abstract")): f.write(f"AB  - {text(r['abstract'])}\n")
            doi = first_doi(r)
            if doi: f.write(f"DO  - {doi}\n")
            if text(r.get("date_published")): f.write(f"PY  - {text(r['date_published'])[:4]}\n")
            elif text(r.get("year_published")): f.write(f"PY  - {text(r['year_published'])}\n")
            for a in authors(r): f.write(f"AU  - {a}\n")
            if text(r.get("journal")): f.write(f"T2  - {text(r['journal'])}\n")
            if text(r.get("url")): f.write(f"UR  - {text(r['url'])}\n")
            f.write("ER  -\n\n")
    print(f"Wrote {len(records)} RIS records to {dst}")

if __name__ == "__main__":
    if len(sys.argv) != 3: raise SystemExit("Usage: lens_json_to_ris.py INPUT.json OUTPUT.ris")
    main(sys.argv[1], sys.argv[2])
