#!/usr/bin/env python3
"""Sequentially process uncompleted Zenodo full-text deposits until exhausted or cancelled.

One record is downloaded and coded at a time. After every completed paper the
cumulative coding JSON and provenance architecture are committed to GitHub.
"""
import csv, json, os, shutil, subprocess, tarfile, zipfile, urllib.request
from pathlib import Path
from datetime import datetime, timezone

ROOT=Path.cwd(); WORK=ROOT/'work'; RAW=WORK/'raw'; PREP=WORK/'prepared'; ANN=WORK/'annotations'
REG=ROOT/'data/reference/fulltext_batch_registry.csv'; ARCH=ROOT/'data/fulltext_coding/coding_architecture.json'
CUM=ROOT/'data/fulltext_coding/cumulative_coding.json'; MODEL=os.environ.get('FULLTEXT_CODING_MODEL','gpt-5.6-luna')
TOKEN=os.environ['ZENODO_ACCESS_TOKEN']


def jload(p,default):
    p=Path(p); return json.loads(p.read_text()) if p.exists() else default

def request_json(url):
    req=urllib.request.Request(url,headers={'Authorization':f'Bearer {TOKEN}','Accept':'application/json'})
    with urllib.request.urlopen(req,timeout=90) as r: return json.load(r)

def git_checkpoint(wid):
    subprocess.run(['git','add',str(CUM),str(ARCH)],check=True)
    if subprocess.run(['git','diff','--cached','--quiet']).returncode != 0:
        subprocess.run(['git','config','user.name','github-actions[bot]'],check=True)
        subprocess.run(['git','config','user.email','41898282+github-actions[bot]@users.noreply.github.com'],check=True)
        subprocess.run(['git','commit','-m',f'Checkpoint full-text coding {wid}'],check=True)
        subprocess.run(['git','push'],check=True)

def persist(wid, annotation, prov, ctx):
    now=datetime.now(timezone.utc).isoformat()
    cum=jload(CUM,{"architecture_version":"1.0","workflow":"zenodo_fulltext_ai_coding","created_at_utc":now,"updated_at_utc":now,"record_count":0,"records":[]})
    arch=jload(ARCH,{"architecture_version":"1.0","workflow":"zenodo_fulltext_ai_coding","created_at_utc":now,"updated_at_utc":now,"record_count":0,"provenance_key_order":["zenodo_record_id","zenodo_archive_filename","zenodo_source_filename","openalex_id","doi","coding_run_id"],"records":{}})
    record={"openalex_id":wid,"doi":str(prov.get('doi') or ''),'zenodo_record_id':ctx['zenodo_record_id'],'zenodo_record_url':ctx['zenodo_record_url'],'zenodo_archive_filename':ctx['zenodo_archive_filename'],'zenodo_source_filename':prov.get('source_filename',f'{wid}.tei.xml'),'coding_status':'completed','coding_run_id':os.environ.get('GITHUB_RUN_ID',''),'coding_timestamp_utc':now,'prompt_version':'fulltext_coding_v3','schema_version':'coding_schema_v3','ontology':'data/reference/topic_ontology_v3.csv','annotation':annotation}
    rs=cum.setdefault('records',[]); rs[:]=[r for r in rs if str(r.get('openalex_id',''))!=wid]; rs.append(record); cum['updated_at_utc']=now; cum['record_count']=len(rs)
    arch.setdefault('records',{})[wid]={k:record[k] for k in record if k!='annotation'}; arch['updated_at_utc']=now; arch['record_count']=len(arch['records'])
    for p,obj in [(CUM,cum),(ARCH,arch)]:
        tmp=Path(str(p)+'.tmp'); tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n'); tmp.replace(p)
    git_checkpoint(wid)

