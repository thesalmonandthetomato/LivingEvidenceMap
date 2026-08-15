#!/usr/bin/env python3
"""Build dashboard JSON from the validated master."""
import csv,json,re
from pathlib import Path
from collections import Counter
from datetime import datetime,timezone
ROOT=Path('.'); MASTER=ROOT/'data/reference/salmon_evidence_map.csv'; OUT=ROOT/'docs/dashboard.json'; STATE=ROOT/'state'; GAZ=ROOT/'config/global_country_gazetteer_v3.csv'
ALIASES={'id':['record_id','id','lens_id','study_id'],'title':['title','article_title','document_title'],'abstract':['abstract','abstract_text'],'year':['year','publication_year','date_year'],'species':['final_species','species','farmed_species','deterministic_species','species_assigned','species_assignment','species_name'],'country':['final_primary_country_iso3c','primary_country','primary_countries','country','countries','country_name','country_names','deterministic_primary_countries','geography_primary_country','geography_country'],'iso3':['final_primary_country_iso3c','iso3','iso3c','primary_iso3c','primary_iso3c_codes','deterministic_primary_iso3c','country_iso3c'],'topics':['topic_hierarchy','topic_hierarchy_paths','hierarchy_path','topics','topic','topic_path'],'updated':['updated_at','update_date','ingested_at','date_added','last_updated']}
TOPIC_EXPLICIT=['broad_topic','subtopic','feature','component']
def pick(fields,names):
    low={f.lower():f for f in fields}; return next((low[n.lower()] for n in names if n.lower() in low),None)
def splitvals(value):
    if value is None:return []
    s=str(value).strip()
    if not s or s.lower() in {'na','nan','null','none','[]'}:return []
    if s.startswith('[') and s.endswith(']'):
        try:return [str(i).strip() for i in json.loads(s) if str(i).strip()]
        except Exception:pass
    return [x.strip() for x in re.split(r'\s*;\s*|\s*\|\s*|\s*→\s*|\s*>>\s*',s) if x.strip()]
def hierarchy_paths(value):
    if not value:return []
    raw=str(value).strip()
    if raw.startswith('[') and raw.endswith(']'):
        try:raw='; '.join(str(x) for x in json.loads(raw))
        except Exception:pass
    out=[]
    for p in re.split(r'\s*;\s*',raw):
        parts=[x.strip() for x in re.split(r'\s*(?:→|>>|/|>)\s*',p) if x.strip()]
        if parts:out.append(parts)
    return out
def topic_level_fields(fields):
    found=[f for f in fields if 'topic' in f.lower() and re.search(r'(?:level|lvl|l)[ _-]?\d+',f.lower())]
    return sorted(set(found),key=lambda f:int(re.search(r'(?:level|lvl|l)[ _-]?(\d+)',f.lower()).group(1)))
def number(v):
    try:return int(float(str(v)))
    except Exception:return None
def search_total():
    total=0; found=False
    p=STATE/'search_baseline.json'
    if p.exists():
        try:
            n=number(json.loads(p.read_text()).get('original_search_results'))
            if n is not None:total+=n;found=True
        except Exception:pass
    p=STATE/'search_history.json'
    if p.exists():
        try:
            obj=json.loads(p.read_text()); items=obj if isinstance(obj,list) else obj.get('runs',[])
            for item in items:
                n=number(item.get('candidate_results')) if isinstance(item,dict) else None
                if n is not None:total+=n;found=True
        except Exception:pass
    return total if found else None
def iso_numeric_map():
    if not GAZ.exists():return {}
    try:
        with GAZ.open(newline='',encoding='utf-8-sig') as f:
            rows=csv.DictReader(f); fields=rows.fieldnames or []
            a=pick(fields,['iso3','iso_3','alpha3','iso_alpha3','iso3c']); b=pick(fields,['iso_numeric','iso_num','numeric','numeric_code','m49','country_code_numeric','iso_numeric_code'])
            if not a or not b:return {}
            return {str(r[a]).strip().upper():str(r[b]).strip().zfill(3) for r in rows if r.get(a) and r.get(b)}
    except Exception:return {}
