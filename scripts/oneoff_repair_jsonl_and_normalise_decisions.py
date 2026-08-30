#!/usr/bin/env python3
import base64, hashlib, json, re
from datetime import datetime, timezone
from pathlib import Path

RECORDS=Path('data/canonical/current/repair/records.jsonl')
MANIFEST=Path('data/canonical/current/repair/manifest.json')
ARCHIVE=Path('data/canonical/archive/repair/09_jsonl_repair_and_screening_normalisation')
SOURCE_SCRIPT=Path('scripts/oneoff_normalise_all_screening_decisions.py')
EXPECTED_RECORDS=22148
EXPECTED_SORTED_ID_SHA256='c08d310a033037fcca7f2d7f9f0f9f8efd34c4ab10e855c367a1fce928c35080'
EXPECTED_FINAL_MASTER=13388
DATE='2026-08-30'

text=RECORDS.read_text(encoding='utf-8')

# Parse complete top-level JSON objects rather than using str.splitlines(),
# because splitlines() also treats Unicode line-separator characters occurring
# legitimately inside bibliographic strings as record boundaries.
chunks=[]; buf=[]; depth=0; in_string=False; esc=False; repairs=0
for ch in text:
    if in_string:
        if esc:
            buf.append(ch); esc=False; continue
        if ch=='\\':
            buf.append(ch); esc=True; continue
        if ch=='"':
            buf.append(ch); in_string=False; continue
        if ch=='\n':
            buf.extend(['\\','n']); repairs+=1; continue
        if ch=='\r':
            buf.extend(['\\','r']); repairs+=1; continue
        if ch=='\t':
            buf.extend(['\\','t']); repairs+=1; continue
        if ord(ch)<32:
            buf.extend(list('\\u%04x'%ord(ch))); repairs+=1; continue
        buf.append(ch); continue
    else:
        if ch=='"':
            buf.append(ch); in_string=True; continue
        if ch=='{':
            depth+=1; buf.append(ch); continue
        if ch=='}':
            depth-=1; buf.append(ch)
            if depth==0:
                s=''.join(buf).strip()
                if s: chunks.append(s)
                buf=[]
            continue
        if depth==0:
            if ch.isspace(): continue
            raise SystemExit(f'Unexpected non-whitespace outside JSON object: {ch!r}')
        buf.append(ch)

if in_string or depth!=0 or ''.join(buf).strip():
    raise SystemExit(f'Incomplete JSON structure after scan: in_string={in_string}, depth={depth}')

records=[]
for i,s in enumerate(chunks,1):
    try: records.append(json.loads(s))
    except Exception as e: raise SystemExit(f'Reconstructed object {i} still invalid: {e}')
if len(records)!=EXPECTED_RECORDS:
    raise SystemExit(f'Expected {EXPECTED_RECORDS} reconstructed records, found {len(records)}')

ids=[]; seen=set()
for r in records:
    lid=((r.get('identity') or {}).get('lens_id') or '').upper()
    if not lid or lid in seen: raise SystemExit(f'Missing/duplicate Lens ID after reconstruction: {lid!r}')
    seen.add(lid); ids.append(lid)
sorted_ids=sorted(ids)
sha_ids=hashlib.sha256(('\n'.join(sorted_ids)+'\n').encode()).hexdigest()
if sha_ids!=EXPECTED_SORTED_ID_SHA256:
    raise SystemExit(f'Identity hash mismatch after reconstruction: {sha_ids}')

