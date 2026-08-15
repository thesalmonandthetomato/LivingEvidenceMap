#!/usr/bin/env python3
"""Build the static JSON consumed by the GitHub Pages evidence-map dashboard."""
import csv, json, re
from pathlib import Path
from collections import Counter
from datetime import datetime, timezone

ROOT=Path('.'); MASTER=ROOT/'data/reference/salmon_evidence_map.csv'; OUT=ROOT/'docs/dashboard.json'; STATE=ROOT/'state'
ALIASES={'id':['record_id','id','lens_id','study_id'],'title':['title','article_title'],'abstract':['abstract','abstract_text'],'year':['year','publication_year','date_year'],'species':['species','farmed_species','deterministic_species','species_assigned','species_assignment'],'country':['country','countries','primary_country','primary_countries','deterministic_primary_countries','geography','geography_country'],'iso3':['iso3','iso3c','primary_iso3c','deterministic_primary_iso3c','country_iso3c'],'topics':['topics','topic','topic_hierarchy','topic_path'],'updated':['updated_at','update_date','ingested_at','date_added','last_updated']}

def pick(fields,names):
    low={f.lower():f for f in fields}; return next((low[n.lower()] for n in names if n.lower() in low),None)
def splitvals(value):
    if value is None:return []
    s=str(value).strip()
    if not s or s.lower() in {'na','nan','null','none','[]'}:return []
    if s.startswith('[') and s.endswith(']'):
        try:return [str(i).strip() for i in json.loads(s) if str(i).strip()]
        except Exception:pass
    return [x.strip() for x in re.split(r'\s*;\s*|\s*\|\s*|\s*→\s*',s) if x.strip()]
def topic_level_fields(fields):
    found=[f for f in fields if 'topic' in f.lower() and re.search(r'(?:level|lvl|l)[ _-]?\d+',f.lower())]
    return sorted(set(found),key=lambda f:(int(re.search(r'(?:level|lvl|l)[ _-]?(\d+)',f.lower()).group(1)),f.lower()))
def number(v):
    try:return int(float(str(v)))
    except Exception:return None

def search_total():
    """Return original baseline + cumulative weekly candidate-result counts when recorded."""
    total=0; found=False
    baseline=STATE/'search_baseline.json'
    if baseline.exists():
        try:
            n=number(json.loads(baseline.read_text(encoding='utf-8')).get('original_search_results'))
            if n is not None: total+=n; found=True
        except Exception:pass
    history=STATE/'search_history.json'
    if history.exists():
        try:
            obj=json.loads(history.read_text(encoding='utf-8')); items=obj if isinstance(obj,list) else obj.get('runs',[])
            for item in items:
                n=number(item.get('candidate_results')) if isinstance(item,dict) else None
                if n is not None: total+=n; found=True
        except Exception:pass
    return total if found else None

if not MASTER.exists():raise SystemExit(f'Master not found: {MASTER}')
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); fields=reader.fieldnames or []; rows=list(reader)
f={k:pick(fields,v) for k,v in ALIASES.items()}; topic_fields=topic_level_fields(fields)
records=[]; species=Counter(); countries=Counter(); iso=Counter(); topics=Counter(); by_level={str(i):Counter() for i in range(1,len(topic_fields)+1)}; species_topic_level={str(i):Counter() for i in range(1,len(topic_fields)+1)}; latest=None
for row in rows:
    sp=splitvals(row.get(f['species'],'')) if f['species'] else ['Unspecified']; sp=sp or ['Unspecified']; co=splitvals(row.get(f['country'],'')) if f['country'] else []; ix=splitvals(row.get(f['iso3'],'')) if f['iso3'] else []
    lv={str(i):splitvals(row.get(field,'')) for i,field in enumerate(topic_fields,1)}; alltopics=splitvals(row.get(f['topics'],'')) if f['topics'] else []
    if not alltopics:
        for vals in lv.values():alltopics.extend(vals)
    for x in sp:species[x]+=1
    for x in co:countries[x]+=1
    for x in ix:iso[x]+=1
    for x in alltopics:topics[x]+=1
    for level,vals in lv.items():
        for x in vals:by_level[level][x]+=1
        for s in sp:
            for x in vals:species_topic_level[level][(s,x)]+=1
    if f['updated'] and row.get(f['updated']):latest=max(latest or '',str(row[f['updated']]))
    rec={'record_id':row.get(f['id'],'') if f['id'] else '','title':row.get(f['title'],'') if f['title'] else '','abstract':row.get(f['abstract'],'') if f['abstract'] else '','year':row.get(f['year'],'') if f['year'] else '','species':sp,'countries':co,'iso3':ix,'topics':alltopics}
    for level,vals in lv.items():rec['topic_level_'+level]=vals
    records.append(rec)
payload={'generated_at':datetime.now(timezone.utc).isoformat(),'metrics':{'last_update':latest,'total_records':len(rows),'total_countries':len(countries),'total_species':len(species),'total_topics':len(topics),'candidate_search_results_screened':search_total(),'topics_by_level':{k:dict(v.most_common()) for k,v in by_level.items()}},'species_counts':dict(species.most_common()),'country_counts':dict(countries.most_common()),'country_iso3_counts':dict(iso),'topic_counts':dict(topics.most_common()),'topic_level_counts':{k:dict(v.most_common()) for k,v in by_level.items()},'species_topic_level_counts':{level:{f'{s}|||{t}':n for (s,t),n in counts.items()} for level,counts in species_topic_level.items()},'topic_level_fields':topic_fields,'records':records}
OUT.parent.mkdir(parents=True,exist_ok=True); OUT.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8'); print(f'Built dashboard data: {len(records):,} records')
