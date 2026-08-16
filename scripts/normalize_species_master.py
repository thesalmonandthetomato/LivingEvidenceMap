#!/usr/bin/env python3
"""Canonicalise species labels in the validated LivingEvidenceMap master."""
import csv, re
from pathlib import Path

MASTER = Path('data/master/current/living_evidence_map_master.csv')
OUT = Path('data/master/candidates/living_evidence_map_master_species_normalized.csv')

SPECIES_COLUMNS = [
    'final_species', 'deterministic_species', 'farmed_species',
    'species', 'species_name', 'species_assignment'
]

def canonical(value: str) -> str:
    s = str(value or '').strip()
    if not s:
        return ''
    key = re.sub(r'\s+', ' ', s).strip().lower()
    if 'unspecified' in key and any(x in key for x in ('salmon', 'salmonid', 'species')):
        return 'Unspecified species'
    if key == 'rainbow salmon':
        return 'Rainbow salmon'
    return s

def normalise_cell(value: str) -> str:
    parts = [p.strip() for p in re.split(r'\s*;\s*', str(value or '')) if p.strip()]
    if not parts:
        return ''
    out = []
    for p in parts:
        c = canonical(p)
        if c and c not in out:
            out.append(c)
    return '; '.join(out)

with MASTER.open(newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    fields = reader.fieldnames or []
    rows = list(reader)

cols = [c for c in SPECIES_COLUMNS if c in fields]
if not cols:
    raise SystemExit('No recognised species columns found')

changed = 0
for row in rows:
    for col in cols:
        old = row.get(col, '')
        new = normalise_cell(old)
        if new != old:
            row[col] = new
            changed += 1

OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open('w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
    w.writeheader()
    for row in rows:
        w.writerow(row)

with OUT.open(newline='', encoding='utf-8-sig') as f:
    out_rows = sum(1 for _ in csv.DictReader(f))
if len(rows) != out_rows:
    raise SystemExit('Row-count validation failed')

print(f'Rows: {len(rows):,}')
print(f'Species cells canonicalised: {changed:,}')
print(f'Output: {OUT}')
