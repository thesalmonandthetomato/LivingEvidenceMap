#!/usr/bin/env python3
"""Run selected existing W01 preparatory stages read-only, then benchmark candidates."""
from pathlib import Path
import os, subprocess, sys, time, json
workflow = Path(".github/workflows/workflow_01_production.yml").read_text()
w00 = "docs/search_record/zenodo/run-39298022062.json"
w01 = "docs/deduplication/zenodo/run-39140209398.json"
stages = [
    "Restore latest Workflow 01 state from baseline plus deltas",
    "Restore current Workflow 00 source subset",
    "Prepare updated and preserved API source inputs",
    "Build runtime source catalogue and validate source inputs",
    "Build provenance-safe prior-plus-new manifestation union",
    "Generate incremental duplicate candidates",
]
report = {"schema":"experimental-w01-fast-real-benchmark-v1",
          "workflow00_pointer":w00,"previous_workflow01_pointer":w01,
          "production_w01_modified":False,"production_publication_allowed":False,
          "stages":[]}
Path("outputs/experimental_w01_fast").mkdir(parents=True,exist_ok=True)
def save(): Path("outputs/experimental_w01_fast/benchmark-stages.json").write_text(json.dumps(report,indent=2))
for name in stages:
    marker = "      - name: "+name+"\n"
    if workflow.count(marker)!=1: raise RuntimeError("Stage not unique: "+name)
    tail=workflow.split(marker,1)[1].split("\n      - name: ",1)[0]
    if "\n        run: |\n" not in tail: raise RuntimeError("Missing shell run block: "+name)
    source=tail.split("\n        run: |\n",1)[1].split("\n      - ",1)[0]
    lines=source.splitlines()
    if not all((not line.strip()) or line.startswith("          ") for line in lines):
        raise RuntimeError("Unexpected indentation in "+name)
    shell="\n".join(line[10:] if line.strip() else "" for line in lines)+"\n"
    shell=shell.replace("${{ inputs.workflow00_pointer_path }}",w00)
    shell=shell.replace("${{ inputs.previous_workflow01_pointer_path }}",w01)
    if "${{" in shell: raise RuntimeError("Unresolved workflow interpolation in "+name)
    start=time.monotonic()
    print("BEGIN SHADOW STAGE",name,flush=True)
    status=subprocess.run(["bash","-euo","pipefail","-c",shell],check=False).returncode
    elapsed=round(time.monotonic()-start,2)
    report["stages"].append({"name":name,"exit_code":status,"seconds":elapsed})
    save()
    print("END SHADOW STAGE",name,"status",status,"seconds",elapsed,flush=True)
    if status: sys.exit(status)
prev=json.loads(Path("previous_state/workflow01_full_five_source/summary.json").read_text())
prior=int(prev["source_manifestations"])
meta="outputs/workflow01_candidates/normalised_metadata.csv"
root="outputs/experimental_w01_fast"
tasks=[
  ("exact",["Rscript","scripts/updater/experimental_w01_fast/build_exact_block_index.R","--metadata",meta,"--prior-n",str(prior),"--output-dir",root+"/exact"]),
  ("fuzzy",["Rscript","scripts/updater/experimental_w01_fast/build_fuzzy_candidates.R","--metadata",meta,"--prior-n",str(prior),"--output-dir",root+"/fuzzy"]),
  ("combine",["Rscript","scripts/updater/experimental_w01_fast/combine_candidates.R",
      "--exact",root+"/exact/exact_block_candidates.csv","--fuzzy",root+"/fuzzy/fuzzy_candidates.csv",
      "--output",root+"/combined.csv"]),
  ("parity",["Rscript","scripts/updater/experimental_w01_fast/compare_production_candidates.R",
      "--production","outputs/workflow01_candidates/all_candidate_pairs.csv",
      "--experimental",root+"/combined.csv","--report",root+"/parity.json"])
]
for name,cmd in tasks:
    start=time.monotonic()
    print("BEGIN EXPERIMENT",name,flush=True)
    status=subprocess.run(cmd,check=False).returncode
    elapsed=round(time.monotonic()-start,2)
    report["stages"].append({"name":name,"exit_code":status,"seconds":elapsed})
    save()
    print("END EXPERIMENT",name,"status",status,"seconds",elapsed,flush=True)
    if status: sys.exit(status)
