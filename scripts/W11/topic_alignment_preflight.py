#!/usr/bin/env python3
"""Read-only W07/full-text pilot preflight: select a reproducible, identity-safe sample."""
import argparse,csv,hashlib,json,os,re,urllib.request,zipfile,io
from pathlib import Path

def get_json(url,token):
    req=urllib.request.Request(url,headers={"Authorization":"Bearer "+token,"Accept":"application/json"})
    with urllib.request.urlopen(req,timeout=75) as r:return json.load(r)
def get_bytes(url,token):
    req=urllib.request.Request(url,headers={"Authorization":"Bearer "+token})
    with urllib.request.urlopen(req,timeout=900) as r:return r.read()
def norm(s):return re.sub(r"^https?://(?:dx\.)?doi\.org/","",str(s or "").lower().strip())
def file_from_deposit(dep,token,name):
    matches=[f for f in dep["files"] if f["filename"]==name]
    if len(matches)!=1:raise RuntimeError("Expected one Zenodo file: "+name)
    return download_from_entry(matches[0],dep,token)
def download_from_entry(f,dep,token):
    import urllib.parse
    links=f.get("links",{})
    urls=[links.get("download"),links.get("self"),links.get("content")]
    if dep.get("links",{}).get("bucket"):
        urls.append(dep["links"]["bucket"].rstrip("/")+"/"+urllib.parse.quote(f["filename"],safe=""))
    for url in urls:
        if not url:continue
        try:return get_bytes(url,token)
        except Exception as e:print("Restricted Zenodo endpoint unavailable; trying next",type(e).__name__,flush=True)
    raise RuntimeError("All authenticated Zenodo endpoints failed for "+f["filename"])
def from_archive(blob,archive_name,filename):
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        files=[n for n in z.namelist() if n.endswith("/"+filename) or n==filename]
        if len(files)!=1:raise RuntimeError(f"ZIP identity ambiguous: {archive_name} {filename}: {files}")
        return z.read(files[0])
def strings(x):
    if isinstance(x,str):return [x]
    if isinstance(x,list):return sum([strings(y) for y in x],[])
    return []
def w07_entries(rec):
    """Inspect known W07 structures, but never fabricate a score or use W11 availability as W07 coding."""
    layers=[(k,v) for k,v in rec.items() if re.search(r"topic|workflow.?07|w07",k,re.I)]
    return {k:v for k,v in layers}
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--ledger",required=True);p.add_argument("--output",required=True);p.add_argument("--n",type=int,default=10)
    p.add_argument("--max-archives",type=int,default=8)
    a=p.parse_args();token=os.environ["ZENODO_ACCESS_TOKEN"]
    if a.n<1 or a.n>20:raise RuntimeError("Pilot restricted to at most 20 papers")
    out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
    ledger=list(csv.DictReader(open(a.ledger,encoding="utf-8-sig",newline="")))
    if len(ledger)!=22911:raise RuntimeError("Wrong canonical population")
    dep=get_json("https://zenodo.org/api/deposit/depositions/23459613",token)
    can=[f for f in dep["files"] if re.search(r"canonical.*\.jsonl$",f["filename"],re.I)]
    if len(can)!=1:raise RuntimeError("Cannot uniquely identify authoritative W08 canonical JSONL")
    body=download_from_entry(can[0],dep,token)
    lines=[ln for ln in body.decode("utf-8").splitlines() if ln.strip()]
    canonical_by_id={}
    for line in lines:
        rec=json.loads(line)
        rid=str(rec.get("identity",{}).get("record_id",""))
        if not rid or rid in canonical_by_id:raise RuntimeError("Missing or duplicate record ID in W08 JSONL")
        canonical_by_id[rid]=rec
    ledger_ids=[r["canonical_record_id"] for r in ledger]
    if len(set(ledger_ids))!=len(ledger_ids):raise RuntimeError("Duplicate IDs in W11 ledger")
    overlap=len(set(ledger_ids)&set(canonical_by_id))
    print(f"W08 included JSONL records={len(canonical_by_id)}, ledger records={len(ledger)}, ID overlap={overlap}",flush=True)
    if overlap<0.95*len(ledger):
        raise RuntimeError("W08/W11 ID overlap <95%; source snapshots are incompatible")
    candidates=[]
    for row in ledger:
        if row.get("historical_archive_link_accepted","").lower()!="true":continue
        if row.get("source_format","").lower() not in ("grobid_xml","xml","tei_xml"):continue
        if not row.get("zenodo_deposit_id") or not row.get("archive_filename") or not row.get("within_zip_filename"):continue
        rec=canonical_by_id.get(row["canonical_record_id"])
        if rec is None:continue
        details=w07_entries(rec)
        if not details:continue
        candidates.append((row,rec,details))
    if not candidates:raise RuntimeError("No W08 included archived XML record with observable W07 topic data; do not run model calls")
    # Select across archive deposits, preferring files already packed together, and avoiding multiple manifestations.
    candidates.sort(key=lambda v:(v[0]["zenodo_deposit_id"],v[0]["canonical_record_id"]))
    unique=[];seen=set();deps=set()
    for row,rec,details in candidates:
        ident=row["canonical_record_id"];dep_id=row["zenodo_deposit_id"]
        if ident in seen or (dep_id not in deps and len(deps)>=a.max_archives):continue
        seen.add(ident);deps.add(dep_id);unique.append((row,rec,details))
        if len(unique)>=a.n:break
    if len(unique)<a.n:raise RuntimeError(f"Only {len(unique)} identity-safe candidate XMLs, need {a.n}")
    Path(out/"pilot_w07_field_structure.json").write_text(json.dumps([{"record_id":r["canonical_record_id"],"w07_fields":list(d)} for r,_,d in unique],indent=2))
    # Save W07 field source unchanged; ensure they are not accidentally supplied as model inputs.
    archives={}
    manifest=[]
    (out/"xml").mkdir(exist_ok=True)
    for row,rec,details in unique:
        deposit=row["zenodo_deposit_id"];name=row["archive_filename"]
        key=(deposit,name)
        if key not in archives:
            d=get_json("https://zenodo.org/api/deposit/depositions/"+deposit,token)
            archives[key]=file_from_deposit(d,token,name)
        blob=from_archive(archives[key],name,row["within_zip_filename"])
        if not blob.lstrip().startswith((b"<?xml",b"<TEI",b"<tei",b"<")):
            raise RuntimeError("Retrieved file is not plausible XML: "+row["canonical_record_id"])
        sha=hashlib.sha256(blob).hexdigest()
        known=row.get("sha256","").lower()
        if known and re.fullmatch("[0-9a-f]{64}",known) and sha!=known:
            raise RuntimeError("SHA256 mismatch for "+row["canonical_record_id"])
        dest=out/"xml"/(row["canonical_record_id"].replace("/","_")+".xml")
        dest.write_bytes(blob)
        manifest.append({"canonical_record_id":row["canonical_record_id"],"doi":norm(row["canonical_doi"]),
          "canonical_title":row["canonical_title"],"canonical_year":row["canonical_year"],
          "xml_file":str(dest),"xml_sha256":sha,"zenodo_deposit":deposit,
          "zenodo_archive":name,"within_zip_filename":row["within_zip_filename"],
          "w07_raw_source":details})
    (out/"sample_manifest.json").write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+"\n")
    print(json.dumps({"eligible_with_w07_field":len(candidates),"selected":len(manifest),
      "deposits":sorted(deps),"xmls_verified":len(manifest),
      "w07_field_names":sorted(set(k for m in manifest for k in m["w07_raw_source"]))},indent=2))
if __name__=="__main__":main()
