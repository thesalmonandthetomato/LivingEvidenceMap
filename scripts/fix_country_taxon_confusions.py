#!/usr/bin/env python3
"""Remove false AIA/ATG country annotations caused by the Anguilla taxon.

The authoritative master is large, so this script performs an in-place CSV
correction and writes a compact audit rather than duplicating the master.
"""
from __future__ import annotations

import csv
import json
import re
from pathlib import Path

MASTER = Path("data/master/current/living_evidence_map_master.csv")
AUDIT = Path("data/master/archive/country_annotation_correction_2026-08-17.csv")

ISO_FIELDS = [
    "final_primary_country_iso3c", "iso3", "iso3c", "primary_iso3c",
    "primary_iso3c_codes", "deterministic_primary_iso3c",
    "country_iso3c", "country_iso3c_codes",
    "deterministic_primary_iso3c_codes",
]
COUNTRY_FIELDS = [
    "final_primary_country", "primary_country", "primary_countries",
    "country", "countries", "country_name", "country_names",
    "deterministic_primary_countries", "geography_primary_country",
    "geography_country",
]
SPECIES_FIELDS = [
    "final_species", "species", "farmed_species", "deterministic_species",
    "species_assigned", "species_assignment", "species_name",
]
ID_FIELDS = ["record_id", "id", "lens_id", "study_id"]

BAD = {"", "na", "n/a", "nan", "null", "none"}
TARGET_ISO = {"AIA", "ATG"}
TARGET_NAMES = {"anguilla", "antigua and barbuda", "antigua"}


def first_field(fields, candidates):
    lower = {f.lower(): f for f in fields}
    for candidate in candidates:
        if candidate.lower() in lower:
            return lower[candidate.lower()]
    return None


def values(value):
    if value is None:
        return []
    s = str(value).strip()
    if s.lower() in BAD:
        return []
    if s.startswith("[") and s.endswith("]"):
        try:
            obj = json.loads(s)
            if isinstance(obj, list):
                return [str(x).strip() for x in obj if str(x).strip()]
        except Exception:
            pass
    return [x.strip() for x in re.split(r"\s*;\s*|\s*\|\s*", s) if x.strip()]


def remove_targets(value, targets, json_output=False):
    if value is None:
        return value, False
    original = str(value)
    s = original.strip()
    if not s:
        return value, False
    is_json = s.startswith("[") and s.endswith("]")
    if is_json:
        try:
            obj = json.loads(s)
            if isinstance(obj, list):
                kept = [x for x in obj if str(x).strip().lower() not in targets]
                changed = kept != obj
                return (json.dumps(kept, ensure_ascii=False) if changed else original), changed
        except Exception:
            pass
    parts = re.split(r"\s*;\s*|\s*\|\s*", original)
    kept = [p.strip() for p in parts if p.strip() and p.strip().lower() not in targets]
    if len(kept) == len([p for p in parts if p.strip()]):
        return original, False
    return "; ".join(kept), True


def has_anguilla_taxon(row, species_field):
    if not species_field:
        return False
    species = str(row.get(species_field, "") or "")
    # The country gazetteer term "Anguilla" is a country name, but Anguilla
    # is also a biological genus (e.g. Anguilla anguilla). In the species
    # annotation field it is unambiguously taxonomic, so suppress country
    # matches derived from it.
    return bool(re.search(r"\banguilla\b", species, flags=re.IGNORECASE))


if not MASTER.exists():
    raise SystemExit(f"Authoritative master not found: {MASTER}")

with MASTER.open("r", encoding="utf-8-sig", newline="") as fh:
    reader = csv.DictReader(fh)
    fields = reader.fieldnames or []
    rows = list(reader)

iso_fields = [f for f in fields if f.lower() in {x.lower() for x in ISO_FIELDS}]
country_fields = [f for f in fields if f.lower() in {x.lower() for x in COUNTRY_FIELDS}]
species_field = first_field(fields, SPECIES_FIELDS)
id_field = first_field(fields, ID_FIELDS)
if not iso_fields and not country_fields:
    raise SystemExit("No recognised country fields found in authoritative master")

changes = []
for row in rows:
    if not has_anguilla_taxon(row, species_field):
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
            "species": row.get(species_field, "") if species_field else "",
            "old_iso3": json.dumps(old_iso, ensure_ascii=False, sort_keys=True),
            "new_iso3": json.dumps({f: row.get(f, "") for f in iso_fields}, ensure_ascii=False, sort_keys=True),
            "old_country": json.dumps(old_country, ensure_ascii=False, sort_keys=True),
            "new_country": json.dumps({f: row.get(f, "") for f in country_fields}, ensure_ascii=False, sort_keys=True),
            "reason": "Removed AIA/ATG country annotation where species annotation contains the Anguilla taxon",
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
