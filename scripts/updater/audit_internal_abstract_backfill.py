#!/usr/bin/env python3
import argparse,csv,json,re,unicodedata
from pathlib import Path
from difflib import SequenceMatcher

ELLIPSIS_RE=re.compile(r'(\.\.\.|…|&hellip;)',re.I)
DOI_RE=re.compile(r'10\.\d{4,9}/[-._;()/:A-Z0-9]+',re.I)

def norm_text(x):
    return ' '.join(str(x or '').replace('\ufeff','').split()).strip()

def norm_title(x):
    x=unicodedata.normalize('NFKD',norm_text(x)).casefold()
    return re.sub(r'[^a-z0-9]+',' ',x).strip()

def norm_doi(x):
    x=norm_text(x)
    m=DOI_RE.search(x)
    return m.group(0).rstrip('.,;').casefold() if m else ''

def is_partial(x):
    return bool(ELLIPSIS_RE.search(str(x or '')))

def field(d,*names):
    low={str(k).casefold():k for k in d.keys()}
    for n in names:
        k=low.get(n.casefold())
        if k is not None and norm_text(d.get(k)):
            return norm_text(d.get(k))
    return ''

def read_csv_sources(path):
    out=[]
    with path.open(encoding='utf-8-sig',newline='') as f:
        r=csv.DictReader(f)
        for i,row in enumerate(r,2):
            abstract=field(row,'abstract','abstracts','ab')
            if not abstract: continue
            out.append({
                'source':'master_csv','source_path':str(path),'source_row':i,
                'lens_id':field(row,'lens_id','lens id','lensid','record_id'),
                'doi':norm_doi(field(row,'doi','doi(s)','digital object identifier')),
                'title':field(row,'title','publication title','article title'),
                'year':field(row,'year','publication_year','publication year'),
                'abstract':abstract
            })
    return out

def read_ris_sources(path):
    records=[]; cur={}; last_tag=None; line_no=0; start=1
    def flush():
        nonlocal cur,last_tag,start
        if cur:
            ab=norm_text(' '.join(cur.get('AB',[])+cur.get('N2',[])))
            if ab:
                title=norm_text(' '.join(cur.get('TI',[])+cur.get('T1',[])))
                doi=norm_doi(' '.join(cur.get('DO',[])))
                lens=''
                for tag in ('ID','AN','UR','L1','L2'):
                    txt=' '.join(cur.get(tag,[]))
                    m=re.search(r'\b\d{3}-\d{3}-\d{3}-\d{3}-[0-9X]{3}\b',txt)
                    if m: lens=m.group(0); break
                records.append({'source':'includes_ris','source_path':str(path),'source_row':start,
                    'lens_id':lens,'doi':doi,'title':title,'year':norm_text(' '.join(cur.get('PY',[])+cur.get('Y1',[]))), 'abstract':ab})
        cur={}; last_tag=None
    with path.open(encoding='utf-8-sig',errors='replace') as f:
        for line_no,line in enumerate(f,1):
            if re.match(r'^ER\s{0,2}-',line): flush(); start=line_no+1; continue
            m=re.match(r'^([A-Z0-9]{2})\s{0,2}-\s?(.*)$',line.rstrip('\n\r'))
            if m:
                last_tag=m.group(1); cur.setdefault(last_tag,[]).append(m.group(2)); continue
            if last_tag and line.startswith((' ','\t')):
                cur[last_tag][-1]+=' '+line.strip()
        flush()
    return records

def canonical_fields(r):
    c=r.get('canonical') or {}; ident=r.get('identity') or {}
    return {
      'lens_id':norm_text(ident.get('lens_id') or r.get('record_id') or r.get('lens_id') or c.get('lens_id')),
      'doi':norm_doi(c.get('doi') or ident.get('doi') or r.get('doi')),
      'title':norm_text(c.get('title') or ident.get('title') or r.get('title')),
      'year':norm_text(c.get('year') or c.get('publication_year') or ident.get('year') or r.get('year')),
      'abstract':norm_text(c.get('abstract'))
    }

def idx_add(index,key,val):
    if key: index.setdefault(key,[]).append(val)

