#!/usr/bin/env python3
import argparse, csv, json, re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

LENS_ID_RE = re.compile(r"^\d{3}-\d{3}-\d{3}-\d{3}-[0-9X]{3}$", re.I)
MIN_ABSTRACT_CHARS = 200
MIN_ABSTRACT_RATIO = 0.92
MIN_ABSTRACT_TOKEN_JACCARD = 0.85
MIN_ABSTRACT_MARGIN = 0.03
MAX_RARE_TOKEN_FREQ = 50


def norm_text(x):
    return re.sub(r"\s+", " ", str(x or "").strip()).lower()


def norm_doi(x):
    s = norm_text(x)
    s = re.sub(r"^https?://(dx\.)?doi\.org/", "", s)
    s = re.sub(r"^doi:\s*", "", s)
    return s.strip().rstrip(".,; ")


def abstract_tokens(x):
    return set(re.findall(r"[a-z0-9]+", norm_text(x)))


def first(row, names):
    for n in names:
        if n in row and str(row.get(n) or "").strip():
            return str(row[n]).strip()
    return ""


def load_jsonl(path):
    out=[]
    with Path(path).open(encoding='utf-8') as f:
        for line in f:
            if line.strip(): out.append(json.loads(line))
    return out


def flatten_candidate_fields(row):
    keys=[]
    for k in row:
        kl=k.lower()
        if any(t in kl for t in ('screen','decision','include','exclude','retain','relevance','review','human','machine','date')):
            keys.append(k)
    return keys


