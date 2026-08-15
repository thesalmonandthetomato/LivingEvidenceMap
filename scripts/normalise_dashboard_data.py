#!/usr/bin/env python3
"""Normalise species labels and dashboard metrics without changing the master."""
import json, re
from collections import Counter
from pathlib import Path

DASH=Path('docs/dashboard.json')


def canon(s):
    s=str(s or '').strip()
    if not s: return ''
    key=re.sub(r'\s+',' ',s).lower()
    if 'unspecified' in key and any(x in key for x in ('salmon','salmonid','species')):
        return 'Unspecified species'
    if key == 'rainbow salmon': return 'Rainbow salmon'
    return s


def norm_list(xs):
    out=[]
    for x in xs or []:
        c=canon(x)
        if c and c not in out: out.append(c)
    return out

with DASH.open(encoding='utf-8') as f: d=json.load(f)

# Canonicalise record-level species labels and keep the generic category out of
# species-facing dashboard selectors/analytics.
for r in d.get('records',[]):
    r['species']=norm_list(r.get('species',[]))
    for k,v in list(r.items()):
        if k.startswith('species') and isinstance(v,list): r[k]=norm_list(v)

species=Counter()
for r in d.get('records',[]):
    for s in r.get('species',[]):
        if s != 'Unspecified species': species[s]+=1

d['species_counts']=dict(species.most_common())

# Rebuild country × species counts from the dashboard records. This uses the
# record-level ISO3 annotations already present in the master/dashboard data.
cs={}
all_iso=Counter()
for r in d.get('records',[]):
    countries=[str(x).upper() for x in (r.get('iso3') or []) if str(x).strip()]
    for c in countries: all_iso[c]+=1
    for s in r.get('species',[]):
        if s == 'Unspecified species': continue
        b=cs.setdefault(s,Counter())
        for c in countries: b[c]+=1

d['country_iso3_counts']=dict(all_iso)
d['country_iso3_species_counts']={s:dict(c) for s,c in cs.items()}

# Count only finest-level topic assignments per record for the dashboard's
# headline/topic total. The full hierarchy remains available for heatmaps.
finest=Counter()
finest_assignments=0
for r in d.get('records',[]):
    levels=[]
    for k,v in r.items():
        m=re.fullmatch(r'topic_level_(\d+)',k)
        if m and isinstance(v,list) and v:
            levels.append((int(m.group(1)),v))
    if levels:
        _,vals=max(levels,key=lambda x:x[0])
        for t in dict.fromkeys(str(x).strip() for x in vals if str(x).strip()):
            finest[t]+=1; finest_assignments+=1

d['topic_counts']=dict(finest.most_common())
d['metrics']['total_topics']=finest_assignments
# The requested dashboard update date is the publication/update date for this release.
d['metrics']['last_update']='2026-08-13'

with DASH.open('w',encoding='utf-8') as f:
    json.dump(d,f,ensure_ascii=False,separators=(',',':'))
print(f"Normalised dashboard: species={len(species):,}; finest_topic_assignments={finest_assignments:,}; countries={len(all_iso):,}")
