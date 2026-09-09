#!/usr/bin/env python3
import json
from pathlib import Path

CANONICAL = Path('data/canonical/current/repair/records.jsonl')
MANIFEST = Path('data/canonical/current/repair/manifest.json')
OUT = Path('data/canonical/current/repair/retraction_audit.jsonl')

RETRACTION_TERMS = {
    'retraction','retracted','withdrawn','withdrawal','expression of concern',
    'publication notice','correction notice','erratum','corrigendum'
}


def text_fields(rec):
    vals=[]
    for k in ('title','abstract','publication_type','type','source_title','journal','notes'):
        v=rec.get(k)
        if isinstance(v,str): vals.append(v)
        elif isinstance(v,list): vals.extend(str(x) for x in v)
    return ' '.join(vals).lower()


def main():
    if not CANONICAL.exists():
        raise SystemExit(f'Missing canonical file: {CANONICAL}')
    records=[]
    flagged=[]
    for line in CANONICAL.read_text(encoding='utf-8').splitlines():
        if not line.strip(): continue
        rec=json.loads(line)
        records.append(rec)
        blob=text_fields(rec)
        hits=sorted(t for t in RETRACTION_TERMS if t in blob)
        if hits:
            flagged.append({
                'record_id': rec.get('record_id') or rec.get('id') or rec.get('lens_id'),
                'title': rec.get('title'),
                'doi': rec.get('doi'),
                'matched_terms': hits,
                'action': 'REVIEW'
            })
    OUT.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in flagged),encoding='utf-8')
    manifest=json.loads(MANIFEST.read_text(encoding='utf-8')) if MANIFEST.exists() else {}
    manifest['retraction_sweep']={
        'records_checked': len(records),
        'records_flagged_for_review': len(flagged),
        'status': 'audit_complete'
    }
    MANIFEST.write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(f'Checked {len(records)} records; flagged {len(flagged)} for human review.')

if __name__=='__main__':
    main()
