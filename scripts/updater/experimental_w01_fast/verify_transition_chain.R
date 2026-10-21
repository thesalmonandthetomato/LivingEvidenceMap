#!/usr/bin/env Rscript
# Read-only verification of an ordered chain of immutable W01-Fast checkpoints.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
positions<-which(a=="--snapshot")
links<-which(a=="--transition")
if(length(positions)<2L||length(links)!=length(positions)-1L||
 any(c(positions,links)==length(a)))stop("Supply ordered --snapshot paths and adjacent --transition files")
snapshots<-a[positions+1L];transitions<-a[links+1L]
if(anyDuplicated(snapshots)||anyDuplicated(transitions))stop("Repeated chain inputs")
verify<-"scripts/updater/experimental_w01_fast/verify_state_snapshot.R"
ms<-lapply(snapshots,function(path){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(verify,"--snapshot-dir",path),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(!is.null(status)&&status!=0L)stop("Invalid chain snapshot")
 fromJSON(file.path(path,"manifest.json"),simplifyVector=FALSE)
})
ids<-vapply(ms,function(m)m$batch_id,character(1))
if(anyDuplicated(ids))stop("Repeated batch ID")
for(i in seq_along(transitions)){
 t<-fromJSON(transitions[[i]],simplifyVector=FALSE)
 a<-ms[[i]];b<-ms[[i+1L]]
 h1<-digest(file=file.path(snapshots[[i]],"manifest.json"),algo="sha256")
 h2<-digest(file=file.path(snapshots[[i+1L]],"manifest.json"),algo="sha256")
 if(!identical(t$schema,"experimental-w01-fast-transition-v1")||
 !identical(t$previous_batch_id,a$batch_id)||
 !identical(t$next_batch_id,b$batch_id)||
 !identical(t$previous_manifest_sha256,h1)||
 !identical(t$next_manifest_sha256,h2)||
 !identical(t$production_publication_allowed,FALSE))stop("Broken chain link")
 before<-vapply(a$objects,function(x)x$sha256,character(1))
 after<-vapply(b$objects,function(x)x$sha256,character(1))
 if(!identical(sort(names(before)),sort(names(after))))stop("Unexpected state schema migration")
 expected<-sort(names(after)[before[names(after)]!=after])
 recorded<-sort(as.character(unlist(t$changed_objects,use.names=FALSE)))
 if(!identical(expected,recorded))stop("Incorrect changed-object delta in transition")
}
cat(sprintf("PASS: validated %d snapshots and %d transition links\n",
 length(snapshots),length(transitions)))
