#!/usr/bin/env python3
"""Apply authoritative dashboard presentation data rules after topic augmentation."""
import csv,json
from collections import Counter,defaultdict,OrderedDict
from pathlib import Path
DASH=Path('docs/dashboard.json'); GAZ=Path('config/global_country_gazetteer_v3.csv')
if not DASH.exists(): raise SystemExit('docs/dashboard.json not found')
def clean(s): return ' '.join(str(s or '').strip().split())
def norm_unspecified(s):
    key=clean(s).lower(); return 'Unspecified species' if key in {'unspecified species','unspecified salmon','unspecified salmon species','salmon unspecified','unspecified salmonid','unspecified salmonid species'} else clean(s)
def pick(fields,names):
    low={f.lower():f for f in fields}; return next((low[n.lower()] for n in names if n.lower() in low),None)
with DASH.open(encoding='utf-8') as f: d=json.load(f)
def path_text(path): return ' > '.join(clean(x) for x in (path or []) if clean(x))
def clean_paths(paths):
    out=[]; seen=set()
    for path in paths or []:
        text=path_text(path)
        if text and text not in seen: seen.add(text); out.append([clean(x) for x in path if clean(x)])
    return out
for r in d.get('records',[]):
    paths=clean_paths(r.get('topic_paths',[])); r['topic_paths']=paths; r['topics']=[path_text(p) for p in paths]; r['topic_path_descriptions']=[d.get('topic_definitions',{}).get(path_text(p),'') for p in paths]; r['species']=[norm_unspecified(x) for x in r.get('species',[]) if clean(x)] or ['Unspecified species']
country_names={}
if GAZ.exists():
    try:
        with GAZ.open(newline='',encoding='utf-8-sig') as f:
            reader=csv.DictReader(f); fields=reader.fieldnames or []; iso_col=pick(fields,['iso3','iso_3','alpha3','iso_alpha3','iso3c','iso_a3','iso_a3c','alpha_3']); name_col=pick(fields,['name','country','country_name','name_en','short_name','official_name','country_name_en'])
            if iso_col and name_col:
                for row in reader:
                    iso=clean(row.get(iso_col,'')).upper(); name=clean(row.get(name_col,''))
                    if iso and name: country_names[iso]=name
    except Exception: pass
d['country_name_by_iso3']=country_names
preferred_named=['Atlantic salmon','Rainbow trout','Chinook salmon','Coho salmon','Sockeye salmon','Chum salmon','Pink salmon','Masu salmon']
sc=d.get('species_counts',{}); ordered=OrderedDict((n,sc[n]) for n in preferred_named if n in sc)
for n,c in sc.items():
    if n not in ordered and n!='Unspecified species': ordered[n]=c
d['species_counts']=dict(ordered); d['species_display_order']=preferred_named+(['Unspecified species'] if 'Unspecified species' in sc else []); d['species_display_labels']={'Unspecified species':'Unspecified salmon'}; d['metrics']['total_species']=sum(1 for n in d['species_counts'] if n!='Unspecified species')
d['species_group_display_order']=d['species_display_order']; d['species_group_counts']={n:sc[n] for n in d['species_display_order'] if n in sc}
sgc=defaultdict(Counter)
for r in d.get('records',[]):
    for s in r.get('species',[]):
        for c in r.get('iso3',[]): sgc[norm_unspecified(s)][str(c).upper()]+=1
d['country_iso3_species_group_counts']={s:dict(sgc[s]) for s in d['species_display_order'] if s in sgc}
# Rebuild the hierarchy from scratch. A record ID is the unit of analysis: one article can contribute only once to each node.
node_ids=defaultdict(set); level_ids=defaultdict(lambda:defaultdict(set)); species_level_ids=defaultdict(lambda:defaultdict(set)); terminal_ids=defaultdict(set)
for r in d.get('records',[]):
    rid=str(r.get('record_id','')).strip()
    if not rid: continue
    unique_paths={tuple(clean(x) for x in p if clean(x)) for p in r.get('topic_paths',[]) if any(clean(x) for x in p)}
    for path in unique_paths:
        for depth in range(1,len(path)+1):
            prefix=path[:depth]; full=' > '.join(prefix); node_ids[full].add(rid); level_ids[depth][full].add(rid)
            for s in r.get('species',[]): species_level_ids[depth][(norm_unspecified(s),full)].add(rid)
        terminal_ids[path[-1]].add(rid)
# Build a tree whose node counts are exactly the unique-record cardinality for that full path.
tree={}
for full,ids in node_ids.items():
    parts=full.split(' > '); parent=tree
    for name in parts:
        node=parent.setdefault(name,{'name':name,'count':0,'children':{}}); parent=node['children']
    # Assign below after the tree structure exists.
for full,ids in node_ids.items():
    parts=full.split(' > '); parent=tree
    for name in parts:
        parent[name]['count']=len(node_ids[' > '.join(parts[:parts.index(name)+1])]) if parts.index(name)==0 else len(node_ids[' > '.join(parts[:parts.index(name)+1])])
        parent=parent[name]['children']
# The loop above is safe for unique names only within a path; set counts again directly to avoid any ambiguity from repeated labels.
def assign_counts(obj,prefix=[]):
    for name,node in obj.items():
        full=' > '.join(prefix+[name]); node['count']=len(node_ids.get(full,set())); assign_counts(node['children'],prefix+[name])
assign_counts(tree)
d['topic_tree']=tree
d['topic_level_counts']={str(level):{topic:len(ids) for topic,ids in sorted(vals.items())} for level,vals in sorted(level_ids.items())}
d['species_topic_level_counts']={str(level):{f'{s}|||{topic}':len(ids) for (s,topic),ids in vals.items()} for level,vals in sorted(species_level_ids.items())}
d['species_group_topic_level_counts']=dict(d['species_topic_level_counts'])
d['topic_counts']={topic:len(ids) for topic,ids in terminal_ids.items()}
d['metrics']['total_topics']=len(node_ids); d['metrics']['records_without_topics']=sum(1 for r in d.get('records',[]) if not r.get('topic_paths'))
d['topic_level_labels']={str(i):('Top-level topic' if i==1 else 'Topic level '+str(i)) for i in sorted(level_ids)}
DASH.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
print(f"Dashboard data fixed: {len(d.get('records',[])):,} records; hierarchy nodes={len(node_ids):,}; unique-record topic counts rebuilt; heatmap counts rebuilt")