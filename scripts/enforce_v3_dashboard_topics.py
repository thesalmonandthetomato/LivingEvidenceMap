#!/usr/bin/env python3
"""Rebuild dashboard topic assignments from the authoritative V3 topic-path field.

This deliberately ignores legacy flat topic fields. The dashboard must never expose
old labels (e.g. Species, Atlantic salmon, Production stage) as ontology topics.
"""
import csv
import json
import re
from pathlib import Path

MASTER = Path('data/master/current/living_evidence_map_master.csv')
ONTOLOGY = Path('data/reference/topic_ontology_v3.csv')
DASHBOARD = Path('docs/dashboard.json')

def clean(value):
    return ' '.join(str(value or '').strip().split())

def parse_paths(value):
    if value is None: return []
    raw = str(value).strip()
    if not raw: return []
    if raw.startswith('[') and raw.endswith(']'):
        try:
            obj = json.loads(raw)
            if isinstance(obj, list):
                if all(isinstance(x, list) for x in obj): return [[clean(v) for v in x if clean(v)] for x in obj]
                raw = '; '.join(str(x) for x in obj)
        except Exception: pass
    paths=[]
    for item in re.split(r'\s*;\s*', raw):
        parts=[clean(x) for x in re.split(r'\s*(?:>|→|>>|/)\s*', item) if clean(x)]
        if parts: paths.append(parts)
    return paths

def ontology_prefixes():
    prefixes=set()
    with ONTOLOGY.open(newline='',encoding='utf-8-sig') as fh:
        for row in csv.DictReader(fh):
            raw=row.get('hierarchy_path','')
            parts=tuple(clean(x) for x in re.split(r'\s*>\s*',raw) if clean(x))
            for i in range(1,len(parts)+1): prefixes.add(parts[:i])
    return prefixes

with MASTER.open(newline='',encoding='utf-8-sig') as fh:
    reader=csv.DictReader(fh); fields=reader.fieldnames or []
    if 'record_id' not in fields: raise SystemExit('Master has no record_id column')
    topic_field='topic_hierarchy_paths' if 'topic_hierarchy_paths' in fields else None
    if not topic_field: raise SystemExit('Master has no authoritative topic_hierarchy_paths column')
    master_topics={str(row.get('record_id','')).strip():parse_paths(row.get(topic_field,'')) for row in reader}

prefixes=ontology_prefixes(); d=json.loads(DASHBOARD.read_text(encoding='utf-8')); changed=0; invalid=[]
for record in d.get('records',[]):
    rid=str(record.get('record_id','')).strip(); raw_paths=master_topics.get(rid,[]); valid_paths=[]
    for path in raw_paths:
        t=tuple(path)
        if t in prefixes: valid_paths.append(path)
        elif t: invalid.append((rid,' > '.join(path)))
    valid_paths=list(dict.fromkeys(tuple(p) for p in valid_paths)); new_topics=list(dict.fromkeys(part for path in valid_paths for part in path)); new_paths=[list(p) for p in valid_paths]
    if record.get('topic_paths')!=new_paths or record.get('topics')!=new_topics: changed+=1
    record['topic_paths']=new_paths; record['topics']=new_topics
    for key in list(record):
        if key.startswith('topic_level_'): del record[key]
    for i in range(1,max((len(p) for p in new_paths),default=0)+1):
        vals=list(dict.fromkeys(p[i-1] for p in new_paths if len(p)>=i))
        if vals: record[f'topic_level_{i}']=vals

d['metrics']['records_without_topics']=sum(1 for r in d.get('records',[]) if not r.get('topic_paths'))
DASHBOARD.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
print(f'Enforced V3 topic paths for {len(d.get("records", [])):,} records; changed {changed:,}; records without valid V3 topics: {d["metrics"]["records_without_topics"]:,}')
if invalid: print(f'Ignored {len(invalid):,} non-V3 paths from the master topic field.')
