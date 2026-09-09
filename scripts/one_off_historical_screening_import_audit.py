#!/usr/bin/env python3
import argparse, csv, json, re
from collections import Counter, defaultdict
from pathlib import Path


def norm_text(x):
    return re.sub(r"\s+", " ", str(x or "").strip()).lower()


def norm_doi(x):
    s = norm_text(x)
    s = re.sub(r"^https?://(dx\.)?doi\.org/", "", s)
    s = re.sub(r"^doi:\s*", "", s)
    return s.strip().rstrip(".,; ")


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
        'candidate_field_value_counts':{}
    }
    for k in candidate_fields:
        c=Counter(str(r.get(k) or '').strip() for r in master)
        schema['candidate_field_value_counts'][k]=dict(c.most_common(30))
    (out/'master_screening_schema.json').write_text(json.dumps(schema,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

    by_lens=defaultdict(list); by_doi=defaultdict(list); by_record=defaultdict(list); by_title_year=defaultdict(list)
    lens_to_record={}
    for i,r in enumerate(canonical):
        ident=r.get('identity') or {}
        c=r.get('canonical') or {}
        lens=str(ident.get('lens_id') or '').strip()
        rid=str(ident.get('record_id') or r.get('record_id') or '').strip()
        doi=norm_doi(c.get('doi') or ident.get('doi') or '')
        title=norm_text(c.get('title') or '')
        year=str(c.get('year') or '').strip()
        if lens:
            by_lens[lens].append(i); lens_to_record[lens]=i
        if rid: by_record[rid].append(i)
        if doi: by_doi[doi].append(i)
        if title and year: by_title_year[(title,year)].append(i)

    matches=[]; ambiguous=[]; unmatched=[]
    method_counts=Counter(); target_counts=Counter()

    for row_no,row in enumerate(master, start=2):
        lens=first(row,['lens_id','Lens ID','lensId','lensid'])
        rid=first(row,['record_id','Record ID','recordid'])
        doi=norm_doi(first(row,['doi','DOI','doi_key']))
        title=norm_text(first(row,['title','Title','TI']))
        year=first(row,['year','Year','publication_year','PY'])
        candidates=[]; method=''
        if lens and lens in by_lens:
            candidates=by_lens[lens]; method='lens_id'
        elif rid and rid in by_record:
            candidates=by_record[rid]; method='record_id'
        elif doi and doi in by_doi:
            candidates=by_doi[doi]; method='doi'
        elif title and year and (title,year) in by_title_year:
            candidates=by_title_year[(title,year)]; method='title_year'

        base={'master_row':row_no,'master_record_id':rid or None,'master_lens_id':lens or None,'master_doi':doi or None,'master_title':first(row,['title','Title','TI']) or None,'master_year':year or None}
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
