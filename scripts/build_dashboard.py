#!/usr/bin/env python3
"""Build the static JSON consumed by the GitHub Pages evidence-map dashboard.

The script deliberately discovers common field names rather than hard-coding one
master schema. The dashboard is rebuilt from the current master after updates.
"""
import csv, json, re
from pathlib import Path
from collections import Counter, defaultdict
from datetime import datetime, timezone

ROOT = Path('.')
MASTER = ROOT / 'data/reference/salmon_evidence_map.csv'
OUT = ROOT / 'docs/dashboard.json'
STATE = ROOT / 'state'

ALIASES = {
    'id': ['record_id','id','lens_id','study_id'],
    'title': ['title','article_title'],
    'abstract': ['abstract','abstract_text'],
    'year': ['year','publication_year','date_year'],
    'species': ['species','farmed_species','deterministic_species','species_assigned','species_assignment'],
    'country': ['country','countries','primary_country','primary_countries','deterministic_primary_countries','geography','geography_country'],
    'iso3': ['iso3','iso3c','primary_iso3c','deterministic_primary_iso3c','country_iso3c'],
    'topics': ['topics','topic','topic_hierarchy','topic_path'],
    'updated': ['updated_at','update_date','ingested_at','date_added','last_updated'],
}

def pick(fields, names):
    low = {f.lower(): f for f in fields}
    return next((low[n.lower()] for n in names if n.lower() in low), None)

def splitvals(value):
    if value is None: return []
    s = str(value).strip()
    if not s or s.lower() in {'na','nan','null','none','[]'}: return []
    if s.startswith('[') and s.endswith(']'):
        try:
            x = json.loads(s)
            return [str(i).strip() for i in x if str(i).strip()]
        except Exception:
            pass
    return [x.strip() for x in re.split(r'\s*;\s*|\s*\|\s*|\s*→\s*', s) if x.strip()]

def topic_level_fields(fields):
    found=[]
    for f in fields:
        fl=f.lower()
        if 'topic' in fl and re.search(r'(?:level|lvl|l)[ _-]?\d+', fl): found.append(f)
    return sorted(set(found), key=lambda f: (int(re.search(r'(?:level|lvl|l)[ _-]?(\d+)', f.lower()).group(1)), f.lower()))

def number(value):
    try: return int(float(str(value)))
    except Exception: return None

def search_total():
    """Use an explicit cumulative search history if present; never invent a value."""
    paths=[STATE/'search_history.json', STATE/'search_history.csv', STATE/'lens_search_history.json']
    total=0; found=False
    keys=['candidate_results','candidate_count','total_results','results','records_returned','screened_count']
    for p in paths:
        if not p.exists(): continue
        try:
            if p.suffix == '.json':
                obj=json.loads(p.read_text(encoding='utf-8'))
                items=obj if isinstance(obj,list) else obj.get('runs', obj.get('history', []))
                if isinstance(items,dict): items=[items]
                for item in items:
                    if isinstance(item,dict):
                        n=next((number(item.get(k)) for k in keys if number(item.get(k)) is not None),None)
                        if n is not None: total += n; found=True
            else:
                with p.open(newline='',encoding='utf-8-sig') as f:
                    for item in csv.DictReader(f):
                        n=next((number(item.get(k)) for k in keys if number(item.get(k)) is not None),None)
                        if n is not None: total += n; found=True
        except Exception:
            continue
    return total if found else None

if not MASTER.exists(): raise SystemExit(f'Master not found: {MASTER}')
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); fields=reader.fieldnames or []; rows=list(reader)

f={k:pick(fields,v) for k,v in ALIASES.items()}
topic_fields=topic_level_fields(fields)
records=[]
species=Counter(); countries=Counter(); iso=Counter(); topics=Counter(); by_level={}
for i,field in enumerate(topic_fields,1): by_level[str(i)]=Counter()
species_topic=Counter(); species_topic_level={str(i):Counter() for i in range(1,len(topic_fields)+1)}
latest=None
for row in rows:
    sp=splitvals(row.get(f['species'],'')) if f['species'] else ['Unspecified']; sp=sp or ['Unspecified']
    co=splitvals(row.get(f['country'],'')) if f['country'] else []
    ix=splitvals(row.get(f['iso3'],'')) if f['iso3'] else []
    lv={str(i):splitvals(row.get(field,'')) for i,field in enumerate(topic_fields,1)}
    alltopics=splitvals(row.get(f['topics'],'')) if f['topics'] else []
    if not alltopics:
        for vals in lv.values(): alltopics.extend(vals)
    for x in sp: species[x]+=1
    for x in co: countries[x]+=1
    for x in ix: iso[x]+=1
    for x in alltopics: topics[x]+=1
    for level,vals in lv.items():
        for x in vals: by_level[level][x]+=1
    for s in sp:
        for t in alltopics: species_topic[(s,t)]+=1
        for level,vals in lv.items():
            for t in vals: species_topic_level[level][(s,t)]+=1
    if f['updated'] and row.get(f['updated']): latest=max(latest or '',str(row[f['updated']]))
    rec={'record_id':row.get(f['id'],'') if f['id'] else '', 'title':row.get(f['title'],'') if f['title'] else '', 'abstract':row.get(f['abstract'],'') if f['abstract'] else '', 'year':row.get(f['year'],'') if f['year'] else '', 'species':sp, 'countries':co, 'iso3':ix, 'topics':alltopics}
    for level,vals in lv.items(): rec['topic_level_'+level]=vals
    records.append(rec)

payload={
 'generated_at':datetime.now(timezone.utc).isoformat(),
 'metrics':{'last_update':latest,'total_records':len(rows),'total_countries':len(countries),'total_species':len(species),'total_topics':len(topics),'candidate_search_results_screened':search_total(),'topics_by_level':{k:dict(v.most_common()) for k,v in by_level.items()}},
 'species_counts':dict(species.most_common()), 'country_counts':dict(countries.most_common()), 'country_iso3_counts':dict(iso),
 'topic_counts':dict(topics.most_common()), 'topic_level_counts':{k:dict(v.most_common()) for k,v in by_level.items()},
 'species_topic_counts':{f'{s}|||{t}':n for (s,t),n in species_topic.items()},
 'species_topic_level_counts':{level:{f'{s}|||{t}':n for (s,t),n in counts.items()} for level,counts in species_topic_level.items()},
 'topic_level_fields':topic_fields, 'records':records
}
OUT.parent.mkdir(parents=True,exist_ok=True)
OUT.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
print(f'Built dashboard data: {len(records):,} records')