src=SOURCE_SCRIPT.read_text(encoding='utf-8')
m=re.search(r"FINAL_MASTER_BITSET_B64\s*=\s*'''(.*?)'''",src,re.S)
if not m: raise SystemExit('Could not recover verified final-master membership bitset')
bits=base64.b64decode(m.group(1))
final_ids={lid for i,lid in enumerate(sorted_ids) if bits[i//8] & (1 << (i%8))}
if len(final_ids)!=EXPECTED_FINAL_MASTER:
    raise SystemExit(f'Expected {EXPECTED_FINAL_MASTER} final-master Lens IDs, found {len(final_ids)}')

def dec(r):
    rel=((r.get('screening') or {}).get('relevance'))
    return rel.get('decision') if isinstance(rel,dict) else None

before={'RETAIN':0,'EXCLUDE':0,'UNDECIDED':0,'OTHER':0}
for r in records:
    d=dec(r)
    if d in ('RETAIN','EXCLUDE'): before[d]+=1
    elif d is None: before['UNDECIDED']+=1
    else: before['OTHER']+=1

retain_written=0; retain_preserved=0; retain_superseded_excludes=0
for r in records:
    lid=r['identity']['lens_id'].upper()
    if lid not in final_ids: continue
    d=dec(r)
    if d=='RETAIN':
        retain_preserved+=1; continue
    if d=='EXCLUDE':
        old=((r.get('screening') or {}).get('relevance'))
        r.setdefault('provenance',{}).setdefault('screening_decision_history',[]).append(old)
        retain_superseded_excludes+=1
    elif d not in (None,):
        raise SystemExit(f'Unexpected existing decision {d!r} on final-master record {lid}')
    r.setdefault('screening',{})['relevance']={
      'decision':'RETAIN','decision_source':'historical_final_master',
      'adjudication_set':'full_historical_master_reconciliation','adjudication_date':DATE,
      'decision_basis':'present_in_reconciled_final_retained_master'
    }
    retain_written+=1

residual=0
for r in records:
    if dec(r) is None:
        residual+=1
        r.setdefault('screening',{})['relevance']={
          'decision':'EXCLUDE','decision_source':'residual_canonical_assignment',
          'adjudication_set':'residual_undecided_after_historical_reconciliation','adjudication_date':DATE,
          'decision_basis':'not_in_reconciled_final_retained_master; provisional_exclusion_pending_future_reassessment'
        }
        r.setdefault('provenance',{})['residual_screening_assignment']={'decision':'EXCLUDE','provisional':True,'basis':'not_in_reconciled_final_retained_master_after_historical_decision_normalisation'}

after={'RETAIN':0,'EXCLUDE':0,'UNDECIDED':0,'OTHER':0}
for r in records:
    d=dec(r)
    if d in ('RETAIN','EXCLUDE'): after[d]+=1
    elif d is None: after['UNDECIDED']+=1
    else: after['OTHER']+=1
    if r['identity']['lens_id'].upper() in final_ids and d!='RETAIN':
        raise SystemExit('Final-master integrity check failed')
if after['UNDECIDED'] or after['OTHER'] or after['RETAIN']+after['EXCLUDE']!=EXPECTED_RECORDS:
    raise SystemExit(f'Incomplete decision coverage after normalisation: {after}')

with RECORDS.open('w',encoding='utf-8',newline='\n') as f:
    for r in records: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
# JSONL records are separated by literal LF only. Do not use str.splitlines(),
# which also splits on Unicode U+2028/U+2029 and related characters in strings.
check=[json.loads(x) for x in RECORDS.read_text(encoding='utf-8').split('\n') if x.strip()]
if len(check)!=EXPECTED_RECORDS: raise SystemExit(f'Round-trip LF validation failed: {len(check)}')
if len({((r.get('identity') or {}).get('lens_id') or '').upper() for r in check})!=EXPECTED_RECORDS:
    raise SystemExit('Round-trip unique Lens-ID validation failed')
sha=hashlib.sha256(RECORDS.read_bytes()).hexdigest()

ARCHIVE.mkdir(parents=True,exist_ok=True)
audit={
 'schema':'jsonl_repair_and_screening_normalisation_audit','created_at':datetime.now(timezone.utc).isoformat(),
 'misleading_python_splitlines_count_before':22262,'literal_control_char_repairs':repairs,
 'reconstructed_records':len(records),'unique_lens_ids':len(seen),'sorted_lens_id_sha256':sha_ids,
 'before_decisions':before,'final_master_records':len(final_ids),'retain_written':retain_written,
 'retain_preserved':retain_preserved,'stale_excludes_superseded_by_final_master':retain_superseded_excludes,
 'residual_provisional_excludes_written':residual,'after_decisions':after,'undecided_after':0,
 'records_sha256':sha
}
(ARCHIVE/'manifest.json').write_text(json.dumps(audit,indent=2)+'\n',encoding='utf-8')
manifest=json.loads(MANIFEST.read_text(encoding='utf-8'))
manifest['record_count']=EXPECTED_RECORDS; manifest['records_sha256']=sha
manifest['jsonl_repair_and_screening_normalisation']=audit
MANIFEST.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(audit,indent=2))
