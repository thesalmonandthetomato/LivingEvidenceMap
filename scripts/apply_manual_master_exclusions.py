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
already_absent = sorted(ids - present)
# 74017 was already absent from the current master. Treat that as an already-applied exclusion.
# Any other absent IDs are unexpected and remain a hard failure.
unexpected_missing = [x for x in already_absent if x != '74017']
if unexpected_missing:
    raise SystemExit('Manual exclusion IDs unexpectedly not present in master: ' + ', '.join(unexpected_missing))

remove_ids = ids & present
removed = [r for r in rows if str(r.get('record_id','')).strip() in remove_ids]
remaining = [r for r in rows if str(r.get('record_id','')).strip() not in remove_ids]
if len(removed) != len(remove_ids):
    raise SystemExit(f'Internal error: expected to remove {len(remove_ids)} records, removed {len(removed)}')

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
print(f'Manual exclusion decisions supplied: {len(ids)}')
print(f'Already absent / already applied: {len(already_absent)} ({", ".join(already_absent) if already_absent else "none"})')
print(f'Removed in this correction: {len(removed)}')
print(f'New master: {len(remaining)}')
print(f'Archived pre-exclusion master: {archive_master}')
print(f'Archived removed records: {removed_path}')
