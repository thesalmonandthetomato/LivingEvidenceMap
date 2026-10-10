#!/usr/bin/env Rscript
# Synthetic identity and incremental-screening regressions. Test-only; no external I/O.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root <- "/tmp/lem-isolated/regression"
dir.create(root,recursive=TRUE,showWarnings=FALSE)
writejl <- function(x,p) writeLines(vapply(x,function(z)toJSON(z,auto_unbox=TRUE,null="null"),character(1)),p)
run <- function(script,args,expect_ok=TRUE) {
  out <- suppressWarnings(system2("Rscript",c(script,args),stdout=TRUE,stderr=TRUE))
  status <- attr(out,"status")
  good <- is.null(status)||status==0L
  if(good!=expect_ok)stop("Unexpected exit from ",script,": ",paste(out,collapse=" | "))
  invisible(out)
}
# W01: numeric manifestation indexes must not silently rebind when ordering changes.
meta <- data.frame(idx=1:3,source=c("lens","scopus","lens"),source_record_id=c("a","b","c"))
meta_path<-file.path(root,"manifestations.csv")
write.csv(meta,meta_path,row.names=FALSE)
fingerprint <- function(m) digest(paste(paste(m$idx,m$source,m$source_record_id,sep="\t"),collapse="\n"),algo="sha256",serialize=FALSE)
checkpoint <- file.path(root,"checkpoint.json")
write_json(list(dedup_index_identity=list(rows=3,sha256=fingerprint(meta))),checkpoint,auto_unbox=TRUE)
script<-"scripts/updater/workflow_01_validate_index_identity.R"
run(script,c("--metadata",meta_path,"--checkpoint-manifest",checkpoint,"--output",file.path(root,"w01-ok.json")))
stopifnot(fromJSON(file.path(root,"w01-ok.json"))$status=="PASS")
swapped<-meta[c(2,1,3),]
swapped$idx<-1:3
write.csv(swapped,meta_path,row.names=FALSE)
run(script,c("--metadata",meta_path,"--checkpoint-manifest",checkpoint),expect_ok=FALSE)
write.csv(meta,meta_path,row.names=FALSE)
# W04: retain unchanged prior decisions; changed inputs and new records must requeue.
canon <- function(id,title,abstract)list(identity=list(record_id=id),canonical=list(title=title,abstract=abstract))
initial<-list(canon("a","Climate A","Original A"),canon("b","Climate B","Original B"))
update<-list(canon("a","Climate A","Updated A"),canon("b","Climate B","Original B"),canon("c","Climate C","New C"))
old_path<-file.path(root,"prior_canonical.jsonl");new_path<-file.path(root,"current_canonical.jsonl")
writejl(initial,old_path);writejl(update,new_path)
statuses<-lapply(c("a","b","c"),function(id)list(record_id=id,publication_status=list(exclude_from_workflow04=FALSE)))
w03<-file.path(root,"w03.jsonl");writejl(statuses,w03)
prior_layer<-file.path(root,"prior_screen.jsonl")
writejl(lapply(c("a","b"),function(id)list(record_id=id,screening=list(final_decision="include"))),prior_layer)
run("scripts/updater/workflow_04_prepare_incremental.R",c("--canonical",new_path,"--workflow03-status",w03,"--prior-workflow04",prior_layer,"--prior-canonical",old_path,"--output-dir",file.path(root,"w04")))
manifest<-fromJSON(file.path(root,"w04","prepare_manifest.json"))
stopifnot(manifest$status=="PASS",manifest$canonical_records==3,manifest$reusable_records==1,manifest$screen_queue_records==2,manifest$new_record_ids==1,manifest$changed_screening_input==1,manifest$changed_screening_input_reused==0)
stopifnot(identical(readLines(file.path(root,"w04","reused_record_ids.txt")),"b"))
stopifnot(setequal(readLines(file.path(root,"w04","screen_queue_record_ids.txt")),c("a","c")))
# Negative: forced rescreen of an unknown identity must fail closed.
writeLines("unknown-id",file.path(root,"unknown.txt"))
run("scripts/updater/workflow_04_prepare_incremental.R",c("--canonical",new_path,"--workflow03-status",w03,"--force-rescreen-record-ids",file.path(root,"unknown.txt"),"--output-dir",file.path(root,"w04-invalid")),expect_ok=FALSE)
write_json(list(status="PASS",w01_stable_index=TRUE,w01_swapped_index_rejected=TRUE,w04_unchanged_reused=1,w04_changed_rescreened=1,w04_new_queued=1,w04_invalid_forced_id_rejected=TRUE),file.path(root,"regression-report.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: W01 index stability and W04 incremental update regression tests\n")
