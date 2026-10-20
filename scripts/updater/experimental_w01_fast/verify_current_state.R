#!/usr/bin/env Rscript
# Fail-closed read of experimental CURRENT pointer and referenced checkpoint.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE);i<-match("--state-dir",a)
if(is.na(i)||i==length(a))stop("Required: --state-dir")
p<-file.path(a[[i+1L]],"CURRENT.json")
if(!file.exists(p))stop("Missing committed state pointer")
v<-fromJSON(p,simplifyVector=FALSE)
if(!identical(v$schema,"experimental-w01-fast-current-v1")||
 !identical(v$production_publication_allowed,FALSE)||
 !is.character(v$snapshot_path)||length(v$snapshot_path)!=1L||
 !is.character(v$manifest_sha256)||length(v$manifest_sha256)!=1L||
 !grepl("^[0-9a-f]{64}$",v$manifest_sha256)||
 !is.character(v$batch_id)||length(v$batch_id)!=1L||
 !nzchar(v$batch_id))stop("Invalid current state pointer")
manifest<-file.path(v$snapshot_path,"manifest.json")
if(!file.exists(manifest)||!identical(digest(file=manifest,algo="sha256"),v$manifest_sha256))
 stop("Current pointer manifest mismatch")
m<-fromJSON(manifest,simplifyVector=FALSE)
if(!identical(v$batch_id,m$batch_id))stop("Current pointer batch mismatch")
check<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/verify_state_snapshot.R",
 "--snapshot-dir",v$snapshot_path),stdout=TRUE,stderr=TRUE))
status<-attr(check,"status");if(!is.null(status)&&status!=0L)
 stop("Current state references an invalid or corrupted snapshot")
cat(sprintf("PASS: current state %s matches verified snapshot and SHA-256 manifest\n",v$batch_id))
