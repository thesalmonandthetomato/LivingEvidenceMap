#!/usr/bin/env python3
"""Convert a manually supplied RIS file into the common update JSON/CSV shape.

The source RIS remains the user's manually supplied input; this script only
creates a normalized update artifact. Downstream processing can then apply the
same deduplication and enrichment path as a Lens increment.
"""
import argparse, csv, json, re
from datetime import datetime, timezone
from pathlib import Path

TAG_RE = re.compile(r"^([A-Z0-9]{2})\s{0,2}[- ]\s?(.*)$")

def parse_ris(path):
    records, current = [], None
    last_tag = None
    for raw in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        line = raw.rstrip("\r\n")
        m = TAG_RE.match(line)
        if m:
            tag, value = m.groups()
            if tag == "TY":
                current = {"publication_type": value.strip(), "authors": [], "keywords": []}
                last_tag = tag
            elif current is not None and tag == "ER":
                records.append(current)
                current = None
                last_tag = None
            elif current is not None:
                if tag in {"AU", "A1"}:
                    current.setdefault("authors", []).append(value.strip())
                elif tag in {"KW"}:
                    current.setdefault("keywords", []).append(value.strip())
                else:
                    current[tag] = value.strip()
                last_tag = tag
            continue
        if current is not None and last_tag and line.startswith("  "):
            key = {"AU": "authors", "A1": "authors", "KW": "keywords"}.get(last_tag, last_tag)
            if key in {"authors", "keywords"}:
                current.setdefault(key, []).append(line.strip())
            elif key in current:
                current[key] = str(current[key]) + " " + line.strip()
    return records

def norm(v):
    return re.sub(r"\s+", " ", str(v or "").strip())

def normalize(r):
    ext = []
    if r.get("DO"):
        ext.append({"type": "doi", "value": norm(r["DO"])})
    return {
        "title": norm(r.get("TI") or r.get("T1")),
        "abstract": norm(r.get("AB")),
        "authors": r.get("authors", []),
        "year_published": norm(r.get("PY") or r.get("Y1")),
        "date_published": norm(r.get("DA")),
        "doi": norm(r.get("DO")),
        "external_ids": ext,
        "keywords": r.get("keywords", []),
        "publication_type": norm(r.get("publication_type")),
        "source": "manual_ris",
    }

ap = argparse.ArgumentParser()
ap.add_argument("ris_file")
ap.add_argument("--output-dir", default="outputs/manual_ris_ingest")
args = ap.parse_args()
src = Path(args.ris_file)
if not src.is_file():
    raise SystemExit(f"RIS file not found: {src}")
raw = parse_ris(src)
records = [normalize(r) for r in raw if normalize(r)["title"] or normalize(r)["abstract"]]
out = Path(args.output_dir)
out.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
json_path = out / f"manual_ris_increment_{stamp}.json"
csv_path = out / f"manual_ris_increment_{stamp}.csv"
manifest_path = out / f"manual_ris_increment_{stamp}_manifest.json"
json_path.write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
fields = sorted({k for r in records for k in r.keys()})
with csv_path.open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
    w.writeheader()
    w.writerows(records)
manifest = {
    "status": "no_records" if not records else "records_found",
    "source": "manual_ris",
    "source_file": str(src),
    "retrieved_at": datetime.now(timezone.utc).isoformat(),
    "records_written": len(records),
    "downstream_action": "do_not_modify_master" if not records else "process_update",
}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(f"Manual RIS records written: {len(records)}")
print(f"Status: {manifest['status']}")