if not MASTER.exists():raise SystemExit(f'Master not found: {MASTER}')
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); fields=reader.fieldnames or []; rows=list(reader)
f={k:pick(fields,v) for k,v in ALIASES.items()}; explicit_topics=[x for x in TOPIC_EXPLICIT if x in fields]; topic_fields=topic_level_fields(fields)
records=[]; species=Counter(); countries=Counter(); iso=Counter(); topics=Counter(); by_level={}; species_topic_level={}; latest=None
for row in rows:
    sp=splitvals(row.get(f['species'],'')) if f['species'] else []
    if not sp: sp=['Unspecified']
    # final_primary_country_iso3c is both the authoritative historical geography field and a valid ISO3 source.
    ix=splitvals(row.get(f['iso3'],'')) if f['iso3'] else []
    co=ix[:]
    # If a human-readable country field exists, retain it for the table; ISO remains the map key.
    if f['country'] and f['country'] != f['iso3']:
        named=splitvals(row.get(f['country'],''))
        if named: co=named
    levels={str(i):splitvals(row.get(field,'')) for i,field in enumerate(explicit_topics,1)}
    detected_start=len(levels)+1
    detected=topic_level_fields(fields)
    for i,field in enumerate(detected,1):
        vals=splitvals(row.get(field,''))
        if vals and not levels.get(str(i)): levels[str(i)]=vals
    paths=hierarchy_paths(row.get(f['topics'],'')) if f['topics'] else []
    for i in range(1,max((len(p) for p in paths),default=0)+1):
        vals=[]
        for p in paths:
            if len(p)>=i and p[i-1] not in vals:vals.append(p[i-1])
        if vals and not levels.get(str(i)):levels[str(i)]=vals
    alltopics=[]
    for vals in levels.values():
        for x in vals:
            if x not in alltopics:alltopics.append(x)
    if not alltopics and f['topics']:alltopics=splitvals(row.get(f['topics'],''))
    for x in sp:species[x]+=1
    for x in co:countries[x]+=1
    for x in ix:iso[x]+=1
    for x in alltopics:topics[x]+=1
    for level,vals in levels.items():
        by_level.setdefault(level,Counter()); species_topic_level.setdefault(level,Counter())
        for x in vals:by_level[level][x]+=1
        for s in sp:
            for x in vals:species_topic_level[level][(s,x)]+=1
    if f['updated'] and row.get(f['updated']):latest=max(latest or '',str(row[f['updated']]))
    rec={'record_id':row.get(f['id'],'') if f['id'] else '','title':row.get(f['title'],'') if f['title'] else '','abstract':row.get(f['abstract'],'') if f['abstract'] else '','year':row.get(f['year'],'') if f['year'] else '','species':sp,'countries':co,'iso3':ix,'topics':alltopics}
    for level,vals in levels.items():rec['topic_level_'+level]=vals
    records.append(rec)
map_iso=iso_numeric_map(); country_map={map_iso.get(k,k):v for k,v in iso.items()}
payload={'generated_at':datetime.now(timezone.utc).isoformat(),'metrics':{'last_update':latest,'total_records':len(rows),'total_countries':len(countries),'total_species':len(species),'total_topics':len(topics),'candidate_search_results_screened':search_total(),'topics_by_level':{k:dict(v.most_common()) for k,v in sorted(by_level.items(),key=lambda x:int(x[0]))}},'species_counts':dict(species.most_common()),'country_counts':dict(countries.most_common()),'country_iso3_counts':dict(country_map),'topic_counts':dict(topics.most_common()),'topic_level_counts':{k:dict(v.most_common()) for k,v in sorted(by_level.items(),key=lambda x:int(x[0]))},'species_topic_level_counts':{level:{f'{s}|||{t}':n for (s,t),n in counts.items()} for level,counts in sorted(species_topic_level.items(),key=lambda x:int(x[0]))},'topic_level_fields':topic_fields,'records':records}
OUT.parent.mkdir(parents=True,exist_ok=True); OUT.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8'); print(f'Built dashboard data: {len(records):,} records; countries={len(countries):,}; iso3={len(iso):,}; topics={len(topics):,}; species={len(species):,}')
