#!/usr/bin/env python3
import argparse, csv, json, re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

LENS_RE = re.compile(r'^\d{3}-\d{3}-\d{3}-\d{3}-[\dXx]{3}$')
DOI_RE = re.compile(r'10\.\d{4,9}/[^\s"<>]+', re.I)


def norm_text(x):
    s=str(x or '').lower().strip()
    s=re.sub(r'<[^>]+>',' ',s)
    s=re.sub(r'[^\w\s]',' ',s,flags=re.UNICODE)
    return re.sub(r'\s+',' ',s).strip()


def norm_title(x):
    return norm_text(x)


def norm_doi(x):
    s=str(x or '').strip().lower()
    s=re.sub(r'^https?://(dx\.)?doi\.org/','',s)
    s=re.sub(r'^doi:\s*','',s)
    m=DOI_RE.search(s)
    if m: s=m.group(0)
    return s.strip().rstrip('.,;:)\]}')


def first(row,names):
    for n in names:
        if n in row and str(row.get(n) or '').strip(): return str(row[n]).strip()
    return ''


def token_jaccard(a,b):
    A=set(norm_text(a).split()); B=set(norm_text(b).split())
    if not A or not B: return 0.0
    return len(A&B)/len(A|B)


def seq(a,b):
    return SequenceMatcher(None,norm_text(a),norm_text(b),autojunk=False).ratio()


def author_tokens(x):
    return {t for t in norm_text(x).split() if len(t)>2}


def load_jsonl(path):
    with Path(path).open(encoding='utf-8') as f:
        return [json.loads(x) for x in f if x.strip()]


def cval(rec,key):
    return (rec.get('canonical') or {}).get(key)


def canonical_author_text(rec):
    a=cval(rec,'authors')
    if isinstance(a,list):
        vals=[]
        for x in a:
            if isinstance(x,dict): vals.extend(str(v) for v in x.values() if v)
            elif x: vals.append(str(x))
        return ' '.join(vals)
    return str(a or '')


def canonical_source_text(rec):
    return str(cval(rec,'source') or cval(rec,'source_title') or cval(rec,'journal') or '')


def screening_fields(row):
    out={}
    for k,v in row.items():
        kl=k.lower()
        if any(t in kl for t in ('screen','decision','include','exclude','retain','relevance','review','human','machine','date')):
            out[k]=v
    return out


