#!/usr/bin/env python3
"""W11 stand-alone 10-paper methods/results topic alignment against immutable W07."""
import argparse,csv,hashlib,json,os,re,time,urllib.request
from pathlib import Path

def request(url,data=None):
    hd={"Accept":"application/json"}
    if data is not None:
        hd.update({"Authorization":"Bearer "+os.environ["OPENAI_API_KEY"],"Content-Type":"application/json"})
    req=urllib.request.Request(url,data=None if data is None else json.dumps(data).encode(),headers=hd,method="POST" if data else "GET")
    with urllib.request.urlopen(req,timeout=350) as r:return json.load(r) if data else r.read()
def text(x):
    if isinstance(x,str):return x
    if isinstance(x,list):return "\n".join(text(z) for z in x)
    if isinstance(x,dict):return "\n".join(text(z) for z in x.values())
    return ""
def w07_codes(x,allowed):
    """Conservative nested extraction, scores retained; caller must verify source keys."""
    found={}
    def walk(v):
        if isinstance(v,list):
            for z in v:walk(z)
        elif isinstance(v,dict):
            code=v.get("path_id") or v.get("topic_path_id")
            if isinstance(code,str) and code in allowed:
                n=v.get("support_count",v.get("support",v.get("copies",None)))
                kept=v.get("retained_for_analysis",None)
                found.setdefault(code,{"support":n,"retained_for_analysis":kept})
            for z in v.values():walk(z)
    walk(x)
    return found
def api_text(r):
    return "\n".join(c["text"] for z in r.get("output",[]) for c in z.get("content",[]) if c.get("type")=="output_text")
def main():
    ap=argparse.ArgumentParser();ap.add_argument("--manifest",required=True);ap.add_argument("--out",required=True)
    ap.add_argument("--model",default="gpt-5.6-luna");ap.add_argument("--n",type=int,default=10)
    a=ap.parse_args()
    out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
    manifest=json.loads(Path(a.manifest).read_text())[:a.n]
    if not manifest:raise RuntimeError("Empty pilot sample")
    # Match the frozen production ontology, not full-text pilot v3.
    ontology_url="https://raw.githubusercontent.com/thesalmonandthetomato/LivingEvidenceMap/workflow07-canonical-jsonl-dashboard/data/reference/topic_ontology_v3_6.csv"
    content=request(ontology_url)
    digest=hashlib.sha256(content).hexdigest()
    expected="5d78959f86d40f200f7dc7c3184a2d5ab61fd89d1450be7fbff39c2578246a43"
    if digest!=expected:raise RuntimeError(f"Frozen v3.6 ontology SHA mismatch {digest}; model calls disabled")
    (out/"frozen_ontology_v3_6.csv").write_bytes(content)
    import io
    ontology=list(csv.DictReader(io.StringIO(content.decode("utf-8-sig"))))
    valid={r["path_id"] for r in ontology}
    # Refuse blind calls if W07 source assignments cannot be extracted.
    scores={m["canonical_record_id"]:w07_codes(m["w07_raw_source"],valid) for m in manifest}
    if not any(scores.values()):
        raise RuntimeError("No W07 path_id assignments extracted; inspect pilot_w07_field_structure.json before model calls")
    system=("Classify the focal salmon aquaculture article into the supplied frozen W07 v3.6 ontology. "
       "Use article OBJECTIVES, METHODS and RESULTS as controlling evidence. Do not classify incidental "
       "background or cited-study claims. Do not infer subjects beyond the focal eligible salmonid component. "
       "Return JSON object with ontology_codes array of v3.6 path_id strings and evidence array of objects "
       "{path_id, objective_quote, methods_quote, results_quote, section}. Evidence must be directly drawn "
       "from supplied article. At least one direct method/results quotation is required per code. "
       "Return [] where no pathway can be substantiated; no invented citations. "
       "Do not return extra codes not in ontology.")
    records=[]
    for i,m in enumerate(manifest,1):
        rid=m["canonical_record_id"];result_file=out/(str(i).zfill(2)+"_result.json")
        raw_file=out/(str(i).zfill(2)+"_raw.json")
        if raw_file.exists() and result_file.exists():
            obj=json.loads(result_file.read_text())
        else:
            xml=Path(m["xml_file"]).read_text(encoding="utf-8",errors="replace")
            if len(xml)<1500:raise RuntimeError(f"XML too short for {rid}")
            # Context budget fail-closed: XML is not silently truncated.
            if len(xml)>500000:
                raise RuntimeError(f"XML too long ({len(xml)} chars) for pilot; requires section extraction: {rid}")
            user={"canonical_record_id":rid,"title":m["canonical_title"],"article_xml":xml,
                  "ontology":ontology}
            payload={"model":a.model,"input":[{"role":"system","content":system},
              {"role":"user","content":json.dumps(user,ensure_ascii=False)}]}
            response=request(os.environ.get("OPENAI_BASE_URL","https://api.openai.com/v1").rstrip("/")+"/responses",payload)
            raw_file.write_text(json.dumps(response,ensure_ascii=False,indent=2))
            try:obj=json.loads(api_text(response))
            except Exception as e:raise RuntimeError(f"Model output invalid for {rid}; raw checkpoint preserved: {e}")
            (result_file).write_text(json.dumps(obj,ensure_ascii=False,indent=2))
        codes=obj.get("ontology_codes",[])
        if not isinstance(codes,list) or any(not isinstance(c,str) or c not in valid for c in codes):
            raise RuntimeError(f"Invalid ontology code for {rid}; checkpoints saved")
        evidence=obj.get("evidence",[])
        if codes and (not isinstance(evidence,list) or not all(any(isinstance(z,dict) and z.get("path_id")==c and (z.get("methods_quote") or z.get("results_quote")) for z in evidence) for c in codes)):
            raise RuntimeError(f"Missing method/result evidence for {rid}; checkpoints saved")
        old=scores[rid];baseline={k for k,v in old.items() if v.get("retained_for_analysis") is not False}
        new=set(codes);u=baseline|new
        records.append({"canonical_record_id":rid,"doi":m["doi"],"old_w07_codes":sorted(baseline),
            "old_w07_support":old,"fulltext_codes":sorted(new),"agreed_codes":sorted(baseline&new),
            "abstract_only":sorted(baseline-new),"fulltext_only":sorted(new-baseline),
            "exact_match":baseline==new,"jaccard":(len(baseline&new)/len(u) if u else None),
            "old_3of3_recalled":sorted(k for k,v in old.items() if str(v.get("support")) in ("3","3/3") and k in new)})
        (out/"paired_results.json").write_text(json.dumps(records,indent=2)+"\n")
        print(f"Completed {i}/{len(manifest)}: {rid}; W07 {len(baseline)}, full text {len(new)}",flush=True)
        time.sleep(0.25)
    with open(out/"paired_comparison.csv","w",newline="") as f:
        fields=["canonical_record_id","doi","old_w07_codes","fulltext_codes","agreed_codes","abstract_only","fulltext_only","exact_match","jaccard"]
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for r in records:w.writerow({k:json.dumps(r[k]) if isinstance(r[k],list) else r[k] for k in fields})
    print(json.dumps({"papers":len(records),"exact_agreement":sum(r["exact_match"] for r in records),
         "mean_jaccard_excluding_both_empty":sum(r["jaccard"] for r in records if r["jaccard"] is not None)/max(1,sum(r["jaccard"] is not None for r in records))},indent=2))
if __name__=="__main__":main()
