#!/usr/bin/env Rscript
# Materialise a verified checkpoint from an ordered, checked transition chain.
# Read-only towards source checkpoints; no production publishing.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
get_many<-function(flag){p<-which(a==flag);if(any(p==length(a)))stop("Missing value");a[p+1L]}
snapshots<-get_many("--snapshot");links<-get_many("--transition")
target<-get_many("--target-batch");output<-get_many("--output-dir")
if(length(target)!=1L||length(output)!=1L||length(snapshots)<2L||
 length(links)!=length(snapshots)-1L)stop("Invalid replay arguments")
if(file.exists(output)||dir.exists(output))stop("Refusing to overwrite replay output")
verifier<-"scripts/updater/experimental_w01_fast/verify_transition_chain.R"
args<-c(as.vector(rbind(rep("--snapshot",length(snapshots)),snapshots)),
 as.vector(rbind(rep("--transition",length(links)),links)))
log<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(verifier,args),stdout=TRUE,stderr=TRUE))
code<-attr(log,"status");if(!is.null(code)&&code!=0L)
 stop(paste("Chain verification failed:",paste(log,collapse=" | ")))
manifests<-lapply(snapshots,function(p)fromJSON(file.path(p,"manifest.json"),simplifyVector=FALSE))
batches<-vapply(manifests,function(m)m$batch_id,character(1))
idx<-match(target,batches)
if(is.na(idx))stop("Requested batch not in verified chain")
snapshot<-snapshots[[idx]];m<-manifests[[idx]]
dir.create(output,recursive=TRUE)
dir.create(file.path(output,"objects"))
for(obj in m$objects){
 src<-file.path(snapshot,obj$object);dest<-file.path(output,obj$object)
 if(!file.copy(src,dest,overwrite=FALSE))stop("Replay object copy failed")
 if(!identical(digest(file=dest,algo="sha256"),obj$sha256))stop("Replay object hash mismatch")
}
if(!file.copy(file.path(snapshot,"manifest.json"),file.path(output,"manifest.json"),
 overwrite=FALSE))stop("Replay manifest copy failed")
cat(sprintf("PASS: replayed verified batch %s from %d-checkpoint chain\n",target,length(snapshots)))
