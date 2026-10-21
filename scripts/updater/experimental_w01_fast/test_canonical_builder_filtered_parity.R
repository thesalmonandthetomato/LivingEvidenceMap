#!/usr/bin/env Rscript
# Small end-to-end fixture: unchanged canonical builder on full corpus vs
# identity-filtered affected sources. Never accesses GitHub production state.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("canonical-parity-");dir.create(root)
runner<-file.path(R.home("bin"),"Rscript")
run<-function(script,args){
 log<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if(status!=0L)stop(sprintf("Script %s failed: %s",script,paste(log,collapse=" | ")))
}
record<-function(id)toJSON(list(identity=list(lens_id=id),
 canonical=list(title=paste("Article",id),abstract=paste("Abstract",id),
 year=2024,doi=paste0("10.1111/",id)),
 lens=list(raw_payload=list(title=paste("Article",id)))),auto_unbox=TRUE)
source<-file.path(root,"lens.jsonl")
writeLines(vapply(c("A","B","C"),record,character(1)),source)
im<-file.path(root,"inputs.json")
writeLines(toJSON(list(schema="living-evidence-map-workflow01-source-inputs-v1",
 sources=list(lens=list(source))),auto_unbox=TRUE),im)
map<-data.table(source="lens",source_record_id=c("A","B","C"),
 cluster_id=c("work-affected","work-affected","work-untouched"),
 cluster_size=c(2L,2L,1L))
fullmap<-file.path(root,"fullmap.csv");fwrite(map,fullmap)
scope<-file.path(root,"scope.csv");fwrite(map[cluster_id=="work-affected"],scope)
filter_out<-file.path(root,"filtered")
run("scripts/updater/experimental_w01_fast/filter_canonical_source_inputs.R",
 c("--affected-cluster-map",scope,"--input-manifest",im,"--output-dir",filter_out))
builder<-"scripts/updater/workflow_01_build_canonical_jsonl.R"
strips<-file.path(root,"strips.jsonl")
repairs<-file.path(root,"repairs.jsonl")
writeLines(toJSON(list(source="lens",source_record_id="A"),auto_unbox=TRUE),strips)
writeLines(toJSON(list(source="lens",source_record_id="B",action="set_title",value="Corrected B",review_case_id="fixture-1"),auto_unbox=TRUE),repairs)
directives<-file.path(root,"filtered-directives")
run("scripts/updater/experimental_w01_fast/filter_canonical_directives.R",
 c("--affected-cluster-map",scope,"--strip-actions",strips,
 "--data-quality-repairs",repairs,"--output-dir",directives))
canonical<-function(map_path,input_manifest,dir,strip_path,repairs_path){
 dir.create(dir)
 output<-file.path(dir,"canonical.jsonl")
 run(builder,c("--cluster-map",map_path,"--input-manifest",input_manifest,
 "--run-id","synthetic-test","--strip-actions",strip_path,
 "--data-quality-repairs",repairs_path,"--output",output,
 "--manifest",file.path(dir,"manifest.json"),
 "--repair-audit",file.path(dir,"repair_audit.jsonl")))
 lapply(readLines(output,warn=FALSE),function(line)fromJSON(line,simplifyVector=FALSE))
}
all<-canonical(fullmap,im,file.path(root,"full"),strips,repairs)
part<-canonical(scope,file.path(filter_out,"filtered_source_inputs.json"),
 file.path(root,"partial"),file.path(directives,"strip_actions.jsonl"),
 file.path(directives,"data_quality_repairs.jsonl"))
find_work<-function(records,id){
 hits<-Filter(function(rec)identical(rec$deduplication$cluster_id,id),records)
 if(length(hits)!=1L)stop("Missing or duplicate canonical work");hits[[1L]]
}
# The identical original scientific materialiser must produce the same work
# record whether invoked on the full corpus or on exact affected-source subset.
stopifnot(length(all)==2L,length(part)==1L,
 identical(find_work(all,"work-affected"),find_work(part,"work-affected")))