def main():
    requested=os.environ.get('ZENODO_RECORD_ID','').strip()
    rows=list(csv.DictReader(REG.open(encoding='utf-8-sig',newline='')))
    arch=jload(ARCH,{'records':{}}); done={k for k,v in arch.get('records',{}).items() if v.get('coding_status')=='completed'}
    by={}
    for r in rows:
        rid=str(r.get('zenodo_record_id','')).strip()
        if rid: by.setdefault(rid,[]).append(r)
    if requested: order=[requested]
    else:
        order=sorted([rid for rid,rr in by.items() if any(str(r.get('status','')).lower()=='deposited' and str(r.get('openalex_id','')).strip() not in done for r in rr)],key=lambda x:int(x) if x.isdigit() else x)
    if not order: raise SystemExit('No unprocessed deposited Zenodo records remain.')
    print(f'Will process up to {len(order)} Zenodo records; cancel the workflow to stop safely.')
    for rid in order:
        expected=by.get(rid,[]); expected_names={r.get('zenodo_archive_filename') for r in expected if r.get('zenodo_archive_filename')}
        data=request_json(f'https://zenodo.org/api/records/{rid}')
        archive=next((f for f in data.get('files',[]) if f.get('key') in expected_names),None)
        if archive is None:
            z=[f for f in data.get('files',[]) if str(f.get('key','')).lower().endswith(('.zip','.tar.gz','.tgz'))]
            if len(z)==1: archive=z[0]
        if not archive: raise SystemExit(f'Cannot uniquely identify archive for Zenodo record {rid}')
        url=archive.get('links',{}).get('download') or archive.get('links',{}).get('self')
        req=urllib.request.Request(url,headers={'Authorization':f'Bearer {TOKEN}'})
        with urllib.request.urlopen(req,timeout=900) as r: blob=r.read()
        shutil.rmtree(RAW,ignore_errors=True); shutil.rmtree(PREP,ignore_errors=True); RAW.mkdir(parents=True); PREP.mkdir(parents=True); ANN.mkdir(parents=True,exist_ok=True)
        zpath=WORK/'zenodo_archive'; zpath.write_bytes(blob)
        if zipfile.is_zipfile(zpath): zipfile.ZipFile(zpath).extractall(RAW)
        elif tarfile.is_tarfile(zpath): tarfile.open(zpath).extractall(RAW)
        else: raise SystemExit(f'Unsupported archive format for Zenodo record {rid}')
        reg={str(r.get('openalex_id','')).strip():r for r in expected}; ctx={'zenodo_record_id':rid,'zenodo_record_url':f'https://zenodo.org/records/{rid}','zenodo_archive_filename':archive.get('key'),'zenodo_version_doi':data.get('doi'),'zenodo_concept_doi':data.get('conceptdoi')}
        selected=[]
        for p in sorted(RAW.rglob('*.tei.xml')):
            wid=p.name.removesuffix('.tei.xml'); r=reg.get(wid)
            if r and wid not in done: selected.append((p,r))
        if not selected:
            print(f'No new files in Zenodo record {rid}; continuing.')
            continue
        for p,r in selected:
            wid=str(r['openalex_id']); out=PREP/f'{wid}.json'
            subprocess.run(['python','scripts/fulltext_coding/prepare_fulltext_for_coding.py','--input',str(p),'--output',str(out)],check=True)
            subprocess.run(['python','scripts/fulltext_coding/code_fulltext_test_v3.py','--input-dir',str(PREP),'--output-dir',str(ANN),'--ontology','data/reference/topic_ontology_v3.csv','--schema','scripts/fulltext_coding/coding_schema_v3.json','--validator','scripts/fulltext_coding/validate_coding_output_v4.py','--prompt','scripts/fulltext_coding/fulltext_coding_prompt_v3.txt','--model',MODEL,'--max-papers','1'],check=True)
            ap=ANN/f'{wid}.json'
            if not ap.exists(): raise SystemExit(f'No final annotation produced for {wid}')
            annotation=jload(ap,{})
            persist(wid,annotation,{'source_filename':p.name,'doi':r.get('doi','')},ctx); done.add(wid)
            print(f'CHECKPOINTED {wid} -> Zenodo {rid}')
        print(f'COMPLETED ZENODO RECORD {rid}')
    print('No further unprocessed deposited Zenodo records remain.')

if __name__=='__main__': main()
