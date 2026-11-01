#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
root<-tempfile("w01-fast-contract-");dir.create(root)
on.exit(unlink(root,recursive=TRUE),add=TRUE)
file<-function(n)file.path(root,n)
m<-data.table(source=c("a","b"),source_record_id=c("x","y"),cluster_id=c("work-1","work-1"),cluster_size=c(2L,2L))
fwrite(m,file("map.csv"))
z<-list(schema_version="living-evidence-map-canonical-v1",
identity=list(record_id="work-1",record_id_type="deduplication_cluster_id"),
canonical=list(title="Fixture"),deduplication=list(cluster_id="work-1",member_count=2L),
manifestations=list(list(source="a",source_record_id="x",abstract="a"),list(source="b",source_record_id="y",abstract="b")))
writeLines(toJSON(z,auto_unbox=TRUE,null="null"),file("canonical.jsonl"))
file.create(file("strips.jsonl"));file.create(file("repairs.jsonl"));file.create(file("audit.jsonl"))
write_json(list(approved_data_quality_repairs=0L,applied_data_quality_repairs=0L),file("prev_manifest.json"),auto_unbox=TRUE)
script<-"scripts/updater/experimental_w01_fast/stage_production_canonical_contract.R"
call<-function(out)system2(file.path(R.home("bin"),"Rscript"),
c(script,"--cluster-map",file("map.csv"),"--canonical",file("canonical.jsonl"),
"--output-dir",out,"--run-id","fixture","--strip-actions",file("strips.jsonl"),
"--repair-ledger",file("repairs.jsonl"),"--repair-audit",file("audit.jsonl"),
 "--previous-canonical-manifest",file("prev_manifest.json")),
stdout=TRUE,stderr=TRUE)
x<-call(file("valid"));stopifnot(is.null(attr(x,"status"))||attr(x,"status")==0L)
a<-fromJSON(file("valid/canonical_manifest.json"))
stopifnot(a$records==1L,a$source_manifestations==2L,
a$duplicate_clusters==1L,
identical(a$canonical_jsonl_sha256,digest(file=file("valid/records.jsonl"),algo="sha256")))
m[2L,cluster_id:="work-2"];fwrite(m,file("map.csv"))
b<-suppressWarnings(call(file("invalid")));stopifnot(!is.null(attr(b,"status")),attr(b,"status")!=0L)
cat("PASS: canonical contract staging and mismatched identity rejection\\n")

# Verify the orchestrator supplies the complete required production canonical contract.
orchestrator<-paste(readLines("scripts/updater/experimental_w01_fast/run_full_incremental_update.R",warn=FALSE),collapse="\n")
section<-strsplit(orchestrator,'run("stage_canonical_contract"',fixed=TRUE)[[1L]]
stopifnot(length(section)==2L)
contract_call<-strsplit(section[[2L]],'# Validate persistence',fixed=TRUE)[[1L]][[1L]]
stopifnot(grepl('"--previous-canonical-manifest"',contract_call,fixed=TRUE),
          grepl('file.path(previous_root,"canonical","canonical_manifest.json")',contract_call,fixed=TRUE))


# The production delta generator and replayer must agree on the manifest filename.
builder<-paste(readLines("scripts/updater/workflow_01_build_delta.R",warn=FALSE),collapse="\n")
replayer<-paste(readLines("scripts/updater/workflow_01_replay_delta.R",warn=FALSE),collapse="\n")
acceptance<-paste(readLines(".github/workflows/w01_fast_integration_acceptance.yml",warn=FALSE),collapse="\n")
stopifnot(grepl('file.path(output_dir,"delta_manifest.json")',builder,fixed=TRUE),
          grepl('file.path(delta_dir,"delta_manifest.json")',replayer,fixed=TRUE),
          grepl("file.path(base,'delta','delta_manifest.json')",acceptance,fixed=TRUE),
          !grepl("file.path(base,'delta','manifest.json')",acceptance,fixed=TRUE))
