import json
from pathlib import Path
from collections import Counter,defaultdict
p=Path('docs/dashboard.json'); d=json.loads(p.read_text(encoding='utf-8')); records=d.get('records',[])
def canon(s):
 k=' '.join(str(s).strip().lower().split())
 if k in {'unspecified','unspecified salmon','unspecified salmon species','unspecified salmonid','unspecified salmonid species','salmon unspecified','unspecified species'}: return 'Unspecified species'
 if k in {'rainbow salmon','rainbow_trout','rainbow trout'}: return 'Rainbow trout'
 return str(s).strip()
def clean_topic(s):
 s=' '.join(str(s or '').strip().split()); return '' if s.lower() in {'na','n/a','nan','null','none','unknown','unspecified','not applicable',''} else s
for r in records:
 r['species']=list(dict.fromkeys(canon(x) for x in r.get('species',[]) if canon(x))) or ['Unspecified species']
 r['topics']=list(dict.fromkeys(clean_topic(x) for x in r.get('topics',[]) if clean_topic(x)))
 r['topic_paths']=[[clean_topic(x) for x in path if clean_topic(x)] for path in r.get('topic_paths',[]) if any(clean_topic(x) for x in path)]
cs=defaultdict(Counter); sc=Counter(); terminal=Counter(); level_counts=defaultdict(Counter); species_level=defaultdict(Counter); tree={}
for r in records:
 for s in r['species']:
  sc[s]+=1
  for c in r.get('iso3',[]): cs[s][str(c).upper()]+=1
 paths=r.get('topic_paths',[])
 if paths:
  for path in paths:
   parent=tree
   for depth,name in enumerate(path,1):
    node=parent.setdefault(name,{'name':name,'count':0,'children':{}}); node['count']+=1; parent=node['children']
  deepest=max(len(x) for x in paths)
  for path in paths:
   if len(path)==deepest:
    for x in dict.fromkeys(path[-1:]): terminal[x]+=1
  for depth in range(1,max(len(x) for x in paths)+1):
   for path in paths:
    if len(path)>=depth: level_counts[str(depth)][path[depth-1]]+=1
    for s in r['species']:
     if len(path)>=depth: species_level[str(depth)][(s,path[depth-1])]+=1
 else:
  levels=[]
  for k,v in r.items():
   if k.startswith('topic_level_') and isinstance(v,list) and v: levels.append((int(k.rsplit('_',1)[1]),v))
  if levels:
   deepest=max(i for i,v in levels)
   for x in next(v for i,v in levels if i==deepest): terminal[x]+=1
   for i,v in levels:
    for x in v: level_counts[str(i)][x]+=1
    for s in r['species']:
     for x in v: species_level[str(i)][(s,x)]+=1
d['species_counts']=dict(sc.most_common())
d['country_iso3_species_counts']={s:dict(c) for s,c in cs.items()}
d['topic_counts']=dict(terminal.most_common()); d['metrics']['total_topics']=sum(terminal.values()); d['metrics']['total_species']=len(d['species_counts'])
d['topic_level_counts']={k:dict(v.most_common()) for k,v in sorted(level_counts.items(),key=lambda x:int(x[0]))}
d['species_topic_level_counts']={lev:{f'{s}|||{t}':n for (s,t),n in c.items()} for lev,c in sorted(species_level.items(),key=lambda x:int(x[0]))}
d['topic_tree']=tree; d['topic_level_labels']={str(i):('Top-level topic' if i==1 else 'Topic level '+str(i)) for i in range(1,max([int(x) for x in level_counts] or [1])+1)}; d['metrics']['last_update']='2026-08-13'
p.write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')),encoding='utf-8'); print('Augmented dashboard data:',len(records),'records;',len(d['species_counts']),'species;',sum(terminal.values()),'finest-level assignments;',sum(1 for r in records if not r.get('topic_paths') and not any(k.startswith('topic_level_') and v for k,v in r.items())))
