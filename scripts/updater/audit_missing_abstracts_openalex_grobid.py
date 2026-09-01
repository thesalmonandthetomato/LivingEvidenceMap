#!/usr/bin/env python3
import argparse, json, re, time, urllib.parse, urllib.request
from pathlib import Path

UA='LivingEvidenceMap/1.0 (OpenAlex GROBID availability audit)'

def normdoi(x):
    if not x: return None
    x=str(x).strip().lower()
    x=re.sub(r'^https?://(dx\.)?doi\.org/','',x)
    return x or None

def getv(d,*paths):
    for p in paths:
        cur=d
        ok=True
        for k in p:
            if not isinstance(cur,dict) or k not in cur: ok=False; break
            cur=cur[k]
        if ok and cur not in (None,'',[]): return cur
    return None

def missing_abs(r):
    a=getv(r,('canonical','abstract'),('abstract',),('raw','abstract'))
    return not (isinstance(a,str) and a.strip())

def doi_of(r):
    d=getv(r,('canonical','doi'),('doi',),('identifiers','doi'),('raw','doi'))
    if isinstance(d,list): d=next((x for x in d if x),None)
    return normdoi(d)

def fetch_work(doi):
    url='https://api.openalex.org/works/https://doi.org/'+urllib.parse.quote(doi,safe='')
    req=urllib.request.Request(url,headers={'User-Agent':UA,'Accept':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=30) as f:
            return f.status,json.load(f)
    except urllib.error.HTTPError as e:
        return e.code,None
    except Exception:
        return None,None

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--records',required=True); ap.add_argument('--output',required=True); ap.add_argument('--report',required=True)
    ap.add_argument('--delay',type=float,default=0.12)
    args=ap.parse_args()
    rows=[]
    total=missing=with_doi=matched=grobid=pdf=pdf_only=0
    with open(args.records,encoding='utf-8') as f:
        for line in f:
            if not line.strip(): continue
            r=json.loads(line); total+=1
            if not missing_abs(r): continue
            missing+=1; doi=doi_of(r)
            rec={'record_id':getv(r,('record_id',),('lens_id',),('canonical','lens_id')),'doi':doi,'openalex_matched':False,'grobid_xml':False,'pdf':False}
            if doi:
                with_doi+=1
                status,w=fetch_work(doi); rec['http_status']=status
                if w:
                    matched+=1; rec['openalex_matched']=True; rec['openalex_id']=w.get('id')
                    hc=w.get('has_content') or {}
                    rec['grobid_xml']=bool(hc.get('grobid_xml')); rec['pdf']=bool(hc.get('pdf'))
                    if rec['grobid_xml']: grobid+=1
                    if rec['pdf']: pdf+=1
                    if rec['pdf'] and not rec['grobid_xml']: pdf_only+=1
                time.sleep(args.delay)
            rows.append(rec)
    Path(args.output).parent.mkdir(parents=True,exist_ok=True)
    with open(args.output,'w',encoding='utf-8') as f:
        for x in rows: f.write(json.dumps(x,ensure_ascii=False)+'\n')
    report={'input_record_count':total,'missing_abstract_count':missing,'missing_with_doi_count':with_doi,'openalex_matched_count':matched,'grobid_xml_count':grobid,'pdf_count':pdf,'pdf_only_no_grobid_count':pdf_only,'missing_without_doi_count':missing-with_doi,'canonical_mutated':False}
    Path(args.report).write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
if __name__=='__main__': main()
