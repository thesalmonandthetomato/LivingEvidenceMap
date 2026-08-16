#!/usr/bin/env python3
"""Apply the authoritative dashboard presentation data rules after topic augmentation."""
import csv
import json
from collections import Counter, defaultdict, OrderedDict
from pathlib import Path

DASH = Path('docs/dashboard.json')
GAZ = Path('config/global_country_gazetteer_v3.csv')
if not DASH.exists(): raise SystemExit('docs/dashboard.json not found')

def clean(s): return ' '.join(str(s or '').strip().split())
def norm_unspecified(s):
    key=clean(s).lower()
    return 'Unspecified species' if key in {'unspecified species','unspecified salmon','unspecified salmon species','salmon unspecified','unspecified salmonid','unspecified salmonid species'} else clean(s)
def pick(fields,names):
    low={f.lower():f for f in fields}
    return next((low[n.lower()] for n in names if n.lower() in low),None)
with DASH.open(encoding='utf-8') as f: d=json.load(f)

def path_text(path): return ' > '.join(clean(x) for x in (path or []) if clean(x))
def clean_paths(paths):
    out=[]; seen=set()
    for path in paths or []:
        text=path_text(path)
        if text and text not in seen:
            seen.add(text); out.append([clean(x) for x in path if clean(x)])
    return out
for r in d.get('records',[]):
    paths=clean_paths(r.get('topic_paths',[])); r['topic_paths']=paths
    r['topics']=[path_text(p) for p in paths]
    r['topic_path_descriptions']=[d.get('topic_definitions',{}).get(path_text(p),'') for p in paths]
    r['species']=[norm_unspecified(x) for x in r.get('species',[]) if clean(x)] or ['Unspecified species']

country_names={}
if GAZ.exists():
    try:
        with GAZ.open(newline='',encoding='utf-8-sig') as f:
            reader=csv.DictReader(f); fields=reader.fieldnames or []
            iso_col=pick(fields,['iso3','iso_3','alpha3','iso_alpha3','iso3c','iso_a3','iso_a3c','alpha_3'])
            name_col=pick(fields,['name','country','country_name','name_en','short_name','official_name','country_name_en'])
            if iso_col and name_col:
                for row in reader:
                    iso=clean(row.get(iso_col,'')).upper(); name=clean(row.get(name_col,''))
                    if iso and name: country_names[iso]=name
    except Exception: pass
d['country_name_by_iso3']=country_names

# Eight named species are represented. The UI groups Pacific salmon as Other salmon.
preferred_named=['Atlantic salmon','Rainbow trout','Chinook salmon','Coho salmon','Sockeye salmon','Chum salmon','Pink salmon','Masu salmon']
sc=d.get('species_counts',{}); ordered=OrderedDict((n,sc[n]) for n in preferred_named if n in sc)
for n,c in sc.items():
    if n not in ordered and n!='Unspecified species': ordered[n]=c
d['species_counts']=dict(ordered)
d['species_display_order']=preferred_named+(['Unspecified species'] if 'Unspecified species' in sc else [])
d['species_display_labels']={'Unspecified species':'Unspecified salmon'}
d['metrics']['total_species']=sum(1 for n in d['species_counts'] if n!='Unspecified species')

def group_for(s):
    s=norm_unspecified(s)
    if s=='Atlantic salmon': return 'Atlantic salmon'
    if s=='Rainbow trout': return 'Rainbow trout'
    if s=='Unspecified species': return 'Unspecified salmon'
    return 'Other salmon'
groups=['Atlantic salmon','Rainbow trout','Other salmon','Unspecified salmon']
gc=Counter(); gcc=defaultdict(Counter)
for r in d.get('records',[]):
    for s in r.get('species',[]):
        g=group_for(s); gc[g]+=1
        for c in r.get('iso3',[]): gcc[g][str(c).upper()]+=1
d['species_group_display_order']=groups
d['species_group_counts']={g:gc[g] for g in groups if gc[g]}
d['country_iso3_species_group_counts']={g:dict(gcc[g]) for g in groups if g in gcc}
gtc=defaultdict(Counter)
for r in d.get('records',[]):
    paths={tuple(p) for p in r.get('topic_paths',[])}
    for s in r.get('species',[]):
        g=group_for(s)
        for path in paths:
            for level in range(1,len(path)+1): gtc[str(level)][(g,' > '.join(path[:level]))]+=1
d['species_group_topic_level_counts']={lev:{f'{g}|||{t}':n for (g,t),n in vals.items()} for lev,vals in gtc.items()}
d['metrics']['records_without_topics']=sum(1 for r in d.get('records',[]) if not r.get('topic_paths'))
DASH.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
print(f"Dashboard presentation data fixed: records={len(d.get('records',[])):,}; named species={d['metrics']['total_species']}; UI groups={len(groups)}; database topics use ' > ' hierarchy paths; country names={len(country_names):,}")
