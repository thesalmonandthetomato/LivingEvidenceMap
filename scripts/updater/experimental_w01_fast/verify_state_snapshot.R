#!/usr/bin/env Rscript
# Verify an immutable W01-Fast checkpoint before any future replay.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
i<-match("--snapshot-dir",args)
if(is.na(i)||i==length(args))stop("Required: --snapshot-dir")
root<-args[[i+1L]]
manifest_path<-file.path(root,"manifest.json")
if(!file.exists(manifest_path))stop("Missing snapshot manifest")
m<-fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(m$schema,"experimental-w01-fast-state-v1")||
 !is.character(m$batch_id)||length(m$batch_id)!=1L||!nzchar(m$batch_id)||
 !identical(m$production_publication_allowed,FALSE)||
 is.null(m$objects)||!length(m$objects)||is.null(names(m$objects))||
 anyDuplicated(names(m$objects)))stop("Invalid snapshot schema or metadata")
for(name in names(m$objects)){
 obj<-m$objects[[name]]
 h<-obj$sha256
 path<-obj$object
 if(!is.character(h)||length(h)!=1L||!grepl("^[a-f0-9]{64}$",h)||
 !identical(path,paste0("objects/",h)))stop("Invalid content-addressed object")
 full<-file.path(root,path)
 if(!file.exists(full)||dir.exists(full)||
 !identical(unname(as.numeric(file.info(full)$size)),as.numeric(obj$bytes))||
 !identical(digest(file=full,algo="sha256"),h))
 stop(sprintf("Snapshot content missing or corrupted: %s",name))
}
cat(sprintf("PASS: verified %d immutable snapshot objects for batch %s\n",
 length(m$objects),m$batch_id))
