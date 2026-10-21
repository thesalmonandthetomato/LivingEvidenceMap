#!/usr/bin/env python3
"""Read-only ten-paper full-XML extraction pilot, independent of production."""
import argparse,hashlib,json,os,urllib.request,copy,time
from pathlib import Path
from methods_extraction_pilot import FIELDS,ELIGIBLE
def run():
 p=argparse.ArgumentParser()
 p.add_argument("--manifest",required=True);p.add_argument("--schema",required=True);p.add_argument("--out",required=True)
 a=p.parse_args();out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
 original=json.loads(Path(a.manifest).read_text())
 if len(original)!=10 or len({m["canonical_record_id"] for m in original})!=10:raise RuntimeError("Wrong pilot sample")
 schema=copy.deepcopy(json.loads(Path(a.schema).read_text()))
 schema.pop("ontology_codes",None);schema["fields"].pop("ontology_codes",None)
 schema["current_substantive_fields"]=[x for x in schema["current_substantive_fields"] if x!="ontology_codes"]
 for key in ("field_completeness","not_reported_fields"):
  sub="allowed_fields" if key=="field_completeness" else "allowed_values"
  schema[key][sub]=[x for x in schema[key][sub] if x!="ontology_codes"]
 if set(schema["fields"])!=set(FIELDS):raise RuntimeError("Unexpected extraction schema")
 prompt=("Extract all 25 substantive fields in the supplied fulltext_coding_v3 schema from the entire supplied article XML. "
 "The ONLY eligible salmon/rainbow trout species are: "+ELIGIBLE+". All study setting, population, design, intervention, "
 "comparison and outcome evidence must apply specifically to the eligible salmon/rainbow trout species studied. "
 "Never transfer findings from a different species or cited studies. Do not undertake topic classification and "
 "do not output ontology_codes. Use the full article's objectives, methods, results and funding acknowledgements "
 "where relevant. Identify measured outcomes, not speculative discussion. Follow the supplied schema enumerations "
 "and the original fulltext_coding_v3 definitions: experimental implies imposed manipulation, CI is controlled intervention, "
 "RCT requires reported random allocation; field setting is not laboratory merely because samples were analysed there. "
 "Don't infer life stages except Juvenile or Adult with adequate evidence. Don't misclassify generic rearing as intervention; "
 "don't invent comparators. For every supported field supply a direct, field-specific source quotation with section and "
 "page if known. Use schema NOT FOUND conventions for missing fields; never invent facts. "
 "Return ONLY a JSON object comprising 25 substantive fields and all five audit fields.")
 (out/"prompt.txt").write_text(prompt)
 (out/"schema.json").write_text(json.dumps(schema,indent=2))
 summary=[]
 for i,m in enumerate(original,1):
  blob=Path(m["xml_file"]).read_bytes()
  if hashlib.sha256(blob).hexdigest()!=m["xml_sha256"]:raise RuntimeError("XML changed "+m["canonical_record_id"])
  xml=blob.decode("utf-8",errors="replace")
  if len(xml)<1500 or len(xml)>500000:raise RuntimeError("XML outside verified pilot size envelope for "+m["canonical_record_id"])
  payload={"model":"gpt-5.6-luna","text":{"format":{"type":"json_object"}},"input":[{"role":"system","content":prompt},{"role":"user","content":json.dumps({"record_id":m["canonical_record_id"],"full_article_xml":xml,"schema":schema},ensure_ascii=False)}]}
  req=urllib.request.Request(os.environ.get("OPENAI_BASE_URL","https://api.openai.com/v1").rstrip("/")+"/responses",data=json.dumps(payload).encode(),headers={"Authorization":"Bearer "+os.environ["OPENAI_API_KEY"],"Content-Type":"application/json"},method="POST")
  with urllib.request.urlopen(req,timeout=500) as response:r=json.load(response)
  pref=out/("%02d"%i)
  Path(str(pref)+"_raw.json").write_text(json.dumps(r,indent=2))
  raw="\n".join(c["text"] for z in r.get("output",[]) for c in z.get("content",[]) if c.get("type")=="output_text")
  decoded=json.loads(raw)
  expected=set(FIELDS)|set(schema["audit_fields"])
  if set(decoded)!=expected:raise RuntimeError("Extraction keys mismatch "+m["canonical_record_id"]+": "+repr(set(decoded)^expected))
  Path(str(pref)+"_extraction.json").write_text(json.dumps(decoded,ensure_ascii=False,indent=2))
  summary.append({"record_id":m["canonical_record_id"],"doi":m["doi"],"xml_sha256":m["xml_sha256"],"xml_characters":len(xml),"usage":r.get("usage",{})})
  (out/"usage_summary.json").write_text(json.dumps(summary,indent=2))
  print("Completed "+str(i)+"/10 "+m["canonical_record_id"],flush=True)
  time.sleep(.2)
 print(json.dumps({"completed":len(summary),"input_tokens":sum(x["usage"].get("input_tokens",0) for x in summary),"output_tokens":sum(x["usage"].get("output_tokens",0) for x in summary)}))
if __name__=="__main__":run()
