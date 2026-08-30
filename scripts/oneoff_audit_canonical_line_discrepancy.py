#!/usr/bin/env python3
import json, hashlib
from collections import Counter, defaultdict
from pathlib import Path
P=Path('data/canonical/current/repair/records.jsonl')
lines=[x for x in P.read_text(encoding='utf-8').splitlines() if x.strip()]
parsed=[]; bad=[]
for i,line in enumerate(lines,1):
    try: parsed.append(json.loads(line))
    except Exception as e: bad.append({'line':i,'error':str(e),'prefix':line[:120]})
ids=[]; missing=[]
for i,r in enumerate(parsed,1):
    lid=((r.get('identity') or {}).get('lens_id'))
    if not lid: missing.append(i)
    else: ids.append(lid.upper())
c=Counter(ids)
dups={k:v for k,v in c.items() if v>1}
by=defaultdict(list)
for r in parsed:
    lid=((r.get('identity') or {}).get('lens_id') or '').upper()
    if lid in dups: by[lid].append(r)
identical=0; nonidentical=[]
for lid,recs in by.items():
    canon=[json.dumps(r,sort_keys=True,separators=(',',':')) for r in recs]
    if len(set(canon))==1: identical += len(recs)-1
    else:
        nonidentical.append({'lens_id':lid,'occurrences':len(recs),'decisions':[(((r.get('screening') or {}).get('relevance') or {}).get('decision')) for r in recs]})
print(json.dumps({'nonempty_lines':len(lines),'json_parse_errors':len(bad),'parsed_records':len(parsed),'missing_lens_ids':len(missing),'unique_lens_ids':len(c),'duplicate_lens_ids':len(dups),'duplicate_extra_occurrences':sum(v-1 for v in dups.values()),'byte_semantic_identical_extra_occurrences':identical,'nonidentical_duplicate_groups':len(nonidentical),'sample_nonidentical':nonidentical[:20]},indent=2))
if bad: print('PARSE_ERRORS',json.dumps(bad[:10],indent=2))
