#!/usr/bin/env python3
import base64, copy, hashlib, json
from datetime import datetime, timezone
from pathlib import Path

RECORDS = Path('data/canonical/current/repair/records.jsonl')
MANIFEST = Path('data/canonical/current/repair/manifest.json')
ARCHIVE = Path('data/canonical/archive/repair/09_screening_decision_normalisation')
ARCHIVE.mkdir(parents=True, exist_ok=True)

EXPECTED_RECORDS = 22148
EXPECTED_SORTED_ID_SHA256 = 'c08d310a033037fcca7f2d7f9f0f9f8efd34c4ab10e855c367a1fce928c35080'
EXPECTED_FINAL_MASTER_LENS_RECORDS = 13388
ADJUDICATION_DATE = '2026-08-30'

# Membership bitset over the lexicographically sorted 22,148 current canonical Lens IDs.
# It represents all 13,388 Lens-backed records in living_evidence_map_master(6).csv,
# with the 11 verified historical->current Lens-ID re-key mappings applied.
FINAL_MASTER_BITSET_B64 = '''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'''

raw = [line for line in RECORDS.read_text(encoding='utf-8').splitlines() if line.strip()]
assert len(raw) == EXPECTED_RECORDS, f'Expected {EXPECTED_RECORDS} records, found {len(raw)}'
records = [json.loads(line) for line in raw]
ids = []
seen = set()
for r in records:
    lid = ((r.get('identity') or {}).get('lens_id') or '').upper()
    assert lid and lid not in seen, f'Missing/duplicate Lens ID: {lid!r}'
    seen.add(lid); ids.append(lid)
sorted_ids = sorted(ids)
sha_ids = hashlib.sha256(('\n'.join(sorted_ids)+'\n').encode()).hexdigest()
assert sha_ids == EXPECTED_SORTED_ID_SHA256, f'Canonical identity set changed: {sha_ids}'

