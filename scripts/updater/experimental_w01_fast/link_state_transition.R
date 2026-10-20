#!/usr/bin/env Rscript
# Immutable transition record linking two independently verified checkpoints.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
before<-arg("--before");after<-arg("--after");out<-arg("--output")
if(file.exists(out)||dir.exists(out))stop("Refusing transition overwrite")
verify<-"scripts/updater/experimental_w01_fast/verify_state_snapshot.R"
for(path in c(before,after)){
 x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(verify,"--snapshot-dir",path),stdout=TRUE,stderr=TRUE))
 status<-attr(x,"status");if(!is.null(status)&&status!=0L)
  stop(sprintf("Invalid checkpoint: %s",paste(x,collapse=" | ")))
}
bm<-fromJSON(file.path(before,"manifest.json"),simplifyVector=FALSE)
am<-fromJSON(file.path(after,"manifest.json"),simplifyVector=FALSE)
if(identical(bm$batch_id,am$batch_id))stop("Repeated batch identity")
if(!identical(sort(names(bm$objects)),sort(names(am$objects))))
 stop("Snapshot component set changed; explicit schema migration required")
bhash<-vapply(bm$objects,function(x)x$sha256,character(1))
ahash<-vapply(am$objects,function(x)x$sha256,character(1))
changed<-names(ahash)[bhash[names(ahash)]!=ahash]
transition<-list(schema="experimental-w01-fast-transition-v1",
 previous_batch_id=bm$batch_id,next_batch_id=am$batch_id,
 previous_manifest_sha256=digest(file=file.path(before,"manifest.json"),algo="sha256"),
 next_manifest_sha256=digest(file=file.path(after,"manifest.json"),algo="sha256"),
 changed_objects=unname(changed),production_publication_allowed=FALSE)
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(transition,pretty=TRUE,auto_unbox=TRUE),out)
cat(sprintf("PASS: linked %s -> %s; %d changed components\n",
 bm$batch_id,am$batch_id,length(changed)))
