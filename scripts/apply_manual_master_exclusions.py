#!/usr/bin/env python3
import csv
from pathlib import Path
from datetime import date

MASTER = Path('data/reference/salmon_evidence_map.csv')
EXCLUSIONS = Path('data/reference/manual_master_exclusions_2026-08-15.csv')
ARCHIVE_DIR = Path('data/reference/archive')
OUT = Path('data/reference/salmon_evidence_map.csv')

with EXCLUSIONS.open(newline='', encoding='utf-8-sig') as f:
    erows = list(csv.DictReader(f))
ids = {str(r['record_id']).strip() for r in erows if str(r.get('human_decision','')).strip().lower() == 'exclude'}
if len(ids) != 34:
    raise SystemExit(f'Expected 34 manual exclusions, found {len(ids)}')

with MASTER.open(newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    fields = list(reader.fieldnames or [])
    rows = list(reader)
if 'record_id' not in fields:
    raise SystemExit('Master has no record_id column')

present = {str(r.get('record_id','')).strip() for r in rows}
missing = sorted(ids - present)
if missing:
    raise SystemExit('Manual exclusion IDs not present in master: ' + ', '.join(missing))

removed = [r for r in rows if str(r.get('record_id','')).strip() in ids]
remaining = [r for r in rows if str(r.get('record_id','')).strip() not in ids]
if len(removed) != 34:
    raise SystemExit(f'Expected to remove 34 records, removed {len(removed)}')

ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
today = date.today().isoformat()
archive_master = ARCHIVE_DIR / f'salmon_evidence_map_{today}_pre_manual_exclusions.csv'
with archive_master.open('w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(rows)

removed_path = ARCHIVE_DIR / f'manual_exclusions_{today}.csv'
with removed_path.open('w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(removed)

with OUT.open('w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(remaining)

print(f'Original master: {len(rows)}')
print(f'Removed by human adjudication: {len(removed)}')
print(f'New master: {len(remaining)}')
print(f'Archived pre-exclusion master: {archive_master}')
print(f'Archived removed records: {removed_path}')