def best_abstract_match(master_abstract, master_year, canonical, by_year, abstract_token_index, abstract_token_sets):
    a = norm_text(master_abstract)
    if len(a) < MIN_ABSTRACT_CHARS:
        return [], None
    toks = abstract_tokens(a)
    if len(toks) < 20:
        return [], None

    # Generate a compact candidate pool using informative/rare shared tokens.
    pool=set()
    rare_tokens=sorted(
        (t for t in toks if 0 < len(abstract_token_index.get(t, ())) <= MAX_RARE_TOKEN_FREQ),
        key=lambda t: len(abstract_token_index[t])
    )[:30]
    for t in rare_tokens:
        pool.update(abstract_token_index[t])

    if master_year and master_year in by_year:
        year_pool=set(by_year[master_year])
        if pool:
            pool &= year_pool
        else:
            pool = year_pool

    if not pool:
        return [], None

    scored=[]
    for i in pool:
        ctoks=abstract_token_sets[i]
        if not ctoks:
            continue
        jaccard=len(toks & ctoks) / max(1, len(toks | ctoks))
        if jaccard < MIN_ABSTRACT_TOKEN_JACCARD:
            continue
        ca=norm_text((canonical[i].get('canonical') or {}).get('abstract') or '')
        if len(ca) < MIN_ABSTRACT_CHARS:
            continue
        ratio=SequenceMatcher(None, a, ca, autojunk=False).ratio()
        if ratio >= MIN_ABSTRACT_RATIO:
            scored.append((ratio, jaccard, i))

    if not scored:
        return [], None
    scored.sort(reverse=True)
    best=scored[0]
    second=scored[1] if len(scored)>1 else None
    margin=best[0] - second[0] if second else 1.0
    details={
        'abstract_similarity':round(best[0],6),
        'abstract_token_jaccard':round(best[1],6),
        'abstract_similarity_margin':round(margin,6),
        'abstract_candidate_count':len(scored)
    }
    if second and margin < MIN_ABSTRACT_MARGIN:
        return [x[2] for x in scored if best[0]-x[0] < MIN_ABSTRACT_MARGIN], details
    return [best[2]], details


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--master', required=True)
    ap.add_argument('--canonical', required=True)
    ap.add_argument('--outdir', required=True)
    args=ap.parse_args()
    out=Path(args.outdir); out.mkdir(parents=True, exist_ok=True)

    with Path(args.master).open(encoding='utf-8-sig', newline='') as f:
        master=list(csv.DictReader(f))
    canonical=load_jsonl(args.canonical)

    if not master: raise SystemExit('Master CSV is empty')
    candidate_fields=flatten_candidate_fields(master[0])
    schema={
        'master_rows':len(master),
        'master_columns':list(master[0].keys()),
        'candidate_screening_fields':candidate_fields,
        'candidate_field_value_counts':{},
        'matching_order':['lens_id','doi','title_year','exact_abstract','high_similarity_abstract'],
        'abstract_matching':{
            'minimum_characters':MIN_ABSTRACT_CHARS,
            'minimum_sequence_similarity':MIN_ABSTRACT_RATIO,
            'minimum_token_jaccard':MIN_ABSTRACT_TOKEN_JACCARD,
            'minimum_best_vs_second_margin':MIN_ABSTRACT_MARGIN,
            'year_restricted_when_available':True
        }
    }
    for k in candidate_fields:
        c=Counter(str(r.get(k) or '').strip() for r in master)
        schema['candidate_field_value_counts'][k]=dict(c.most_common(30))
    (out/'master_screening_schema.json').write_text(json.dumps(schema,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

    by_lens=defaultdict(list); by_doi=defaultdict(list); by_title_year=defaultdict(list); by_exact_abstract=defaultdict(list); by_year=defaultdict(list)
    lens_to_record={}
    abstract_token_sets=[]
    token_docfreq=Counter()
    for i,r in enumerate(canonical):
        ident=r.get('identity') or {}
        c=r.get('canonical') or {}
        lens=str(ident.get('lens_id') or '').strip()
        doi=norm_doi(c.get('doi') or ident.get('doi') or '')
        title=norm_text(c.get('title') or '')
        year=str(c.get('year') or '').strip()
        abstract=norm_text(c.get('abstract') or '')
        toks=abstract_tokens(abstract) if len(abstract)>=MIN_ABSTRACT_CHARS else set()
        abstract_token_sets.append(toks)
        token_docfreq.update(toks)
        if lens:
            by_lens[lens].append(i); lens_to_record[lens]=i
        if doi: by_doi[doi].append(i)
        if title and year: by_title_year[(title,year)].append(i)
        if abstract and len(abstract)>=MIN_ABSTRACT_CHARS: by_exact_abstract[abstract].append(i)
        if year: by_year[year].append(i)

    abstract_token_index=defaultdict(list)
    for i,toks in enumerate(abstract_token_sets):
        for t in toks:
            if token_docfreq[t] <= MAX_RARE_TOKEN_FREQ:
                abstract_token_index[t].append(i)

    matches=[]; ambiguous=[]; unmatched=[]
    method_counts=Counter(); target_counts=Counter()

    for row_no,row in enumerate(master, start=2):
        explicit_lens=first(row,['lens_id','Lens ID','lensId','lensid'])
        legacy_record_id=first(row,['record_id','Record ID','recordid'])
        lens=explicit_lens or (legacy_record_id if LENS_ID_RE.match(legacy_record_id) else '')
        doi=norm_doi(first(row,['doi','DOI','doi_key']))
        raw_title=first(row,['title','Title','TI'])
        title=norm_text(raw_title)
        year=first(row,['year','Year','publication_year','PY'])
        raw_abstract=first(row,['abstract','Abstract','AB'])
        abstract=norm_text(raw_abstract)
        candidates=[]; method=''; similarity_details=None
        if lens and lens in by_lens:
            candidates=by_lens[lens]; method='lens_id'
        elif doi and doi in by_doi:
            candidates=by_doi[doi]; method='doi'
        elif title and year and (title,year) in by_title_year:
            candidates=by_title_year[(title,year)]; method='title_year'
        elif len(abstract)>=MIN_ABSTRACT_CHARS and abstract in by_exact_abstract:
            candidates=by_exact_abstract[abstract]; method='exact_abstract'
        elif len(abstract)>=MIN_ABSTRACT_CHARS:
            candidates, similarity_details = best_abstract_match(abstract, year, canonical, by_year, abstract_token_index, abstract_token_sets)
            if candidates: method='high_similarity_abstract'

        base={
            'master_row':row_no,
            'master_record_id':legacy_record_id or None,
            'master_lens_id':lens or None,
            'master_doi':doi or None,
            'master_title':raw_title or None,
            'master_year':year or None
        }
        if similarity_details:
            base.update(similarity_details)
        if len(candidates)==1:
            idx=candidates[0]; rec=canonical[idx]; ident=rec.get('identity') or {}; dedup=rec.get('deduplication') or {}
            matched_lens=str(ident.get('lens_id') or '')
            target_lens=matched_lens
            duplicate_of=dedup.get('duplicate_of')
            if dedup.get('status')=='duplicate' and duplicate_of:
                target_lens=str(duplicate_of)
            target_idx=lens_to_record.get(target_lens,idx)
            target=canonical[target_idx]; target_ident=target.get('identity') or {}
            entry={**base,'match_method':method,'matched_lens_id':matched_lens or None,'deduplication_status':dedup.get('status'),'duplicate_of':duplicate_of,'screening_target_lens_id':target_ident.get('lens_id'),'master_screening_values':{k:row.get(k) for k in candidate_fields}}
            matches.append(entry); method_counts[method]+=1; target_counts[str(target_ident.get('lens_id'))]+=1
        elif len(candidates)>1:
            ambiguous.append({**base,'match_method':method,'candidate_lens_ids':[(canonical[i].get('identity') or {}).get('lens_id') for i in candidates],'master_screening_values':{k:row.get(k) for k in candidate_fields}})
        else:
            unmatched.append({**base,'master_screening_values':{k:row.get(k) for k in candidate_fields}})

    def write_jsonl(path,rows):
        Path(path).write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in rows),encoding='utf-8')
    write_jsonl(out/'matched_master_rows.jsonl',matches)
    write_jsonl(out/'ambiguous_master_rows.jsonl',ambiguous)
    write_jsonl(out/'unmatched_master_rows.jsonl',unmatched)

    summary={
        'master_rows':len(master),
        'canonical_records':len(canonical),
        'matched_master_rows':len(matches),
        'ambiguous_master_rows':len(ambiguous),
        'unmatched_master_rows':len(unmatched),
        'match_method_counts':dict(method_counts),
        'unique_screening_targets':len(target_counts),
        'screening_targets_with_multiple_master_rows':sum(1 for n in target_counts.values() if n>1),
        'candidate_screening_fields':candidate_fields,
        'status':'audit_complete'
    }
    (out/'match_summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
