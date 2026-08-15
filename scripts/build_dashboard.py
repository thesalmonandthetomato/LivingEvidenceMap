#!/usr/bin/env python3
"""Build dashboard JSON from the validated master."""
import csv,json,re
from pathlib import Path
from collections import Counter
from datetime import datetime,timezone
ROOT=Path('.'); MASTER=ROOT/'data/reference/salmon_evidence_map.csv'; OUT=ROOT/'docs/dashboard.json'; STATE=ROOT/'state'; GAZ=ROOT/'config/global_country_gazetteer_v3.csv'; ISO_MAP=ROOT/'config/iso3_numeric_map.json'
ALIASES={'id':['record_id','id','lens_id','study_id'],'title':['title','article_title','document_title'],'doi':['doi','doi_url','digital_object_identifier'],'abstract':['abstract','abstract_text'],'year':['year','publication_year','date_year'],'species':['final_species','species','farmed_species','deterministic_species','species_assigned','species_assignment','species_name'],'country':['final_primary_country_iso3c','primary_country','primary_countries','country','countries','country_name','country_names','deterministic_primary_countries','geography_primary_country','geography_country'],'iso3':['final_primary_country_iso3c','iso3','iso3c','primary_iso3c','primary_iso3c_codes','deterministic_primary_iso3c','country_iso3c','deterministic_primary_iso3c_codes'],'topics':['topic_hierarchy','topic_hierarchy_paths','hierarchy_path','topics','topic','topic_path'],'updated':['updated_at','update_date','ingested_at','date_added','last_updated']}
TOPIC_EXPLICIT=['broad_topic','subtopic','feature','component']
BAD_TOPIC={'na','n/a','nan','null','none','unknown','unspecified','not applicable',''}

def pick(fields,names):
    low={f.lower():f for f in fields}; return next((low[n.lower()] for n in names if n.lower() in low),None)
def canon_species(s):
    s=' '.join(str(s or '').strip().split()); k=s.lower()
    if not s or k in BAD_TOPIC or ('unspecified' in k and ('salmon' in k or 'salmonid' in k or 'species' in k)): return 'Unspecified species'
    if k in {'rainbow salmon','rainbow_trout','rainbow trout'}: return 'Rainbow trout'
    return s
def clean_topic(s):
    s=' '.join(str(s or '').strip().split()); return '' if s.lower() in BAD_TOPIC else s
def splitvals(value):
    if value is None:return []
    s=str(value).strip()
    if not s or s.lower() in BAD_TOPIC:return []
    if s.startswith('[') and s.endswith(']'):
        try:return [str(i).strip() for i in json.loads(s) if clean_topic(i)]
        except Exception:pass
    return [x for x in (clean_topic(x) for x in re.split(r'\s*;\s*|\s*\|\s*|\s*→\s*|\s*>>\s*',s)) if x]
def hierarchy_paths(value):
    if not value:return []
    raw=str(value).strip()
    if raw.startswith('[') and raw.endswith(']'):
        try:
            obj=json.loads(raw)
            if isinstance(obj,list): raw='; '.join(str(x) for x in obj)
        except Exception:pass
    out=[]
    for p in re.split(r'\s*;\s*',raw):
        parts=[x for x in (clean_topic(x) for x in re.split(r'\s*(?:→|>>|/|>)\s*',p)) if x]
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
    for p in (STATE/'search_baseline.json',STATE/'search_history.json'):
        if not p.exists():continue
        try:
            obj=json.loads(p.read_text()); items=[obj] if p.name.endswith('baseline.json') else (obj if isinstance(obj,list) else obj.get('runs',[]))
            for item in items:
                n=number((item or {}).get('original_search_results') if p.name.endswith('baseline.json') else (item or {}).get('candidate_results'))
                if n is not None: total+=n; found=True
        except Exception:pass
    return total if found else None
def iso_numeric_map():
    try:
        if ISO_MAP.exists():
            obj=json.loads(ISO_MAP.read_text(encoding='utf-8'))
            if isinstance(obj,dict): return {str(k).upper():str(v).zfill(3) for k,v in obj.items() if v is not None and str(v).strip()}
    except Exception: pass
    if not GAZ.exists():return {}
    try:
        with GAZ.open(newline='',encoding='utf-8-sig') as f:
            rows=csv.DictReader(f); fields=rows.fieldnames or []
            a=pick(fields,['iso3','iso_3','alpha3','iso_alpha3','iso3c','iso_a3','iso_a3c','alpha_3']); b=pick(fields,['iso_numeric','iso_num','numeric','numeric_code','m49','country_code_numeric','iso_numeric_code','iso_n3','iso_n'])
            if not a or not b:return {}
            return {str(r[a]).strip().upper():str(r[b]).strip().zfill(3) for r in rows if r.get(a) and r.get(b)}
    except Exception:return {}
