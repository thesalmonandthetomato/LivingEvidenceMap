#!/usr/bin/env Rscript
# Experimental atomic state pointer advancement. Never writes source snapshots.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
state_dir<-arg("--state-dir");snapshot<-arg("--snapshot-dir")
expected<-arg("--expected-parent-sha256")
if(!grepl("^(NONE|[a-f0-9]{64})$",expected))stop("Invalid expected parent hash")
if(!dir.exists(state_dir))dir.create(state_dir,recursive=TRUE)
pointer<-file.path(state_dir,"CURRENT.json")
old<-if(file.exists(pointer))digest(file=pointer,algo="sha256") else "NONE"
if(!identical(old,expected))stop("Parent pointer changed: refusing stale state advancement")
verify<-"scripts/updater/experimental_w01_fast/verify_state_snapshot.R"
z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
 c(verify,"--snapshot-dir",snapshot),stdout=TRUE,stderr=TRUE))
status<-attr(z,"status")
if(!is.null(status)&&status!=0L)stop("Refusing unverified snapshot")
m<-fromJSON(file.path(snapshot,"manifest.json"),simplifyVector=FALSE)
record<-list(schema="experimental-w01-fast-current-v1",batch_id=m$batch_id,
 manifest_sha256=digest(file=file.path(snapshot,"manifest.json"),algo="sha256"),
 snapshot_path=normalizePath(snapshot,mustWork=TRUE),
 predecessor_pointer_sha256=old,production_publication_allowed=FALSE)
# No automatic rollback to an arbitrary snapshot: explicit parent CAS required.
tmp<-tempfile("pending-",tmpdir=state_dir)
writeLines(toJSON(record,pretty=TRUE,auto_unbox=TRUE),tmp)
if(file.exists(pointer)){
 backup<-paste0(pointer,".bak")
 if(file.exists(backup))stop("Unresolved previous backup; operator recovery required")
 if(!file.rename(pointer,backup))stop("Failed to preserve prior pointer")
 if(!file.rename(tmp,pointer)){
  file.rename(backup,pointer);stop("Failed to publish new pointer")
 }
 unlink(backup)
}else if(!file.rename(tmp,pointer))stop("Failed to install initial pointer")
cat(sprintf("PASS: committed verified experimental snapshot %s\n",m$batch_id))
