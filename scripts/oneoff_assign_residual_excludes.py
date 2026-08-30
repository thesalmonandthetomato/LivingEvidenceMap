#!/usr/bin/env python3
import json, hashlib
from pathlib import Path
from datetime import datetime, timezone

P=Path('data/canonical/current/repair/records.jsonl')
M=Path('data/canonical/current/repair/manifest.json')
A=Path('data/canonical/archive/repair/09_residual_exclusion_assignment')
A.mkdir(parents=True,exist_ok=True)
records=[]
for line in P.open(encoding='utf-8'):
    if line.strip(): records.append(json.loads(line))

def decision(r):
    return (((r.get('screening') or {}).get('relevance') or {}).get('decision'))

targets=[r for r in records if not decision(r)]
if len(records)!=22148: raise SystemExit(f'Expected 22148 canonical records, found {len(records)}')
if len(targets)!=2707: raise SystemExit(f'Expected exactly 2707 undecided records, found {len(targets)}; refusing to modify canonical')

audit=[]
for r in targets:
    lens=((r.get('identity') or {}).get('lens_id'))
    r.setdefault('screening',{})['relevance']={
      'decision':'EXCLUDE',
      'decision_source':'residual_canonical_assignment',
      'adjudication_set':'residual_undecided_after_historical_reconciliation',
      'adjudication_date':'2026-08-30',
      'decision_basis':'absent_from_reconciled_final_retained_master; provisional_exclusion_pending_future_reassessment'
    }
    audit.append({'lens_id':lens,'decision':'EXCLUDE','basis':'residual_undecided_after_historical_reconciliation','provisional':True})

with P.open('w',encoding='utf-8',newline='\n') as f:
    for r in records: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')

post_undecided=sum(1 for r in records if not decision(r))
if post_undecided!=0: raise SystemExit(f'Post-write validation failed: {post_undecided} undecided records remain')
if sum(1 for r in records if decision(r)=='EXCLUDE' and ((r.get('screening') or {}).get('relevance') or {}).get('decision_source')=='residual_canonical_assignment')!=2707:
    raise SystemExit('Post-write validation failed: residual exclusion count != 2707')

sha=hashlib.sha256(P.read_bytes()).hexdigest()
manifest=json.loads(M.read_text(encoding='utf-8'))
manifest['record_count']=len(records); manifest['records_sha256']=sha
manifest['residual_exclusion_assignment']={
 'records':2707,'decision':'EXCLUDE','decision_source':'residual_canonical_assignment',
 'adjudication_set':'residual_undecided_after_historical_reconciliation','adjudication_date':'2026-08-30',
 'decision_basis':'absent_from_reconciled_final_retained_master; provisional_exclusion_pending_future_reassessment',
 'post_assignment_undecided_records':0
}
M.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
with (A/'screening_adjudication_audit.jsonl').open('w',encoding='utf-8') as f:
    for x in audit: f.write(json.dumps(x,separators=(',',':'))+'\n')
(A/'manifest.json').write_text(json.dumps({'schema':'residual_exclusion_assignment_audit','created_at':datetime.now(timezone.utc).isoformat(),'canonical_records':len(records),'records_assigned_exclude':2707,'post_assignment_undecided_records':0,'records_sha256':sha,'provisional':True},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'record_count':len(records),'assigned_exclude':2707,'post_assignment_undecided':0,'records_sha256':sha},indent=2))