def choose_candidate(cf, indexes, source_rank):
    pools=[]; basis=''
    if cf['lens_id'] and cf['lens_id'] in indexes['lens']:
        pools=indexes['lens'][cf['lens_id']]; basis='lens_id_exact'
    elif cf['doi'] and cf['doi'] in indexes['doi']:
        pools=indexes['doi'][cf['doi']]; basis='doi_exact'
    else:
        nt=norm_title(cf['title'])
        if nt and nt in indexes['title']:
            pools=indexes['title'][nt]; basis='title_exact'
        else:
            return None,'no_high_confidence_match',None
    valid=[]
    for s in pools:
        ts=SequenceMatcher(None,norm_title(cf['title']),norm_title(s['title'])).ratio() if cf['title'] and s['title'] else None
        if basis=='doi_exact' and ts is not None and ts < .80: continue
        if basis=='title_exact' and cf['year'] and s['year'] and cf['year'][:4]!=s['year'][:4]: continue
        valid.append((source_rank.get(s['source'],9),-len(s['abstract']),s,ts))
    if not valid: return None,'identity_crosscheck_failed',None
    valid.sort(key=lambda x:(x[0],x[1]))
    chosen=valid[0]
    return chosen[2],basis,chosen[3]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--canonical',required=True)
    ap.add_argument('--master',required=True)
    ap.add_argument('--includes',required=True)
    ap.add_argument('--outdir',required=True)
    args=ap.parse_args(); out=Path(args.outdir); out.mkdir(parents=True,exist_ok=True)
    sources=read_csv_sources(Path(args.master))+read_ris_sources(Path(args.includes))
    indexes={'lens':{},'doi':{},'title':{}}
    for s in sources:
        idx_add(indexes['lens'],s['lens_id'],s); idx_add(indexes['doi'],s['doi'],s); idx_add(indexes['title'],norm_title(s['title']),s)
    rank={'master_csv':0,'includes_ris':1}
    results=[]; counts={'canonical_records':0,'target_missing':0,'target_partial':0,'matched':0,'proposed_missing_fill':0,'proposed_partial_replace':0,'ambiguous_or_rejected':0,'no_match':0}
    with Path(args.canonical).open(encoding='utf-8') as f:
        for line in f:
            if not line.strip(): continue
            r=json.loads(line); counts['canonical_records']+=1; cf=canonical_fields(r)
            target='missing' if not cf['abstract'] else ('partial' if is_partial(cf['abstract']) else '')
            if not target: continue
            counts['target_'+target]+=1
            s,basis,ts=choose_candidate(cf,indexes,rank)
            rec={'lens_id':cf['lens_id'],'doi':cf['doi'],'title':cf['title'],'year':cf['year'],'target':target,'canonical_abstract':cf['abstract'],'canonical_length':len(cf['abstract'])}
            if not s:
                rec.update({'status':'no_match' if basis=='no_high_confidence_match' else 'rejected','reason':basis}); counts['no_match' if rec['status']=='no_match' else 'ambiguous_or_rejected']+=1; results.append(rec); continue
            counts['matched']+=1
            proposed=False; reason=''
            if target=='missing': proposed=True; reason='canonical_missing_source_present'
            else:
                ca=cf['abstract']; sa=s['abstract']
                if len(sa) >= max(len(ca)+80,int(len(ca)*1.20)) and not is_partial(sa): proposed=True; reason='source_demonstrably_more_complete'
                else: reason='source_not_clearly_more_complete'
            rec.update({'status':'proposed' if proposed else 'rejected','reason':reason,'match_basis':basis,'title_similarity':ts,
                        'source':s['source'],'source_path':s['source_path'],'source_row':s['source_row'],'source_title':s['title'],'source_doi':s['doi'],'source_abstract':s['abstract'],'source_length':len(s['abstract'])})
            if proposed: counts['proposed_'+('missing_fill' if target=='missing' else 'partial_replace')]+=1
            else: counts['ambiguous_or_rejected']+=1
            results.append(rec)
    with (out/'audit_results.jsonl').open('w',encoding='utf-8') as f:
        for r in results: f.write(json.dumps(r,ensure_ascii=False)+'\n')
    proposed=[r for r in results if r.get('status')=='proposed']
    with (out/'proposed_backfill.jsonl').open('w',encoding='utf-8') as f:
        for r in proposed: f.write(json.dumps(r,ensure_ascii=False)+'\n')
    counts['proposed_total']=len(proposed); counts['canonical_mutated']=False
    (out/'summary.json').write_text(json.dumps(counts,indent=2),encoding='utf-8')
    with (out/'proposed_backfill.csv').open('w',encoding='utf-8',newline='') as f:
        cols=['lens_id','doi','title','year','target','match_basis','title_similarity','source','source_row','canonical_length','source_length','reason']
        w=csv.DictWriter(f,fieldnames=cols); w.writeheader();
        for r in proposed: w.writerow({k:r.get(k,'') for k in cols})
    print(json.dumps(counts,indent=2))
if __name__=='__main__': main()