stopifnot(identical(readLines(file.path(root,"full","repair_audit.jsonl")),
 readLines(file.path(root,"partial","repair_audit.jsonl"))))
cat("PASS: unchanged canonical builder parity including strip action and approved repair\\n")


# Verify a complete isolated incremental assembly against the unchanged full
# builder. Original records must remain byte-for-byte unchanged.
affected_manifest<-file.path(root,"affected_works.csv")
writeLines(c("stage,cluster_id","prior,work-affected","successor,work-affected"),
 affected_manifest)
assembled_dir<-file.path(root,"assembled")
run("scripts/updater/experimental_w01_fast/recombine_canonical_jsonl.R",
 c("--prior",file.path(root,"full","canonical.jsonl"),
 "--changed",file.path(root,"partial","canonical.jsonl"),
 "--affected-works",affected_manifest,"--output-dir",assembled_dir))
assembled<-readLines(file.path(assembled_dir,"canonical.jsonl"))
baseline<-readLines(file.path(root,"full","canonical.jsonl"))
stopifnot(setequal(assembled,baseline),
 length(assembled)==length(baseline))
cat("PASS: complete affected-only canonical assembly reproduces full-corpus JSONL\\n")

# Integrate assembled canonical output into versioned snapshot and guarded state.
# This validates the handoff, without using production source data or publishing.
snapshot<-file.path(root,"canonical-checkpoint")
run("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id","canonical-fixture-1",
 "--artifact",paste0("canonical=",file.path(assembled_dir,"canonical.jsonl")),
 "--output-dir",snapshot))
state<-file.path(root,"state")
run("scripts/updater/experimental_w01_fast/commit_verified_state.R",
 c("--state-dir",state,"--snapshot-dir",snapshot,"--expected-parent-sha256","NONE"))
run("scripts/updater/experimental_w01_fast/verify_current_state.R",c("--state-dir",state))
snapshot_manifest<-fromJSON(file.path(snapshot,"manifest.json"))
stopifnot(identical(snapshot_manifest$batch_id,"canonical-fixture-1"))
cat("PASS: canonical scientific builder -> unchanged-record assembly -> verified checkpoint -> guarded current pointer\\n")

# Repeat identical canonical state as a second batch. Verify transition, replay,
# pointer advancement, and no byte-level canonical drift.
snapshot2<-file.path(root,"canonical-checkpoint-2")
run("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id","canonical-fixture-2",
 "--artifact",paste0("canonical=",file.path(assembled_dir,"canonical.jsonl")),
 "--output-dir",snapshot2))
link<-file.path(root,"transition.json")
run("scripts/updater/experimental_w01_fast/link_state_transition.R",
 c("--before",snapshot,"--after",snapshot2,"--output",link))
run("scripts/updater/experimental_w01_fast/verify_transition_chain.R",
 c("--snapshot",snapshot,"--snapshot",snapshot2,"--transition",link))
parent_hash<-digest::digest(file=file.path(state,"CURRENT.json"),algo="sha256")
run("scripts/updater/experimental_w01_fast/commit_verified_state.R",
 c("--state-dir",state,"--snapshot-dir",snapshot2,
 "--expected-parent-sha256",parent_hash))
run("scripts/updater/experimental_w01_fast/verify_current_state.R",c("--state-dir",state))
replay_dir<-file.path(root,"canonical-replayed")
run("scripts/updater/experimental_w01_fast/replay_verified_state.R",
 c("--snapshot",snapshot,"--snapshot",snapshot2,"--transition",link,
 "--target-batch","canonical-fixture-2","--output-dir",replay_dir))
m2<-fromJSON(file.path(snapshot2,"manifest.json"),simplifyVector=FALSE)
obj<-m2$objects$canonical$object
stopifnot(identical(digest::digest(file=file.path(snapshot2,obj),algo="sha256"),
 digest::digest(file=file.path(replay_dir,obj),algo="sha256")),
 identical(readLines(file.path(replay_dir,obj),warn=FALSE),assembled))
cat("PASS: repeat-batch canonical checkpoint transition and replay preserve exact bytes\\n")
