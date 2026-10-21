#!/usr/bin/env Rscript
# Explicit, auditable recovery for an interrupted experimental CURRENT update.
# Never touches production; requires exact expected backup hash from operator.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
root<-arg("--state-dir")
expected<-arg("--expected-backup-sha256")
if(!grepl("^[0-9a-f]{64}$",expected))stop("Invalid expected backup SHA-256")
current<-file.path(root,"CURRENT.json");backup<-paste0(current,".bak")
if(file.exists(current)||!file.exists(backup))stop("Recoverable missing-current/valid-backup state required")
observed<-digest(file=backup,algo="sha256")
if(!identical(observed,expected))stop("Backup hash mismatch")
v<-fromJSON(backup,simplifyVector=FALSE)
if(!identical(v$schema,"experimental-w01-fast-current-v1")||
 !identical(v$production_publication_allowed,FALSE)||
 !is.character(v$snapshot_path)||length(v$snapshot_path)!=1L||
 !is.character(v$manifest_sha256)||length(v$manifest_sha256)!=1L)
 stop("Invalid backup pointer")
manifest<-file.path(v$snapshot_path,"manifest.json")
if(!file.exists(manifest)||!identical(digest(file=manifest,algo="sha256"),v$manifest_sha256))
 stop("Invalid backup manifest hash")
z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c("scripts/updater/experimental_w01_fast/verify_state_snapshot.R","--snapshot-dir",v$snapshot_path),
 stdout=TRUE,stderr=TRUE))
status<-attr(z,"status")
if(!is.null(status)&&status!=0L)stop("Backup points to corrupt snapshot")
if(!file.rename(backup,current))stop("Failed to restore verified backup pointer")
if(!identical(digest(file=current,algo="sha256"),expected))
 stop("Recovered pointer checksum mismatch")
cat(sprintf("PASS: recovered explicitly approved experimental pointer %s\n",v$batch_id))
