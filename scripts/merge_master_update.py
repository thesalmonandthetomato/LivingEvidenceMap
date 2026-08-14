#!/usr/bin/env python3
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
def keys(rows):
 out=[]
 for r in rows:
  lens=tv(r,['lens_id','Lens ID','LensID']); doi=tv(r,['doi','DOI','doi_id']); title=tv(r,['title','Title','document_title','Document Title']).lower()
  out.append(('lens',lens.lower()) if lens else ('doi',doi.lower()) if doi else ('title',title) if title else ('row',id(r)))
 return out
master,mcols=read_csv(MASTER); update,ucols=read_csv(UPDATE); topics,trows,trecs=topic_map(TOPICS)
if not update: raise SystemExit('Update is empty')
for i,r in enumerate(update,1):
 k=n(r.get('record_id')) or str(i); t=topics.get(k,{'ids':set(),'paths':set(),'review':False,'reasons':set()}); r['topic_path_ids']='; '.join(sorted(t['ids'])); r['topic_hierarchy_paths']='; '.join(sorted(t['paths'])); r['topic_review_required']='TRUE' if t['review'] else 'FALSE'; r['topic_review_reason']='; '.join(sorted(t['reasons']))
cols=[]
for c in mcols+ucols+['topic_path_ids','topic_hierarchy_paths','topic_review_required','topic_review_reason']:
 if c not in cols: cols.append(c)
mk=set(keys(master)); seen=set(); within=cross=0
for k in keys(update):
 if k in seen: within+=1
 seen.add(k)
 if k in mk: cross+=1
if within or cross: raise SystemExit(f'Deduplication invariant failed: within_update_duplicates={within}; update_vs_master_duplicates={cross}')
combined=master+update
with OUT.open('w',newline='',encoding='utf-8') as f:
 w=csv.DictWriter(f,fieldnames=cols,extrasaction='ignore'); w.writeheader()
 for r in combined: w.writerow({c:r.get(c,'') for c in cols})
final,_=read_csv(OUT)
if len(final)!=len(master)+len(update): raise SystemExit('Candidate row count does not equal master + update')
if len(keys(final))!=len(set(keys(final))): raise SystemExit('Candidate master contains duplicate identity keys')
with MANIFEST.open('w',newline='',encoding='utf-8') as f:
 w=csv.writer(f); w.writerows([['metric','value'],['master_records',len(master)],['update_records',len(update)],['final_records',len(final)],['topic_assignment_rows',trows],['topic_records_with_output',trecs],['within_update_duplicates_detected',within],['update_vs_master_duplicates_detected',cross],['candidate_duplicate_identity_keys',0],['source_master',str(MASTER)],['source_update',str(UPDATE)],['source_topics',str(TOPICS)]])
print(f'Master records: {len(master)}'); print(f'Update records: {len(update)}'); print(f'Final candidate records: {len(final)}'); print(f'Topic assignment rows: {trows}'); print(f'Topic records with output: {trecs}'); print(f'Within-update duplicates: {within}'); print(f'Update-vs-master duplicates: {cross}')
