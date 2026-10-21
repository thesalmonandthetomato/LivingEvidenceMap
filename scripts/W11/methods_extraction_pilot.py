#!/usr/bin/env python3
"""Isolated W11 methods-only pilot: same ten provenance-verified XMLs."""
import argparse,copy,hashlib,json,os,re,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path

FIELDS="document_type review_type study_type study_design research_approach setting sample_unit study_period location_region location_country species other_farmed_species study_population aquaculture_facility system_studied production_stage fish_life_stage exposure_intervention comparator outcome_measured funding_body research_question objectives_summary multiple_studies_flag multiple_studies_reason".split()
ELIGIBLE="Atlantic salmon; chum salmon; pink salmon; coho salmon; chinook salmon; sockeye salmon; masu salmon; rainbow trout; unspecified salmon species"
RULES="""Use only two complete paragraphs immediately preceding the Methods heading plus the entire Methods section. Eligible salmon/rainbow trout species means ONLY: """+ELIGIBLE+""".
Never transfer characteristics from ineligible species or different species-specific study components. No ontology topic coding.
Classify the focal document, not studies merely cited. Study design must follow defined categories: BA (before/after), CI (controlled intervention), BACI (before-after control-impact), RCT (randomised controlled trial), Time-series, Modelling, Qualitative, not_stated, not_applicable. Do not infer randomisation. study_type experimental requires imposed manipulation on the eligible population, not laboratory processing of samples. setting concerns the substantive study setting, not where specimens were processed. sample_unit is the primary sampling/experimental unit, not technical subsamples. production_stage refers to the production context actually studied, not a background mention. fish_life_stage can be inferred only as Juvenile or Adult on sufficiently strong evidence; all other stages require explicit description. Land-based research tanks are not necessarily recirculating aquaculture systems.
exposure_intervention must be actively investigated, not routine husbandry. comparator must be a substantive control or alternative, not merely an analytical subgroup. outcome_measured lists methods-defined measured variables, NOT results or conclusions; do not invent numerical findings. funding_body only when directly stated. research_question and objectives_summary use explicit aims, including those in preceding paragraphs. multiple_studies_flag only where independently structured eligible studies are positively established; if false, reason is null.
Return exactly 25 substantive fields and evidence, document_completeness, document_completeness_evidence, field_completeness, not_reported_fields. No ontology_codes. Preserve schema types and enums. For an applicable but unsupported field return the schema's NOT FOUND convention; never use absence to claim the entire paper lacks the field. For each supported field supply a field-specific quotation exactly drawn from provided text with section and page (if present). document_completeness judges integrity of the intentionally restricted extract, not absence of Results/Discussion. Output ONLY a valid JSON object."""
def lname(t):return t.rsplit("}",1)[-1].lower()
def owntext(el):return " ".join(" ".join(el.itertext()).split())
def is_methods(h):return bool(re.search(r"^(?:\d+(?:\.\d+)*\s*)?(?:materials?\s*(?:and|&)\s*methods?|methods?|methodology|experimental\s*(?:procedures?|design)|patients?\s*(?:and|&)\s*methods?)\b",h,re.I))
def extract(xml):
    root=ET.fromstring(xml)
    # Prefer TEI body, otherwise article body. Do not search bibliography/headings in references.
    bodies=[e for e in root.iter() if lname(e.tag)=="body"]
    if len(bodies)!=1:raise RuntimeError("Ambiguous or absent XML body")
    body=bodies[0]
    top=[e for e in body.iter() if lname(e.tag)=="div"]
    matches=[d for d in top if any(lname(c.tag)=="head" and is_methods(owntext(c)) for c in list(d))]
    if len(matches)!=1:
        headings=[owntext(c)[:130] for d in top for c in list(d) if lname(c.tag)=="head"]
        raise RuntimeError("Expected one Methods section; found "+str(len(matches))+"; available XML section headings: "+repr(headings[:60]))
    target=matches[0]
    # Paragraphs preceding heading in document order (excluding table/figure material).
    para=[x for x in body.iter() if lname(x.tag)=="p"]
    mhead=next(x for x in list(target) if lname(x.tag)=="head" and is_methods(owntext(x)))
    nodes=list(body.iter()); idx={id(n):i for i,n in enumerate(nodes)}
    before=[p for p in para if idx[id(p)]<idx[id(mhead)] and len(owntext(p))>20]
    if len(before)<2:raise RuntimeError("Fewer than two paragraphs before Methods")
    paras=before[-2:]
    method_text=owntext(target)
    if len(method_text)<300:raise RuntimeError("Methods section suspiciously short")
    return "\n\n".join(["[Two preceding paragraphs]",*[owntext(p) for p in paras],"[Complete Methods section]",method_text]),{"preceding_paragraphs":2,"methods_chars":len(method_text),"total_chars":len(method_text)+sum(len(owntext(p)) for p in paras)}
