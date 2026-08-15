#!/usr/bin/env python3
"""Audit master topic paths against the canonical v3 ontology.

Read-only: legacy/4-level/unmapped paths are findings, never silently repaired.
"""
import csv
from collections import Counter
from pathlib import Path
MASTER=Path('data/reference/salmon_evidence_map.csv'); ONTOLOGY=Path('data/reference/topic_ontology_v3.csv'); OUT=Path('state/topic_hierarchy_audit.csv'); SUMMARY=Path('state/topic_hierarchy_audit_summary.txt')
def split_paths(value): return [p.strip() for p in str(value or '').split(';') if p.strip()]
with ONTOLOGY.open(newline='',encoding='utf-8-sig') as f: ontology=list(csv.DictReader(f))
valid_by_id={r.get('path_id','').strip():r.get('hierarchy_path','').strip() for r in ontology if r.get('path_id') and r.get('hierarchy_path')}; valid_paths=set(valid_by_id.values()); valid_depth=Counter(p.count(' > ')+1 for p in valid_paths)
with MASTER.open(newline='',encoding='utf-8-sig') as f:
    reader=csv.DictReader(f); rows=list(reader); fields=reader.fieldnames or []
path_col=next((c for c in ['topic_hierarchy_paths','topic_hierarchy','hierarchy_path','topic_path'] if c in fields),None); id_col=next((c for c in ['topic_path_ids','topic_path_id','path_id'] if c in fields),None); record_col=next((c for c in ['record_id','lens_id','id','study_id'] if c in fields),None)
if not path_col: raise SystemExit(f'No topic path column found. Available fields: {fields}')
findings=[]; path_counts=Counter(); record_path_counts=Counter(); depth_counts=Counter(); invalid_paths=set(); mismatch_count=0; invalid_record_ids=set(); mismatch_record_ids=set()
for row in rows:
    rid=row.get(record_col,'') if record_col else ''; paths=split_paths(row.get(path_col,'')); ids=split_paths(row.get(id_col,'')) if id_col else []
    if not paths: findings.append({'record_id':rid,'finding':'missing_topic_path','path':'','path_id':''}); invalid_record_ids.add(rid); continue
    record_path_counts[len(paths)]+=1
    for i,path in enumerate(paths):
        path_counts[path]+=1; depth=path.count(' > ')+1; depth_counts[depth]+=1; pid=ids[i] if i<len(ids) else ''; expected=valid_by_id.get(pid,'') if pid else ''
        if path not in valid_paths:
            invalid_paths.add(path); invalid_record_ids.add(rid); findings.append({'record_id':rid,'finding':f'unmapped_depth_{depth}' if depth!=3 else 'unmapped_path','path':path,'path_id':pid})
        elif expected and expected!=path:
            mismatch_count+=1; mismatch_record_ids.add(rid); findings.append({'record_id':rid,'finding':'path_id_text_mismatch','path':path,'path_id':pid})
OUT.parent.mkdir(parents=True,exist_ok=True)
with OUT.open('w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=['record_id','finding','path','path_id']); w.writeheader(); w.writerows(findings)
invalid=Counter((x['finding'],x['path']) for x in findings if x['finding']!='path_id_text_mismatch' and x['path'])
summary=[f'Master records: {len(rows):,}',f'Canonical ontology paths: {len(valid_paths):,}',f'Canonical ontology depth distribution: {dict(sorted(valid_depth.items()))}',f'Master topic-path depth distribution: {dict(sorted(depth_counts.items()))}',f'Master records with each number of paths: {dict(sorted(record_path_counts.items()))}',f'Unique master paths: {len(path_counts):,}',f'Unique master paths NOT in canonical ontology: {len(invalid_paths):,}',f'Records with at least one unmapped/missing path: {len(invalid_record_ids):,}',f'Path-ID/text mismatches: {mismatch_count:,}',f'Records with path-ID/text mismatches: {len(mismatch_record_ids):,}','', 'Most common genuinely unmapped paths:']
for (finding,path),n in invalid.most_common(50): summary.append(f'{n:,}\t{finding}\t{path}')
SUMMARY.write_text('\n'.join(summary)+'\n',encoding='utf-8'); print('\n'.join(summary))
