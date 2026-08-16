#!/usr/bin/env python3
"""Audit every master topic representation against canonical topic_ontology_v3.
Read-only: never repair or reinterpret assignments silently.
"""
import csv,json,re
from collections import Counter
from pathlib import Path
MASTER=Path('data/master/current/living_evidence_map_master.csv'); ONTOLOGY=Path('data/reference/topic_ontology_v3.csv'); OUT=Path('state/topic_hierarchy_audit.csv'); SUMMARY=Path('state/topic_hierarchy_audit_summary.txt')
def split_paths(value):
    s=str(value or '').strip()
    if not s or s.lower() in {'na','n/a','nan','null','none'}: return []
    if s.startswith('[') and s.endswith(']'):
        try:
            obj=json.loads(s)
            if isinstance(obj,list): return [str(x).strip() for x in obj if str(x).strip()]
        except Exception: pass
    return [x.strip() for x in re.split(r'\s*;\s*',s) if x.strip()]
def path_parts(path): return [x.strip() for x in re.split(r'\s*(?:→|>>|/|>)\s*',path) if x.strip()]
with ONTOLOGY.open(newline='',encoding='utf-8-sig') as f: ontology=list(csv.DictReader(f))
valid_by_id={r.get('path_id','').strip():r.get('hierarchy_path','').strip() for r in ontology if r.get('path_id') and r.get('hierarchy_path')}; valid_paths=set(valid_by_id.values())
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); rows=list(reader); fields=reader.fieldnames or []
record_col=next((c for c in ['record_id','lens_id','id','study_id'] if c in fields),None); path_cols=[c for c in ['topic_hierarchy','topic_hierarchy_paths','hierarchy_path','topic_path'] if c in fields]
if not path_cols: raise SystemExit(f'No topic path columns found: {fields}')
findings=[]; summaries=[]
for col in path_cols:
    depth=Counter(); path_counts=Counter(); invalid_paths=set(); invalid_records=set(); total_paths=0
    for row in rows:
        rid=row.get(record_col,'') if record_col else ''; paths=split_paths(row.get(col,''))
        if not paths: continue
        for path in paths:
            total_paths+=1; path_counts[path]+=1; depth[len(path_parts(path))]+=1
            if path not in valid_paths:
                invalid_paths.add(path); invalid_records.add(rid); findings.append({'record_id':rid,'field':col,'finding':'unmapped_path','path':path,'path_id':''})
    summaries.append((col,total_paths,len(path_counts),dict(sorted(depth.items())),len(invalid_paths),len(invalid_records),path_counts))
id_col=next((c for c in ['topic_path_ids','topic_path_id','path_id'] if c in fields),None)
if id_col and 'topic_hierarchy_paths' in fields:
    for row in rows:
        rid=row.get(record_col,'') if record_col else ''; paths=split_paths(row.get('topic_hierarchy_paths','')); ids=split_paths(row.get(id_col,''))
        for i,path in enumerate(paths):
            if i<len(ids) and ids[i] and valid_by_id.get(ids[i],'') and valid_by_id[ids[i]]!=path:
                findings.append({'record_id':rid,'field':id_col,'finding':'path_id_text_mismatch','path':path,'path_id':ids[i]})
OUT.parent.mkdir(parents=True,exist_ok=True)
with OUT.open('w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=['record_id','field','finding','path','path_id']); w.writeheader(); w.writerows(findings)
summary=[f'Master records: {len(rows):,}',f'Canonical ontology paths: {len(valid_paths):,}',f'Canonical ontology depth distribution: {dict(sorted(Counter(len(path_parts(p)) for p in valid_paths).items()))}','']
for col,total,unique,depth,invalid,invalid_records,_ in summaries:
    summary += [f'FIELD {col}:',f'  total parsed paths: {total:,}',f'  unique paths: {unique:,}',f'  depth distribution: {depth}',f'  unique paths NOT in ontology: {invalid:,}',f'  records with unmapped paths: {invalid_records:,}','']
summary += [f'Path-ID/text mismatch findings: {sum(1 for x in findings if x["finding"]=="path_id_text_mismatch"):,}','Most common unmapped paths by field:']
for col,_,_,_,_,_,pc in summaries:
    for p,n in [(p,n) for p,n in pc.most_common() if p not in valid_paths][:20]: summary.append(f'{n:,}\t{col}\t{p}')
SUMMARY.write_text('\n'.join(summary)+'\n',encoding='utf-8'); print('\n'.join(summary))
