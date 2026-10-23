#!/usr/bin/env Rscript
# Non-publishing Fast W01 return adapter. Never touches Shiny, GitHub, Zenodo or W02.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k);args[[i+1L]]}
fast<-arg("--fast-root");meta<-arg("--metadata")
prior<-arg("--previous-map");old<-arg("--previous-decisions")
handoff<-arg("--handoff");export<-arg("--export-manifest")
decisions<-arg("--decisions");repairs<-arg("--repairs");out<-arg("--output-dir")
queue<-file.path(fast,"adjudication","human_review_package","human_review_cases.jsonl")
qm_path<-file.path(fast,"adjudication","human_review_package","review_manifest.json")
report<-file.path(fast,"run_report.json")
required<-c(queue,qm_path,report,meta,prior,old,handoff,export,decisions,repairs)
if(any(!file.exists(required))||dir.exists(out)||file.exists(out))
 stop("Missing immutable checkpoint/export evidence or destination exists")
qm<-fromJSON(qm_path,simplifyVector=FALSE)
rp<-fromJSON(report,simplifyVector=FALSE)
h<-fromJSON(handoff,simplifyVector=FALSE)
if(!identical(rp$status,"AWAITING_HUMAN_REVIEW")||
 !identical(qm$queue_sha256,digest(file=queue,algo="sha256",serialize=FALSE))||
 !identical(as.character(qm$queue_sha256),as.character(h$queue_sha256))||
 !identical(as.integer(qm$pending_count),as.integer(h$queue_cases))||
 !identical(h$status,"ready"))stop("Shiny export not tied to original frozen Fast checkpoint")
dir.create(out,recursive=TRUE)
on.exit(if(dir.exists(out)&&!file.exists(file.path(out,"COMPLETE.json")))
 unlink(out,recursive=TRUE,force=TRUE),add=TRUE)
verified<-file.path(out,"verified_shiny.json")
run<-function(script,argv){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),c(script,argv),
 stdout=TRUE,stderr=TRUE))
 code<-if(is.null(attr(z,"status")))0L else as.integer(attr(z,"status"))
 if(code!=0L)stop("Fail-closed: ",basename(script),": ",paste(z,collapse=" | "))
 invisible(z)
}
base<-"scripts/updater/experimental_w01_fast"
run(file.path(base,"verify_shiny_return.R"),c(
 "--handoff",handoff,"--export-manifest",export,
 "--decisions",decisions,"--repairs",repairs,"--queue",queue,"--output",verified))
reviewed<-file.path(out,"reviewed")
run(file.path(base,"resume_review_decisions.R"),c(
 "--fast-root",fast,"--metadata",meta,"--previous-map",prior,
 "--previous-decisions",old,"--queue",queue,
 "--decisions",decisions,"--repairs",repairs,
 "--verified-shiny-return",verified,"--output-dir",reviewed))
rm<-fromJSON(file.path(reviewed,"resume_manifest.json"),simplifyVector=FALSE)
if(!identical(rm$status,"VALIDATED_RESUME_READY")||
 !identical(rm$publication_allowed,FALSE))stop("Fast review resume not validated")
write_json(list(schema="w01-fast-shiny-return-ingestion-v1",
 status="VERIFIED_READY_FOR_NONPUBLISHING_CANONICAL",
 queue_sha256=qm$queue_sha256,
 reviewed_manifest_sha256=digest(file=file.path(reviewed,"resume_manifest.json"),algo="sha256"),
 publication_allowed=FALSE,workflow02_dispatch_allowed=FALSE),
 file.path(out,"COMPLETE.json"),pretty=TRUE,auto_unbox=TRUE)
cat("PASS: verified real W01 Shiny export and staged Fast resume, no external writes\n")
