#!/usr/bin/env python3
import argparse, csv, json, sys
from pathlib import Path


def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline='', encoding='utf-8-sig') as f:
        return list(csv.DictReader(f))


def key_from_row(row):
    for k in ('lens_id','record_id','id'):
        v=(row.get(k) or '').strip()
        if v:
            return v
    raise ValueError(f'No stable record id column found in row: {row}')


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--update-dir', required=True)
    ap.add_argument('--adjudications', required=True)
    ap.add_argument('--out-dir', required=True)
    args=ap.parse_args()

    d=Path(args.update_dir)
    adj_path=Path(args.adjudications)
    out=Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    queued={}
    for fn in ('screening_uncertain.csv','geography_review_queue.csv'):
        for r in read_csv(d/fn):
            queued.setdefault(key_from_row(r), set()).add(fn)
    for r in read_csv(d/'annotation_adjudication.csv'):
        text=','.join(str(v) for v in r.values())
        if 'UNRESOLVED' in text or ',TRUE,' in ','+text+',':
            queued.setdefault(key_from_row(r), set()).add('annotation_adjudication.csv')
    for r in read_csv(d/'topic_classification.csv'):
        text=','.join(str(v) for v in r.values())
        if any(x in text for x in ('UNCERTAIN','UNRESOLVED')) or ',TRUE,' in ','+text+',':
            queued.setdefault(key_from_row(r), set()).add('topic_classification.csv')

    if not adj_path.exists():
        raise SystemExit(f'Adjudication file not found: {adj_path}')
    data=json.loads(adj_path.read_text(encoding='utf-8'))
    decisions=data.get('decisions')
    if not isinstance(decisions,list) or not decisions:
        raise SystemExit('adjudication JSON must contain non-empty decisions[]')

    seen={}
    allowed_relevance={'retain','exclude'}
    for x in decisions:
        rid=str(x.get('record_id','')).strip()
        if not rid:
            raise SystemExit('Every decision requires record_id')
        if rid in seen:
            raise SystemExit(f'Duplicate adjudication for {rid}')
        if rid not in queued:
            raise SystemExit(f'Adjudication references record not in review queue: {rid}')
        decision={k:v for k,v in x.items() if k!='record_id'}
        if 'relevance' in decision and decision['relevance'] not in allowed_relevance:
            raise SystemExit(f'Invalid relevance decision for {rid}: {decision["relevance"]}')
        if not any(k in decision for k in ('relevance','geography','species','topic')):
            raise SystemExit(f'No substantive adjudication supplied for {rid}')
        seen[rid]=decision

    missing=sorted(set(queued)-set(seen))
    if missing:
        raise SystemExit('Missing adjudications for queued records: '+', '.join(missing))

    src=d/'records_after_species_geography_adjudication.csv'
    if not src.exists():
        src=d/'records_after_deduplication.csv'
    rows=read_csv(src)
    if not rows:
        raise SystemExit(f'No update records found in {src}')
    fields=list(rows[0].keys())
    for extra in ('human_relevance_decision','human_geography_decision','human_species_decision','human_topic_decision','human_adjudication_reason'):
        if extra not in fields: fields.append(extra)

    for r in rows:
        rid=key_from_row(r)
        dec=seen.get(rid)
        if not dec: continue
        if 'relevance' in dec:
            r['human_relevance_decision']=dec['relevance']
            if 'final_screening_decision' in r: r['final_screening_decision']=dec['relevance']
        if 'geography' in dec:
            val=dec['geography']
            if isinstance(val,list): val='; '.join(val)
            r['human_geography_decision']=str(val)
            for k in ('geography','geography_iso3','country_iso3','deterministic_primary_iso3c'):
                if k in r: r[k]=str(val)
        if 'species' in dec:
            val=dec['species']
            if isinstance(val,list): val='; '.join(val)
            r['human_species_decision']=str(val)
            if 'deterministic_species' in r: r['deterministic_species']=str(val)
        if 'topic' in dec:
            val=dec['topic']
            if isinstance(val,list): val='; '.join(val)
            r['human_topic_decision']=str(val)
        r['human_adjudication_reason']=str(dec.get('reason',''))

    out_csv=out/'records_after_human_adjudication.csv'
    with out_csv.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore')
        w.writeheader(); w.writerows(rows)
    summary={'queued_records':len(queued),'adjudicated_records':len(seen),'source':str(src),'output':str(out_csv)}
    (out/'human_adjudication_summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps(summary))

if __name__=='__main__': main()
