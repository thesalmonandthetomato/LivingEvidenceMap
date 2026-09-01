#!/usr/bin/env python3
import argparse, json
from datetime import datetime, timezone
from pathlib import Path


def norm(v):
    return '' if v is None else str(v).strip()


def lens_id(r):
    return norm((r.get('canonical') or {}).get('lens_id') or (r.get('identity') or {}).get('lens_id') or r.get('lens_id'))


def abstract(r):
    return norm((r.get('canonical') or {}).get('abstract'))


def read_jsonl(path):
    out=[]
    with Path(path).open(encoding='utf-8') as f:
        for line in f:
            if line.strip():
                out.append(json.loads(line))
    return out


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--canonical', required=True)
    ap.add_argument('--proposals', required=True)
    ap.add_argument('--summary', required=True)
    ap.add_argument('--expected-total', type=int, default=1766)
    ap.add_argument('--expected-missing-fill', type=int, default=1760)
    ap.add_argument('--expected-partial-replace', type=int, default=6)
    args=ap.parse_args()

    props=read_jsonl(args.proposals)
    if len(props)!=args.expected_total:
        raise SystemExit(f'proposal count {len(props)} != expected {args.expected_total}')
    miss=sum(p.get('target')=='missing' for p in props)
    part=sum(p.get('target')=='partial' for p in props)
    if miss!=args.expected_missing_fill or part!=args.expected_partial_replace:
        raise SystemExit(f'proposal split missing={miss}, partial={part} != expected {args.expected_missing_fill}/{args.expected_partial_replace}')
    by_id={p['lens_id']:p for p in props}
    if len(by_id)!=len(props): raise SystemExit('duplicate Lens IDs in proposals')

    path=Path(args.canonical)
    records=read_jsonl(path)
    if len(records)!=22148: raise SystemExit(f'canonical count {len(records)} != 22148')
    before_missing=sum(not abstract(r) for r in records)
    now=datetime.now(timezone.utc).isoformat()
    applied=[]

    for r in records:
        lid=lens_id(r)
        p=by_id.get(lid)
        if not p: continue
        cur=abstract(r)
        audited=norm(p.get('canonical_abstract'))
        if cur!=audited:
            raise SystemExit(f'canonical drift for {lid}: current length {len(cur)} audited length {len(audited)}')
        new=norm(p.get('source_abstract'))
        if not new: raise SystemExit(f'blank proposed abstract for {lid}')
        if p.get('target')=='missing' and cur:
            raise SystemExit(f'{lid} expected missing but canonical is nonblank')
        if p.get('target')=='partial' and not cur:
            raise SystemExit(f'{lid} expected partial but canonical is blank')

        r.setdefault('canonical', {})['abstract']=new
        prov=r.setdefault('provenance', {})
        events=prov.setdefault('canonical_field_enrichment', [])
        if not isinstance(events,list):
            events=[events]
            prov['canonical_field_enrichment']=events
        events.append({
            'field':'abstract',
            'action':'internal_source_backfill' if p.get('target')=='missing' else 'internal_source_partial_replacement',
            'source':p.get('source'),
            'source_path':p.get('source_path'),
            'source_row':p.get('source_row'),
            'match_basis':p.get('match_basis'),
            'title_similarity':p.get('title_similarity'),
            'previous_length':len(cur),
            'new_length':len(new),
            'applied_at':now
        })
        applied.append(lid)

    if len(applied)!=len(props):
        missing_ids=sorted(set(by_id)-set(applied))
        raise SystemExit(f'applied {len(applied)} != proposals {len(props)}; missing ids sample={missing_ids[:10]}')

    after_missing=sum(not abstract(r) for r in records)
    if after_missing != before_missing - args.expected_missing_fill:
        raise SystemExit(f'after missing {after_missing} != expected {before_missing-args.expected_missing_fill}')
    with_abstract=len(records)-after_missing

    path.write_text(''.join(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n' for r in records), encoding='utf-8')
    summary={
        'canonical_records':len(records),
        'before_with_abstract':len(records)-before_missing,
        'before_without_abstract':before_missing,
        'applied_total':len(applied),
        'applied_missing_fill':miss,
        'applied_partial_replace':part,
        'after_with_abstract':with_abstract,
        'after_without_abstract':after_missing,
        'provenance_path':'provenance.canonical_field_enrichment'
    }
    Path(args.summary).write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
