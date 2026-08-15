import csv,json,os,re,time
from pathlib import Path
import requests
MASTER=Path('data/reference/salmon_evidence_map.csv'); IDS=Path('state/dashboard_missing_topics.txt'); ONTOLOGY=Path('data/reference/topic_ontology_v3.csv'); OUT=Path('state/missing_topic_assignments.csv'); CHECK=Path('state/missing_topic_assignments_checkpoint.csv')
api=os.environ.get('OPENAI_API_KEY','')
if not api: raise SystemExit('OPENAI_API_KEY is required')
def read(p):
 with p.open(newline='',encoding='utf-8-sig') as f:return list(csv.DictReader(f)),list(csv.DictReader(f)).fieldnames if False else None
def rows(p):
 with p.open(newline='',encoding='utf-8-sig') as f:
  r=csv.DictReader(f); return list(r),list(r.fieldnames or [])
master,fields=rows(MASTER); ontology,ofields=rows(ONTOLOGY); ids={x.strip() for x in IDS.read_text().splitlines() if x.strip()}
byid={str(r.get('record_id','')).strip():r for r in master}; targets=[byid[x] for x in ids if x in byid]
if len(targets)!=len(ids): raise SystemExit(f'Could not find {len(ids)-len(targets)} missing-topic record IDs in master')
need={'path_id','hierarchy_path','supporting_terms_from_old_ontology'}
if not need.issubset(set(ofields)): raise SystemExit(f'Ontology missing required fields: {sorted(need-set(ofields))}')
valid=[r['hierarchy_path'] for r in ontology if r.get('hierarchy_path')]
prompt_lines=[f"{r['hierarchy_path']} [{r['path_id']}] | Semantic cues: {r.get('supporting_terms_from_old_ontology','')}" for r in ontology if r.get('hierarchy_path')]
schema={'type':'object','properties':{'assignments':{'type':'array','items':{'type':'string','enum':valid}},'review_required':{'type':'boolean'},'review_reason':{'type':['string','null']}},'required':['assignments','review_required','review_reason'],'additionalProperties':False}
def classify(title,abstract):
 system='You are classifying scientific abstracts for a systematic evidence map of farmed salmon and rainbow trout research. Select every valid three-level hierarchy path below that represents a substantive objective, intervention, exposure, measured outcome, interpretation or application of the study. A path need not be the primary focus to be substantive. Semantic cues are non-exhaustive. Do not assign a path from an isolated word, background mention, or motivation alone. Use only listed paths. Multiple paths are allowed when genuinely applicable. An empty assignment is not acceptable for this repair task: if uncertain, choose the best-supported substantive path and set review_required=true.'
 user='VALID HIERARCHY PATHS\n'+'\n'.join(prompt_lines)+'\n\nTITLE\n'+str(title or '')+'\n\nABSTRACT\n'+str(abstract or '')+'\n\nSelect every substantively applicable hierarchy path.'
 body={'model':'gpt-5-mini','store':False,'input':[{'role':'system','content':[{'type':'input_text','text':system}]},{'role':'user','content':[{'type':'input_text','text':user}]}],'text':{'format':{'type':'json_schema','name':'topic_hierarchy_classification','strict':True,'schema':schema}}}
 for attempt in range(4):
  try:
   resp=requests.post('https://api.openai.com/v1/responses',headers={'Authorization':f'Bearer {api}','Content-Type':'application/json'},json=body,timeout=180)
   if resp.status_code>=400: raise RuntimeError(f'HTTP {resp.status_code}: {resp.text[:1000]}')
   data=resp.json(); texts=[]
   for item in data.get('output',[]):
    for c in item.get('content',[]) or []:
     if c.get('type')=='output_text' and c.get('text'): texts.append(c['text'])
   if not texts: raise RuntimeError('No output_text returned')
   parsed=json.loads(texts[0]); assignments=[x for x in parsed.get('assignments',[]) if x in valid]
   if not assignments: raise RuntimeError('LLM returned zero topic assignments')
   return assignments,bool(parsed.get('review_required')),parsed.get('review_reason')
  except Exception:
   if attempt==3: raise
   time.sleep(2**attempt)
checkpoint=[]
if CHECK.exists():
 with CHECK.open(newline='',encoding='utf-8-sig') as f:checkpoint=list(csv.DictReader(f))
done={r['record_id'] for r in checkpoint if r.get('status')=='completed'}
for i,r in enumerate(targets,1):
 rid=str(r.get('record_id',''))
 if rid in done: continue
 try:
  assignments,review,reason=classify(r.get('title',''),r.get('abstract',''))
  om={x['hierarchy_path']:x for x in ontology}; selected=[om[x] for x in assignments]
  row={'record_id':rid,'path_id':'; '.join(sorted(x['path_id'] for x in selected)),'hierarchy_path':'; '.join(assignments),'review_required':'TRUE' if review else 'FALSE','review_reason':reason or '','status':'completed','error':''}
 except Exception as e:
  row={'record_id':rid,'path_id':'','hierarchy_path':'','review_required':'TRUE','review_reason':'Topic repair failed; manual review required','status':'failed','error':str(e)}
 checkpoint.append(row)
 with CHECK.open('w',newline='',encoding='utf-8') as f:
  w=csv.DictWriter(f,fieldnames=['record_id','path_id','hierarchy_path','review_required','review_reason','status','error']);w.writeheader();w.writerows(checkpoint)
 print(f'{i}/{len(targets)} {rid}: {row["status"]}')
failed=[r for r in checkpoint if r.get('status')!='completed']; empty=[r for r in checkpoint if not r.get('hierarchy_path')]
if failed or empty: raise SystemExit(f'Topic repair incomplete: failed={len(failed)}, empty={len(empty)}')
with OUT.open('w',newline='',encoding='utf-8') as f:
 w=csv.DictWriter(f,fieldnames=['record_id','path_id','hierarchy_path','review_required','review_reason','status','error']);w.writeheader();w.writerows(checkpoint)
print(f'Repaired {len(checkpoint)} records with topic assignments.')
# Apply only topic fields to a temporary master, preserving all other data and row count.
backup=Path('data/reference/salmon_evidence_map_pre_topic_repair_2026-08-15.csv');
with MASTER.open(newline='',encoding='utf-8-sig') as f: raw=list(csv.DictReader(f)); cols=list(f.fieldnames or [])
patch={r['record_id']:r for r in checkpoint}
for c in ['topic_path_ids','topic_hierarchy_paths','topic_review_required','topic_review_reason']:
 if c not in cols: cols.append(c)
for r in raw:
 p=patch.get(str(r.get('record_id','')))
 if p:
  r['topic_path_ids']=p['path_id']; r['topic_hierarchy_paths']=p['hierarchy_path']; r['topic_review_required']=p['review_required']; r['topic_review_reason']=p['review_reason']
backup.write_text(MASTER.read_text(encoding='utf-8-sig'),encoding='utf-8')
tmp=MASTER.with_suffix('.csv.tmp')
with tmp.open('w',newline='',encoding='utf-8') as f:
 w=csv.DictWriter(f,fieldnames=cols);w.writeheader();w.writerows(r)
if len(raw)!=len(master): raise SystemExit('Row count changed during topic repair')
tmp.replace(MASTER)
print(f'Updated master topic fields for {len(patch)} records; master rows remain {len(raw):,}. Backup: {backup}')
