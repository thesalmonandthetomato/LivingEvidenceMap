#!/usr/bin/env python3
# One-off 2026-08-14 construction of the next validated master from the current master + completed update.
import csv
from collections import defaultdict
from pathlib import Path
MASTER=Path('data/reference/salmon_evidence_map.csv'); UPDATE=Path('data/updates/2026-08-13_lens/records_after_species_geography_adjudication.csv'); TOPICS=Path('topic_artifact/topic_assignments.csv'); OUT=Path('data/reference/salmon_evidence_map_2026-08-14.csv'); MANIFEST=Path('data/reference/salmon_evidence_map_2026-08-14_manifest.csv')
def read_csv(p):
    with p.open(newline='',encoding='utf-8-sig') as f:
        r=csv.DictReader(f); return list(r),list(r.fieldnames or [])
def n(v): return '' if v is None else str(v).strip()
def tv(r,cs):
    for c in cs:
        if c in r and n(r[c]): return n(r[c])
    return ''
def identity_key(r):
    lens=tv(r,['lens_id','Lens ID','LensID']); doi=tv(r,['doi','DOI','doi_id']); title=tv(r,['title','Title','document_title','Document Title']).lower()
    if lens: return ('lens',lens.lower())
    if doi: return ('doi',doi.lower())
    if title: return ('title',title)
    return None
def duplicate_count(rows):
    seen=set(); dup=0
    for r in rows:
        k=identity_key(r)
        if k is not None:
            if k in seen: dup += 1
            seen.add(k)
    return dup
def collapse_exact_master_duplicates(rows):
    groups=defaultdict(list)
    for i,r in enumerate(rows):
        k=identity_key(r)
        if k is not None: groups[k].append((i,r))
    remove=set(); collapsed=0; conflicts=[]
    for k,items in groups.items():
        if len(items) <= 1: continue
        base=items[0][1]; differing=set()
        for _,r in items[1:]:
            for c in set(base) | set(r):
                if n(base.get(c)) != n(r.get(c)): differing.add(c)
        if differing:
            conflicts.append((k,items,sorted(differing)))
        else:
            for i,_ in items[1:]: remove.add(i)
            collapsed += len(items)-1
    if conflicts:
        print('Conflicting master duplicate identity keys:')
        for k,items,diff in conflicts[:20]:
            print(f'KEY={k} ROWS={[i+2 for i,_ in items]} DIFFERING={diff}')
            for field in diff:
                print(f'  FIELD {field}:')
                for i,r in items: print(f'    row {i+2}: {r.get(field,"")}')
        raise SystemExit(f'Master contains {len(conflicts)} non-identical duplicate identity keys; refusing to discard data')
    return [r for i,r in enumerate(rows) if i not in remove],collapsed
def topic_map(p):
    rows,cols=read_csv(p)
    if 'record_id' not in cols: raise SystemExit(f'Topic output has no record_id column: {cols}')
    d=defaultdict(lambda:{'ids':set(),'paths':set(),'review':False,'reasons':set()})
    for r in rows:
        k=n(r.get('record_id'))
        if not k: continue
        if n(r.get('path_id')): d[k]['ids'].add(n(r['path_id']))
        if n(r.get('hierarchy_path')): d[k]['paths'].add(n(r['hierarchy_path']))
        if n(r.get('review_required')).lower() in {'true','1','yes'}: d[k]['review']=True
        if n(r.get('review_reason')): d[k]['reasons'].add(n(r['review_reason']))
    return d,len(rows),len(d)
master,mcols=read_csv(MASTER); update,ucols=read_csv(UPDATE); topics,trows,trecs=topic_map(TOPICS)
if not update: raise SystemExit('Update is empty')
master_original=len(master); master,master_collapsed=collapse_exact_master_duplicates(master)
if duplicate_count(update): raise SystemExit(f'Update contains {duplicate_count(update)} duplicate identity keys')
master_keys={identity_key(r) for r in master if identity_key(r) is not None}
update_cross=sum(1 for r in update if identity_key(r) is not None and identity_key(r) in master_keys)
if update_cross: raise SystemExit(f'Update contains {update_cross} records already present in master')
for i,r in enumerate(update,1):
    k=n(r.get('record_id')) or str(i); t=topics.get(k,{'ids':set(),'paths':set(),'review':False,'reasons':set()})
    r['topic_path_ids']='; '.join(sorted(t['ids'])); r['topic_hierarchy_paths']='; '.join(sorted(t['paths'])); r['topic_review_required']='TRUE' if t['review'] else 'FALSE'; r['topic_review_reason']='; '.join(sorted(t['reasons']))
cols=[]
for c in mcols+ucols+['topic_path_ids','topic_hierarchy_paths','topic_review_required','topic_review_reason']:
    if c not in cols: cols.append(c)
combined=master+update
if duplicate_count(combined): raise SystemExit(f'Candidate master contains duplicate identity keys after master cleanup: {duplicate_count(combined)}')
with OUT.open('w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=cols,extrasaction='ignore'); w.writeheader()
    for r in combined: w.writerow({c:r.get(c,'') for c in cols})
final,_=read_csv(OUT)
if len(final)!=len(master)+len(update): raise SystemExit('Candidate row count does not equal cleaned master + update')
if duplicate_count(final): raise SystemExit('Candidate master contains duplicate identity keys')
with MANIFEST.open('w',newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerows([['metric','value'],['master_records_original',master_original],['master_exact_duplicate_rows_removed',master_collapsed],['master_records_after_exact_duplicate_cleanup',len(master)],['update_records',len(update)],['final_records',len(final)],['topic_assignment_rows',trows],['topic_records_with_output',trecs],['within_update_duplicates_detected',0],['update_vs_master_duplicates_detected',0],['candidate_duplicate_identity_keys',0],['source_master',str(MASTER)],['source_update',str(UPDATE)],['source_topics',str(TOPICS)]])
print(f'Master records original: {master_original}'); print(f'Exact duplicate master rows removed: {master_collapsed}'); print(f'Master records after cleanup: {len(master)}'); print(f'Update records: {len(update)}'); print(f'Final candidate records: {len(final)}'); print(f'Topic assignment rows: {trows}'); print(f'Topic records with output: {trecs}'); print('Within-update duplicates: 0'); print('Update-vs-master duplicates: 0'); print('Candidate duplicate identity keys: 0')
