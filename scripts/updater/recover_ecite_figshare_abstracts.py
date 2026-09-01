#!/usr/bin/env python3
"""Recover missing/truncated abstracts from eCite/Figshare and emit a validated patch.

Targets canonical records whose abstract is blank OR contains an ellipsis marker.
Only eCite-linked records are attempted. Candidate replacements require identity
validation. The patch records explicit field-level provenance for later write-back.
"""
from __future__ import annotations
import argparse, html, json, re, urllib.request
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import urlparse

UA='LivingEvidenceMap/1.0 (eCite/Figshare abstract recovery; contact via GitHub repository)'
URL_RE=re.compile(r'https?://[^\s\]\[\)\(<>\"\']+',re.I)
DOI_RE=re.compile(r'10\.\d{4,9}/[-._;()/:A-Z0-9]+',re.I)
ELLIPSIS_RE=re.compile(r'(?:\.\.\.|…|&hellip;)',re.I)

def clean(v): return re.sub(r'\s+',' ',html.unescape(str(v or ''))).strip()
def getv(d,*paths):
    for p in paths:
        x=d
        for k in p:
            if not isinstance(x,dict) or k not in x: x=None; break
            x=x[k]
        if x not in (None,'',[]): return x
    return None
def title(r): return clean(getv(r,('canonical','title'),('title',),('raw','title')))
def abstract(r): return clean(getv(r,('canonical','abstract'),('abstract',),('raw','abstract')))
def rid(r): return str(getv(r,('identity','lens_id'),('record_id',),('lens_id',),('canonical','lens_id')) or '')
def norm_doi(v):
    s=clean(v).lower(); s=re.sub(r'^https?://(dx\.)?doi\.org/','',s); s=re.sub(r'^doi:\s*','',s)
    m=DOI_RE.search(s); return m.group(0).rstrip('.,;)').lower() if m else None
def doi(r): return norm_doi(getv(r,('canonical','doi'),('doi',),('identifiers','doi'),('raw','doi')))
def urls(o):
    z=set()
    def w(x):
        if isinstance(x,dict):
            for v in x.values(): w(v)
        elif isinstance(x,list):
            for v in x: w(v)
        elif isinstance(x,str):
            for m in URL_RE.findall(x): z.add(m.rstrip('.,;'))
    w(o); return sorted(z)
def host(u):
    h=(urlparse(u).hostname or '').lower(); return h[4:] if h.startswith('www.') else h
def ecite(u): return host(u)=='ecite.utas.edu.au' or host(u).endswith('.ecite.utas.edu.au')
def req(u):
    q=urllib.request.Request(u,headers={'User-Agent':UA,'Accept':'text/html,application/xhtml+xml,*/*;q=0.8'})
    with urllib.request.urlopen(q,timeout=35) as r: return r.read(),r.geturl(),r.status
def meta(raw):
    s=raw.decode('utf-8',errors='replace'); m={}
    for tag in re.findall(r'<meta\b[^>]*>',s,re.I):
        a={k.lower():html.unescape(v) for k,_,v in re.findall(r'([\w:-]+)\s*=\s*([\"\'])(.*?)\2',tag,re.I|re.S)}
        k=(a.get('name') or a.get('property') or '').lower().strip(); v=a.get('content')
        if k and v and k not in m: m[k]=clean(v)
    t=m.get('citation_title') or m.get('dc.title') or m.get('og:title')
    d=norm_doi(m.get('citation_doi') or m.get('dc.identifier') or '')
    cand=[]
    for k in ('citation_abstract','dc.description','dcterms.abstract','dcterms.description','description','og:description'):
        v=clean(m.get(k));
        if 80<=len(v)<=12000: cand.append((k,v))
    return t,d,max(cand,key=lambda x:len(x[1])) if cand else (None,None)
def sim(a,b):
    a=re.sub(r'[^a-z0-9]+',' ',clean(a).lower()).strip(); b=re.sub(r'[^a-z0-9]+',' ',clean(b).lower()).strip()
    return SequenceMatcher(None,a,b).ratio() if a and b else None

def main():
    p=argparse.ArgumentParser(); p.add_argument('--records',required=True); p.add_argument('--outdir',required=True); a=p.parse_args()
    out=Path(a.outdir); out.mkdir(parents=True,exist_ok=True); rows=[]; patch=[]; counts={'eligible':0,'attempted':0,'recovered':0,'validated':0,'missing':0,'ellipsis':0}
    with open(a.records,encoding='utf-8') as f:
      for line in f:
        if not line.strip(): continue
        r=json.loads(line); old=abstract(r); mode='missing' if not old else ('ellipsis' if ELLIPSIS_RE.search(old) else None)
        if not mode: continue
        eu=[u for u in urls(r) if ecite(u)]
        if not eu: continue
        counts['eligible']+=1; counts[mode]+=1; hit=None; attempts=[]
        for u in eu:
          counts['attempted']+=1
          try:
            raw,final,status=req(u); st,sd,(method,new)=meta(raw); s=sim(title(r),st); de=bool(doi(r) and sd and doi(r)==sd); tv=bool(s is not None and s>=.82); valid=bool(new and (de or tv))
            attempts.append({'url':u,'final_url':final,'status':status,'source_title':st,'source_doi':sd,'title_similarity':s,'doi_exact':de,'identity_valid':valid})
            if new:
              counts['recovered']+=1
              if valid: hit=(new,final,method,st,sd,s,de); counts['validated']+=1; break
          except Exception as e: attempts.append({'url':u,'error':f'{type(e).__name__}: {e}','identity_valid':False})
        row={'record_id':rid(r),'canonical_title':title(r),'canonical_doi':doi(r),'replacement_mode':mode,'old_abstract':old,'attempts':attempts,'identity_valid':bool(hit)}
        if hit:
          new,src,method,st,sd,s,de=hit
          provenance={'field':'canonical.abstract','source_system':'University of Tasmania eCite / Figshare','source_url':src,'retrieval_method':f'html_meta:{method}','source_title':st,'source_doi':sd,'doi_exact':de,'title_similarity':round(s,4) if s is not None else None,'identity_valid':True}
          row.update({'abstract':new,'provenance':provenance})
          patch.append({'record_id':rid(r),'canonical_doi':doi(r),'replacement_mode':mode,'old_abstract':old,'abstract':new,'provenance':provenance})
        rows.append(row)
    report={**counts,'patch_count':len(patch),'canonical_mutated':False}
    (out/'results.jsonl').write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in rows),encoding='utf-8')
    (out/'validated_patch.jsonl').write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in patch),encoding='utf-8')
    (out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8'); print(json.dumps(report,indent=2))
if __name__=='__main__': main()