if not MASTER.exists():raise SystemExit(f'Master not found: {MASTER}')
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); fields=reader.fieldnames or []; rows=list(reader)
f={k:pick(fields,v) for k,v in ALIASES.items()}; explicit_topics=[x for x in TOPIC_EXPLICIT if x in fields]; topic_fields=topic_level_fields(fields)
records=[]; species=Counter(); countries=Counter(); iso=Counter(); topics=Counter(); by_level={}; species_topic_level={}; latest=None; missing_topic_records=[]
for row in rows:
    sp=[canon_species(x) for x in (splitvals(row.get(f['species'],'')) if f['species'] else [])] or ['Unspecified species']; sp=list(dict.fromkeys(sp))
    ix=[str(x).upper() for x in (splitvals(row.get(f['iso3'],'')) if f['iso3'] else [])]; co=ix[:]
    if f['country'] and f['country'] != f['iso3']:
        named=splitvals(row.get(f['country'],''));
        if named: co=named
    paths=hierarchy_paths(row.get(f['topics'],'')) if f['topics'] else []
    levels={}
    if paths:
        for i in range(1,max(len(p) for p in paths)+1):
            vals=list(dict.fromkeys(p[i-1] for p in paths if len(p)>=i and p[i-1]));
            if vals: levels[str(i)]=vals
    else:
        for i,field in enumerate(explicit_topics,1):
            vals=splitvals(row.get(field,''));
            if vals: levels[str(i)]=vals
        for i,field in enumerate(topic_fields,1):
            vals=splitvals(row.get(field,''));
            if vals and str(i) not in levels: levels[str(i)]=vals
    alltopics=list(dict.fromkeys(x for vals in levels.values() for x in vals if x))
    if not alltopics: missing_topic_records.append(row.get(f['id'],'') if f['id'] else '')
    for x in sp: species[x]+=1
    for x in co:countries[x]+=1
    for x in ix:iso[x]+=1
    for x in alltopics:topics[x]+=1
    for level,vals in levels.items():
        by_level.setdefault(level,Counter()); species_topic_level.setdefault(level,Counter())
        for x in vals:by_level[level][x]+=1
        for s in sp:
            if s!='Unspecified species':
                for x in vals: species_topic_level[level][(s,x)]+=1
    if f['updated'] and row.get(f['updated']):latest=max(latest or '',str(row[f['updated']]))
    rec={'record_id':row.get(f['id'],'') if f['id'] else '','title':row.get(f['title'],'') if f['title'] else '','doi':row.get(f['doi'],'') if f['doi'] else '','abstract':row.get(f['abstract'],'') if f['abstract'] else '','year':row.get(f['year'],'') if f['year'] else '','species':sp,'countries':co,'iso3':ix,'topics':alltopics,'topic_paths':paths}
    for level,vals in levels.items():rec['topic_level_'+level]=vals
    records.append(rec)
map_iso=iso_numeric_map(); country_map={map_iso[k]:v for k,v in iso.items() if k in map_iso}; map_id_to_iso3={v:k for k,v in map_iso.items()}
payload={'generated_at':datetime.now(timezone.utc).isoformat(),'metrics':{'last_update':latest,'total_records':len(rows),'total_countries':len(countries),'total_species':len(species),'total_topics':0,'candidate_search_results_screened':search_total(),'records_without_topics':len(missing_topic_records)},'species_counts':dict((s,n) for s,n in species.most_common() if s!='Unspecified species'),'country_counts':dict(countries.most_common()),'country_iso3_counts':dict(country_map),'map_id_to_iso3':map_id_to_iso3,'topic_counts':dict(topics.most_common()),'topic_level_counts':{k:dict(v.most_common()) for k,v in sorted(by_level.items(),key=lambda x:int(x[0]))},'species_topic_level_counts':{level:{f'{s}|||{t}':n for (s,t),n in counts.items()} for level,counts in sorted(species_topic_level.items(),key=lambda x:int(x[0]))},'topic_level_fields':topic_fields,'records':records,'missing_topic_record_ids':missing_topic_records}
OUT.parent.mkdir(parents=True,exist_ok=True); OUT.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8'); print(f'Built dashboard data: {len(records):,} records; countries={len(countries):,}; mapped ISO3 countries={len(country_map):,}; species={len(payload["species_counts"]):,}; topics={len(topics):,}; records_without_topics={len(missing_topic_records):,}')
