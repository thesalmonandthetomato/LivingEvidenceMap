#!/usr/bin/env Rscript
# Reconstruct exact current W01 source provenance before W08/W09 reporting.
# Never use a stale previous-run membership for the latest canonical.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop("Missing ",flag);args[[i+1L]]}
status_path<-arg("--status","docs/current_run/current_run_status.json")
out<-arg("--output-dir","docs/reporting/workflow_09_inputs/current")
s<-fromJSON(status_path,simplifyVector=FALSE)
run<-as.character(s$workflow_runs$W01 %||% "")
if(!grepl("^[0-9]+$",run))stop("No authoritative current W01 run in status")
pointer<-file.path("docs/deduplication/zenodo",paste0("run-",run,".json"))
p<-fromJSON(pointer,simplifyVector=FALSE)
if(!identical(as.character(p$github_run_id),run)||!identical(p$status,"published"))
  stop("Current W01 pointer does not match current-run status")
manifest_path<-file.path(out,"w01_source_manifest.json")
current<-FALSE
if(file.exists(manifest_path)&&file.exists(file.path(out,"w01_source_membership.csv"))){
 m<-tryCatch(fromJSON(manifest_path,simplifyVector=FALSE),error=function(e)NULL)
 current<-!is.null(m)&&identical(as.character(m$source_run_id),run)&&
   identical(tolower(as.character(m$canonical_sha256)),tolower(as.character(p$canonical_jsonl_sha256)))&&
   identical(digest(file=file.path(out,"w01_source_membership.csv"),algo="sha256",serialize=FALSE),
             as.character(m$w01_source_membership_sha256 %||% ""))
}
if(current){cat("PASS: W01 membership already current for run ",run,"\\n",sep="");quit(status=0)}
if(!nzchar(Sys.getenv("ZENODO_ACCESS_TOKEN")))stop("ZENODO_ACCESS_TOKEN required to restore current W01 provenance")
root<-file.path(tempdir(),paste0("workflow01_reporting_",run))
if(dir.exists(root))unlink(root,recursive=TRUE)
cmd<-c("scripts/updater/workflow_01_restore_current_state.R",
       "--pointer",pointer,"--pointer-dir","docs/deduplication/zenodo","--output-root",root)
if(system2("Rscript",cmd)!=0L)stop("Verified W01 restore failed")
canonical<-file.path(root,"canonical","records.jsonl")
if(!file.exists(canonical))stop("Restored W01 canonical missing")
sha<-digest(file=canonical,algo="sha256",serialize=FALSE)
if(!identical(tolower(sha),tolower(as.character(p$canonical_jsonl_sha256))))
  stop("Current W01 restored canonical SHA mismatch")
if(system2("Rscript",c("scripts/reporting/write_workflow09_source_snapshot.R",
  "--stage","W01","--run-id",run,"--canonical",canonical,
  "--output-dir",out,"--status",status_path))!=0L)
  stop("Cannot create current W01 reporting source membership")
m<-fromJSON(manifest_path,simplifyVector=FALSE)
stopifnot(identical(as.character(m$source_run_id),run),
          identical(as.integer(m$canonical_records),as.integer(p$canonical_records)))
unlink(root,recursive=TRUE)
cat("PASS: regenerated W01 source membership for current run ",run,"\\n",sep="")
