#!/usr/bin/env python3
import json
from pathlib import Path
from collections import Counter,defaultdict
p=Path('docs/dashboard.json'); d=json.loads(p.read_text(encoding='utf-8')); records=d.get('records',[])
def canon(s):
 k=' '.join(str(s).strip().lower().split())
 if k in {'unspecified','unspecified salmon','unspecified salmon species','unspecified salmonid','unspecified salmonid species','salmon unspecified','unspecified species'}: return 'Unspecified species'
 if k in {'rainbow salmon','rainbow trout'}: return 'Rainbow trout'
 return str(s).strip()
for r in records: r['species']=[canon(x) for x in r.get('species',[]) if canon(x)] or ['Unspecified species']
cs=defaultdict(Counter); sc=Counter(); terminal=Counter(); level_counts=defaultdict(Counter); species_level=defaultdict(Counter); tree={}
for r in records:
 for s in r['species']:
  sc[s]+=1
  for c in r.get('iso3',[]): cs[s][str(c).upper()]+=1
 levels=[]
 for k,v in r.items():
  if k.startswith('topic_level_') and isinstance(v,list) and v: levels.append((int(k.rsplit('_',1)[1]),v))
 if levels:
  deepest=max(i for i,v in levels)
  for x in dict.fromkeys(next(v for i,v in levels if i==deepest)): terminal[x]+=1
  vals={i:v for i,v in levels}
  curmaps=[tree]
  for lev in sorted(vals):
   nextmaps=[]
   for parentmap in curmaps:
    for name in vals[lev]:
     node=parentmap.setdefault(name,{'name':name,'count':0,'children':{}}); node['count']+=1; nextmaps.append(node['children'])
   curmaps=nextmaps
  for i,v in levels:
   for x in v: level_counts[str(i)][x]+=1
   for s in r['species']:
    if s!='Unspecified species':
     for x in v: species_level[str(i)][(s,x)]+=1
d['species_counts']={k:v for k,v in sc.most_common() if k!='Unspecified species'}
d['country_iso3_species_counts']={s:dict(c) for s,c in cs.items() if s!='Unspecified species'}
d['topic_counts']=dict(terminal.most_common()); d['metrics']['total_topics']=len(terminal); d['metrics']['total_species']=len(d['species_counts'])
d['topic_level_counts']={k:dict(v.most_common()) for k,v in sorted(level_counts.items(),key=lambda x:int(x[0]))}
d['species_topic_level_counts']={lev:{f'{s}|||{t}':n for (s,t),n in c.items()} for lev,c in sorted(species_level.items(),key=lambda x:int(x[0]))}
d['topic_tree']=tree; d['topic_level_labels']={'1':'System domain','2':'Major theme','3':'Evidence subset','4':'Component'}; d['metrics']['last_update']='2026-08-13'
p.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8'); print('Augmented dashboard data:',len(records),'records;',len(d['species_counts']),'species;',len(terminal),'finest topics')
