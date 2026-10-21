#!/usr/bin/env python3
import argparse,csv,json,statistics
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("--first",required=True);p.add_argument("--second",required=True);p.add_argument("--out",required=True)
a=p.parse_args()
first=json.loads(Path(a.first).read_text()); second=json.loads(Path(a.second).read_text())
one={r["canonical_record_id"]:r for r in first};two={r["canonical_record_id"]:r for r in second}
if len(one)!=10 or set(one)!=set(two):raise RuntimeError("Pass identities differ; comparison invalid")
out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
rows=[]
for rid in one:
 x=one[rid];y=two[rid]
 if x["doi"]!=y["doi"] or set(x["old_w07_codes"])!=set(y["old_w07_codes"]):raise RuntimeError("W07 baseline mismatch "+rid)
 a1=set(x["fulltext_codes"]);b=set(y["fulltext_codes"]);w=set(x["old_w07_codes"])
 j=lambda q,r: (len(q&r)/len(q|r)) if q|r else None
 rows.append(dict(canonical_record_id=rid,doi=x["doi"],w07_codes=sorted(w),pass1_codes=sorted(a1),pass2_codes=sorted(b),
      both_fulltext=sorted(a1&b),only_pass1=sorted(a1-b),only_pass2=sorted(b-a1),
      pass1_pass2_exact=a1==b,pass1_pass2_jaccard=j(a1,b),
      w07_pass1_jaccard=j(w,a1),w07_pass2_jaccard=j(w,b),
      w07_in_both=sorted(w&a1&b),stable_fulltext_only=sorted((a1&b)-w),
      unstable_fulltext_only=sorted((a1^b)-w)))
(out/"pass_comparison.json").write_text(json.dumps(rows,indent=2)+"\n")
with (out/"pass_comparison.csv").open("w",newline="") as f:
 cols=list(rows[0]);wr=csv.DictWriter(f,fieldnames=cols);wr.writeheader()
 for row in rows:wr.writerow({k:json.dumps(v) if isinstance(v,list) else v for k,v in row.items()})
summary={"papers":len(rows),"exact_between_passes":sum(x["pass1_pass2_exact"] for x in rows),
 "mean_jaccard_between_passes":statistics.mean(x["pass1_pass2_jaccard"] for x in rows if x["pass1_pass2_jaccard"] is not None),
 "exact_W07_pass1":sum(set(x["w07_codes"])==set(x["pass1_codes"]) for x in rows),
 "exact_W07_pass2":sum(set(x["w07_codes"])==set(x["pass2_codes"]) for x in rows),
 "mean_W07_pass1_jaccard":statistics.mean(x["w07_pass1_jaccard"] for x in rows if x["w07_pass1_jaccard"] is not None),
 "mean_W07_pass2_jaccard":statistics.mean(x["w07_pass2_jaccard"] for x in rows if x["w07_pass2_jaccard"] is not None),
 "stable_new_topics_count":sum(len(x["stable_fulltext_only"]) for x in rows)}
(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
print(json.dumps(summary,indent=2))
