#!/usr/bin/env python3
"""Add bibliographic citation metadata to dashboard.json from the authoritative master."""
import csv, json, re
from pathlib import Path

MASTER = Path('data/master/current/living_evidence_map_master.csv')
DASH = Path('docs/dashboard.json')

ALIASES = {
    'id': ['record_id','id','lens_id','study_id'],
    'authors': ['authors','author','author_names','authors_list','creator','creators','author_list'],
    'journal': ['journal','journal_title','source_title','container_title','publication_name','publication'],
    'volume': ['volume','journal_volume','volume_number'],
    'pages': ['pages','page_range','page','pagination','first_page_last_page'],
    'doi': ['doi','doi_url','digital_object_identifier'],
    'lens': ['lens_url','lens_link','lens_id','lens_document_id'],
}

def pick(fields,names):
    low={f.lower():f for f in fields}; return next((low[n.lower()] for n in names if n.lower() in low),None)
def clean(v): return ' '.join(str(v or '').strip().split())
def normalise_doi(v):
    s=clean(v)
    if not s:return ''
    return re.sub(r'^https?://(dx\.)?doi\.org/','',s,flags=re.I).strip()
def lens_url(v):
    s=clean(v)
    if not s:return ''
    if s.startswith(('http://','https://')):return s
    if s.lower().startswith('lens-'):return 'https://www.lens.org/lens/scholar/'+s
    return ''
if not MASTER.exists() or not DASH.exists(): raise SystemExit('Required dashboard/master file missing')
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); fields=reader.fieldnames or []; rows=reader; cols={k:pick(fields,v) for k,v in ALIASES.items()}; by_id={}
    for row in rows:
        rid=clean(row.get(cols['id'],'')) if cols['id'] else ''
        if not rid:continue
        by_id[rid]={'authors':clean(row.get(cols['authors'],'')) if cols['authors'] else '','journal':clean(row.get(cols['journal'],'')) if cols['journal'] else '','volume':clean(row.get(cols['volume'],'')) if cols['volume'] else '','pages':clean(row.get(cols['pages'],'')) if cols['pages'] else '','doi':normalise_doi(row.get(cols['doi'],'')) if cols['doi'] else '','lens_url':lens_url(row.get(cols['lens'],'')) if cols['lens'] else ''}
payload=json.loads(DASH.read_text(encoding='utf-8'))
for rec in payload.get('records',[]):
    meta=by_id.get(clean(rec.get('record_id','')), {})
    for key in ('authors','journal','volume','pages','lens_url'):rec[key]=meta.get(key,'')
    rec['doi']=normalise_doi(rec.get('doi','') or meta.get('doi',''))
DASH.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
print(f'Added citation metadata to {len(payload.get("records", [])):,} dashboard records')
print('Resolved fields:', ', '.join(f'{k}={v or "MISSING"}' for k,v in cols.items()))