def primary_match(row, indices):
    lens=first(row,['lens_id','Lens ID','lensId','lensid'])
    rid=first(row,['record_id','Record ID','recordid'])
    if not lens and LENS_RE.match(rid): lens=rid
    doi=norm_doi(first(row,['doi','DOI','doi_key']))
    title=norm_title(first(row,['title','Title','TI']))
    year=first(row,['year','Year','publication_year','PY'])
    abstract=norm_text(first(row,['abstract','Abstract','AB']))
    for method,key,index in [
        ('lens_id',lens,indices['lens']),('doi',doi,indices['doi']),('title_year',(title,year) if title and year else None,indices['title_year']),('abstract_exact',abstract if len(abstract)>=200 else None,indices['abstract'])]:
        if key and key in index and len(index[key])==1: return index[key][0],method
        if key and key in index and len(index[key])>1: return None,'ambiguous_'+method
    return None,None


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--master',required=True); ap.add_argument('--canonical',required=True); ap.add_argument('--outdir',required=True)
    args=ap.parse_args(); out=Path(args.outdir); out.mkdir(parents=True,exist_ok=True)
    with Path(args.master).open(encoding='utf-8-sig',newline='') as f: master=list(csv.DictReader(f))
    canonical=load_jsonl(args.canonical)

    idx={k:defaultdict(list) for k in ('lens','doi','title_year','abstract','title')}
    by_year=defaultdict(list)
    for i,r in enumerate(canonical):
        ident=r.get('identity') or {}; lens=str(ident.get('lens_id') or '').strip(); doi=norm_doi(cval(r,'doi'))
        title=norm_title(cval(r,'title')); year=str(cval(r,'year') or '').strip(); abstract=norm_text(cval(r,'abstract'))
        if lens: idx['lens'][lens].append(i)
        if doi: idx['doi'][doi].append(i)
        if title: idx['title'][title].append(i)
        if title and year: idx['title_year'][(title,year)].append(i)
        if len(abstract)>=200: idx['abstract'][abstract].append(i)
        if year: by_year[year].append(i)

    unmatched=[]; prior_ambiguous=[]
    for row_no,row in enumerate(master,start=2):
        mi,method=primary_match(row,idx)
        if mi is None:
            base={'master_row':row_no,'master_title':first(row,['title','Title','TI']) or None,'master_year':first(row,['year','Year','publication_year','PY']) or None,'master_doi':norm_doi(first(row,['doi','DOI','doi_key'])) or None,'master_record_id':first(row,['record_id','Record ID','recordid']) or None,'master_screening_values':screening_fields(row)}
            if method and method.startswith('ambiguous_'): prior_ambiguous.append({**base,'reason':method})
            else: unmatched.append((base,row))

    recovered=[]; ambiguous=[]; still=[]; methods=Counter()
    for base,row in unmatched:
        title_raw=first(row,['title','Title','TI']); title=norm_title(title_raw); year=first(row,['year','Year','publication_year','PY'])
        authors=first(row,['authors','Authors','author','Author','AU']); source=first(row,['source','Source','journal','Journal','source_title','JO'])
        # 1. Exact unique title across canonical.
        if title and title in idx['title'] and len(idx['title'][title])==1:
            ci=idx['title'][title][0]; method='title_exact_unique'
            recovered.append({**base,'match_method':method,'matched_lens_id':(canonical[ci].get('identity') or {}).get('lens_id'),'matched_title':cval(canonical[ci],'title'),'matched_year':cval(canonical[ci],'year'),'title_sequence_similarity':1.0,'title_token_jaccard':1.0}); methods[method]+=1; continue

        pool=by_year.get(year,[]) if year else list(range(len(canonical)))
        # avoid unconstrained all-corpus fuzzy matching for very short/generic titles
        if len(title)<25 or not pool:
            still.append({**base,'reason':'insufficient_safe_metadata'}); continue

        scored=[]
        mtoks=author_tokens(authors); msource=norm_text(source)
        for ci in pool:
            ct=cval(canonical[ci],'title') or ''; nts=norm_title(ct)
            if not nts: continue
            s=seq(title,nts); j=token_jaccard(title,nts)
            if s < 0.92 and j < 0.82: continue
            ca=author_tokens(canonical_author_text(canonical[ci])); a_overlap=(len(mtoks & ca)/len(mtoks)) if mtoks and ca else 0.0
            cs=norm_text(canonical_source_text(canonical[ci])); source_exact=bool(msource and cs and msource==cs)
            # title drives score; author/source only strengthen/tie-break
            composite=0.70*s+0.20*j+0.08*a_overlap+0.02*(1.0 if source_exact else 0.0)
            scored.append((composite,s,j,a_overlap,source_exact,ci))
        scored.sort(reverse=True)
        if not scored:
            still.append({**base,'reason':'no_bibliographic_candidate'}); continue
        best=scored[0]; second=scored[1] if len(scored)>1 else None
        margin=best[0]-(second[0] if second else 0.0)
        comp,s,j,aov,sex,ci=best
        # Accept only exceptionally strong title agreement, with bibliographic support when below near-exact.
        accept=(s>=0.975 and j>=0.92 and margin>=0.025) or (s>=0.955 and j>=0.90 and margin>=0.035 and (aov>=0.5 or sex))
        entry={**base,'candidate_lens_id':(canonical[ci].get('identity') or {}).get('lens_id'),'candidate_title':cval(canonical[ci],'title'),'candidate_year':cval(canonical[ci],'year'),'title_sequence_similarity':round(s,6),'title_token_jaccard':round(j,6),'author_overlap':round(aov,6),'source_exact':sex,'composite_score':round(comp,6),'margin_to_second':round(margin,6)}
        if accept:
            method='title_similarity_year_bibliographic'
            recovered.append({**entry,'match_method':method,'matched_lens_id':entry.pop('candidate_lens_id',None),'matched_title':entry.pop('candidate_title',None),'matched_year':entry.pop('candidate_year',None)}); methods[method]+=1
        elif s>=0.94 and j>=0.86:
            cands=[]
            for x in scored[:3]:
                _,xs,xj,xa,xsex,xci=x
                cands.append({'lens_id':(canonical[xci].get('identity') or {}).get('lens_id'),'title':cval(canonical[xci],'title'),'year':cval(canonical[xci],'year'),'title_sequence_similarity':round(xs,6),'title_token_jaccard':round(xj,6),'author_overlap':round(xa,6),'source_exact':xsex})
            ambiguous.append({**base,'reason':'close_bibliographic_candidates','candidates':cands})
        else:
            still.append({**base,'reason':'below_safe_similarity_threshold','best_candidate':entry})

    def write(name,rows):
        (out/name).write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in rows),encoding='utf-8')
    write('recovered_matches.jsonl',recovered); write('ambiguous_recovery.jsonl',ambiguous); write('still_unmatched.jsonl',still); write('prior_ambiguous.jsonl',prior_ambiguous)
    summary={'master_rows':len(master),'canonical_records':len(canonical),'initially_unmatched_nonambiguous':len(unmatched),'prior_ambiguous':len(prior_ambiguous),'recovered_matches':len(recovered),'recovery_method_counts':dict(methods),'new_ambiguous':len(ambiguous),'still_unmatched':len(still),'status':'audit_complete'}
    (out/'recovery_summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