def api_call(payload):
    endpoint=os.environ.get("OPENAI_BASE_URL","https://api.openai.com/v1").rstrip("/")+"/responses"
    req=urllib.request.Request(endpoint,data=json.dumps(payload).encode(),headers={"Authorization":"Bearer "+os.environ["OPENAI_API_KEY"],"Content-Type":"application/json"},method="POST")
    with urllib.request.urlopen(req,timeout=500) as r:return json.load(r)
def answer(r):return "".join(c.get("text","") for x in r.get("output",[]) for c in x.get("content",[]) if c.get("type")=="output_text")
def main():
    p=argparse.ArgumentParser();p.add_argument("--manifest",required=True);p.add_argument("--out",required=True);p.add_argument("--schema",required=True);p.add_argument("--model",default="gpt-5.6-luna");p.add_argument("--extract-only",action="store_true")
    a=p.parse_args();out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
    manifest=json.loads(Path(a.manifest).read_text())
    if len(manifest)!=10 or len({m["canonical_record_id"] for m in manifest})!=10:raise RuntimeError("Expected ten unique pilot records")
    schema=json.loads(Path(a.schema).read_text());schema=copy.deepcopy(schema)
    schema.pop("ontology_codes",None);schema["fields"].pop("ontology_codes",None)
    for k in ("current_substantive_fields",):
        schema[k]=[v for v in schema[k] if v!="ontology_codes"]
    schema["field_completeness"]["allowed_fields"]=[v for v in schema["field_completeness"]["allowed_fields"] if v!="ontology_codes"]
    schema["not_reported_fields"]["allowed_values"]=[v for v in schema["not_reported_fields"]["allowed_values"] if v!="ontology_codes"]
    if set(schema["fields"])!=set(FIELDS):raise RuntimeError("Method-only schema mismatch")
    (out/"method_only_schema.json").write_text(json.dumps(schema,indent=2))
    (out/"prompt.txt").write_text(RULES)
    summary=[]
    for i,m in enumerate(manifest,1):
        path=Path(m["xml_file"]);blob=path.read_bytes()
        if hashlib.sha256(blob).hexdigest()!=m["xml_sha256"]:raise RuntimeError("XML checksum changed "+m["canonical_record_id"])
        extracted,meta=extract(blob)
        pref=out/("%02d"%i)
        (out/("%02d"%i+"_input.txt")).write_text(extracted)
        result={"canonical_record_id":m["canonical_record_id"],"doi":m["doi"],"xml_sha256":m["xml_sha256"],**meta}
        if not a.extract_only:
            payload={"model":a.model,"input":[{"role":"system","content":RULES},{"role":"user","content":json.dumps({"record_id":m["canonical_record_id"],"article_extract":extracted,"schema":schema},ensure_ascii=False)}]}
            response=api_call(payload);(out/("%02d"%i+"_raw.json")).write_text(json.dumps(response,indent=2))
            decoded=json.loads(answer(response))
            if set(decoded)!=set(FIELDS)|set(schema["audit_fields"]):raise RuntimeError("Unexpected extraction keys for "+m["canonical_record_id"])
            (out/("%02d"%i+"_extraction.json")).write_text(json.dumps(decoded,indent=2,ensure_ascii=False))
            result["usage"]=response.get("usage",{})
        summary.append(result)
        (out/"manifest_summary.json").write_text(json.dumps(summary,indent=2))
        print(f"Prepared {i}/10 "+m["canonical_record_id"]+"; method chars "+str(meta["methods_chars"]),flush=True)
    print(json.dumps({"articles":len(summary),"total_extract_chars":sum(x["total_chars"] for x in summary),"model_calls":0 if a.extract_only else len(summary)}))
if __name__=="__main__":main()