bits = base64.b64decode(FINAL_MASTER_BITSET_B64)
final_ids = {lid for i,lid in enumerate(sorted_ids) if bits[i//8] & (1 << (i%8))}
assert len(final_ids) == EXPECTED_FINAL_MASTER_LENS_RECORDS, f'Expected {EXPECTED_FINAL_MASTER_LENS_RECORDS} final-master IDs, found {len(final_ids)}'

def get_decision(r):
    rel = ((r.get('screening') or {}).get('relevance'))
    return rel.get('decision') if isinstance(rel, dict) else None

before_counts = {'RETAIN':0,'EXCLUDE':0,'UNDECIDED':0,'OTHER':0}
for r in records:
    d=get_decision(r)
    if d in ('RETAIN','EXCLUDE'): before_counts[d]+=1
    elif d is None: before_counts['UNDECIDED']+=1
    else: before_counts['OTHER']+=1

# First: make the reconciled final retained master authoritative for RETAIN membership.
conflicts=[]; retain_written=0; retain_preserved=0
for r in records:
    lid=r['identity']['lens_id'].upper()
    if lid not in final_ids: continue
    d=get_decision(r)
    if d == 'EXCLUDE':
        conflicts.append({'lens_id':lid,'existing_relevance':copy.deepcopy((r.get('screening') or {}).get('relevance'))})
    elif d == 'RETAIN':
        retain_preserved += 1
    elif d is None:
        r.setdefault('screening',{})['relevance']={
          'decision':'RETAIN','decision_source':'historical_final_master',
          'adjudication_set':'full_historical_master_reconciliation','adjudication_date':ADJUDICATION_DATE,
          'decision_basis':'present_in_reconciled_final_retained_master'
        }
        retain_written += 1
    else:
        conflicts.append({'lens_id':lid,'existing_relevance':copy.deepcopy((r.get('screening') or {}).get('relevance'))})
if conflicts:
    (ARCHIVE/'conflicts.json').write_text(json.dumps(conflicts,indent=2),encoding='utf-8')
    raise SystemExit(f'{len(conflicts)} final-master records have conflicting existing decisions; refusing to modify canonical')
assert retain_written + retain_preserved == EXPECTED_FINAL_MASTER_LENS_RECORDS

# Second: user's explicit policy decision: every genuinely residual undecided record is provisional EXCLUDE.
residual_ids=[]
for r in records:
    if get_decision(r) is None:
        lid=r['identity']['lens_id'].upper(); residual_ids.append(lid)
        r.setdefault('screening',{})['relevance']={
          'decision':'EXCLUDE','decision_source':'residual_canonical_assignment',
          'adjudication_set':'residual_undecided_after_historical_reconciliation','adjudication_date':ADJUDICATION_DATE,
          'decision_basis':'not_in_reconciled_final_retained_master; provisional_exclusion_pending_future_reassessment'
        }
        r.setdefault('provenance',{})['residual_screening_assignment']={
          'decision':'EXCLUDE','provisional':True,
          'basis':'not_in_reconciled_final_retained_master_after_historical_decision_normalisation'
        }

# Validate complete decision coverage and retained-master integrity.
after_counts={'RETAIN':0,'EXCLUDE':0,'UNDECIDED':0,'OTHER':0}
for r in records:
    d=get_decision(r)
    if d in ('RETAIN','EXCLUDE'): after_counts[d]+=1
    elif d is None: after_counts['UNDECIDED']+=1
    else: after_counts['OTHER']+=1
    if r['identity']['lens_id'].upper() in final_ids:
        assert d=='RETAIN'
assert after_counts['UNDECIDED']==0 and after_counts['OTHER']==0
assert after_counts['RETAIN']+after_counts['EXCLUDE']==EXPECTED_RECORDS

with RECORDS.open('w',encoding='utf-8',newline='\n') as f:
    for r in records: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
records_sha=hashlib.sha256(RECORDS.read_bytes()).hexdigest()

manifest=json.loads(MANIFEST.read_text(encoding='utf-8'))
manifest['record_count']=EXPECTED_RECORDS
manifest['records_sha256']=records_sha
manifest['screening_decision_normalisation']={
  'adjudication_date':ADJUDICATION_DATE,
  'final_master_lens_records':EXPECTED_FINAL_MASTER_LENS_RECORDS,
  'final_master_retain_written':retain_written,
  'final_master_retain_preserved':retain_preserved,
  'residual_provisional_excludes_written':len(residual_ids),
  'decision_counts_before':before_counts,
  'decision_counts_after':after_counts,
  'undecided_after':0,
  'policy':'Final reconciled master => RETAIN; all remaining undecided => provisional EXCLUDE for later reassessment.'
}
MANIFEST.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

(A:=ARCHIVE/'manifest.json').write_text(json.dumps({
 'schema':'screening_decision_normalisation_audit','created_at':datetime.now(timezone.utc).isoformat(),
 'canonical_record_count':EXPECTED_RECORDS,'final_master_lens_records':EXPECTED_FINAL_MASTER_LENS_RECORDS,
 'final_master_retain_written':retain_written,'final_master_retain_preserved':retain_preserved,
 'residual_provisional_excludes_written':len(residual_ids),'decision_counts_before':before_counts,
 'decision_counts_after':after_counts,'undecided_after':0,'records_sha256':records_sha
},indent=2)+'\n',encoding='utf-8')
(ARCHIVE/'residual_provisional_exclude_ids.txt').write_text('\n'.join(sorted(residual_ids))+'\n',encoding='utf-8')
print(json.dumps({'record_count':EXPECTED_RECORDS,'final_master_retain_written':retain_written,'final_master_retain_preserved':retain_preserved,'residual_provisional_excludes_written':len(residual_ids),'decision_counts_before':before_counts,'decision_counts_after':after_counts,'undecided_after':0,'records_sha256':records_sha},indent=2))
