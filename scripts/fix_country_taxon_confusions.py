#!/usr/bin/env python3
"""Remove false AIA/ATG country annotations caused by the Anguilla taxon."""
from __future__ import annotations

import csv
import json
import re
from pathlib import Path

MASTER = Path("data/master/current/living_evidence_map_master.csv")
AUDIT = Path("data/master/archive/country_annotation_correction_2026-08-17.csv")

BAD = {"", "na", "n/a", "nan", "null", "none"}
TARGET_ISO = {"AIA", "ATG"}
TARGET_NAMES = {"anguilla", "antigua and barbuda", "antigua"}


def split_values(value):
    if value is None:
        return []
    s = str(value).strip()
    if not s or s.lower() in BAD:
        return []
    if s.startswith("[") and s.endswith("]"):
        try:
            obj = json.loads(s)
            if isinstance(obj, list):
                return [str(x).strip() for x in obj if str(x).strip()]
        except Exception:
            pass
    return [x.strip() for x in re.split(r"\s*;\s*|\s*\|\s*", s) if x.strip()]


def remove_targets(value, targets):
    if value is None:
        return value, False
    original = str(value)
    s = original.strip()
    if not s:
        return original, False
    if s.startswith("[") and s.endswith("]"):
        try:
            obj = json.loads(s)
            if isinstance(obj, list):
                kept = [x for x in obj if str(x).strip().lower() not in targets]
                return json.dumps(kept, ensure_ascii=False), kept != obj
        except Exception:
            pass
    parts = re.split(r"\s*;\s*|\s*\|\s*", original)
    nonempty = [p.strip() for p in parts if p.strip()]
    kept = [p for p in nonempty if p.lower() not in targets]
    if len(kept) == len(nonempty):
        return original, False
    return "; ".join(kept), True


def taxon_context(row, fields):
    """Detect Anguilla as a taxon, not merely as a place name."""
    species_text = " ".join(
        str(row.get(f, "") or "") for f in fields if "species" in f.lower()
    )
    context_text = " ".join(
        str(row.get(f, "") or "") for f in fields
        if any(k in f.lower() for k in ("species", "title", "abstract", "keyword", "subject"))
    )
    if re.search(r"\banguilla\b", species_text, re.IGNORECASE):
        return True, species_text
    if re.search(r"\banguilla\s+[a-z][a-z-]+\b", context_text, re.IGNORECASE):
        return True, context_text
    return False, species_text


if not MASTER.exists():
    raise SystemExit(f"Authoritative master not found: {MASTER}")

with MASTER.open("r", encoding="utf-8-sig", newline="") as fh:
    reader = csv.DictReader(fh)
    fields = reader.fieldnames or []
    rows = list(reader)

iso_fields = [f for f in fields if any(k in f.lower() for k in ("iso3", "iso_3", "country_iso")) or f.lower() in {"final_primary_country_iso3c", "primary_iso3c"}]
country_fields = [f for f in fields if any(k in f.lower() for k in ("country", "countries", "geography_primary")) and not any(k in f.lower() for k in ("iso", "code", "numeric"))]
id_fields = [f for f in fields if f.lower() in {"record_id", "id", "lens_id", "study_id"}]
id_field = id_fields[0] if id_fields else None

if not iso_fields and not country_fields:
    raise SystemExit("No country fields found in authoritative master")

changes = []
for row in rows:
    is_taxon, species_context = taxon_context(row, fields)
    if not is_taxon:
        continue

    old_iso = {f: row.get(f, "") for f in iso_fields}
    old_country = {f: row.get(f, "") for f in country_fields}
    changed = False

    for f in iso_fields:
        new, did = remove_targets(row.get(f, ""), TARGET_ISO)
        if did:
            row[f] = new
            changed = True

    for f in country_fields:
        new, did = remove_targets(row.get(f, ""), TARGET_NAMES)
        if did:
            row[f] = new
            changed = True

    if changed:
        changes.append({
            "record_id": row.get(id_field, "") if id_field else "",
            "species_context": species_context,
            "old_iso3": json.dumps(old_iso, ensure_ascii=False, sort_keys=True),
            "new_iso3": json.dumps({f: row.get(f, "") for f in iso_fields}, ensure_ascii=False, sort_keys=True),
            "old_country": json.dumps(old_country, ensure_ascii=False, sort_keys=True),
            "new_country": json.dumps({f: row.get(f, "") for f in country_fields}, ensure_ascii=False, sort_keys=True),
            "reason": "Removed AIA/ATG country annotation where the record contains the Anguilla taxon",
        })

if not changes:
    print("No Anguilla/AIA/ATG country confusions found; master unchanged.")
    raise SystemExit(0)

AUDIT.parent.mkdir(parents=True, exist_ok=True)
tmp = MASTER.with_suffix(".csv.tmp")
with tmp.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
tmp.replace(MASTER)

with AUDIT.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=list(changes[0].keys()))
    writer.writeheader()
    writer.writerows(changes)

print(f"Corrected {len(changes):,} records in {MASTER}.")
print(f"Audit written to {AUDIT}.")
