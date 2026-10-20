#!/usr/bin/env Rscript
# Read-only diagnosis of an interrupted CURRENT pointer transition.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE);i<-match("--state-dir",a)
if(is.na(i)||i==length(a))stop("Required: --state-dir")
root<-a[[i+1L]]
read_pointer<-function(path){
 if(!file.exists(path))return(list(present=FALSE,valid=FALSE,reason="missing"))
 tryCatch({
  v<-fromJSON(path,simplifyVector=FALSE)
  if(!identical(v$schema,"experimental-w01-fast-current-v1")||
     !identical(v$production_publication_allowed,FALSE)||
     !is.character(v$batch_id)||length(v$batch_id)!=1L||
     !is.character(v$snapshot_path)||length(v$snapshot_path)!=1L||
     !is.character(v$manifest_sha256)||length(v$manifest_sha256)!=1L)
    stop("invalid pointer fields")
  manifest<-file.path(v$snapshot_path,"manifest.json")
  if(!file.exists(manifest)||!identical(digest(file=manifest,algo="sha256"),v$manifest_sha256))
    stop("manifest hash mismatch")
  m<-fromJSON(manifest,simplifyVector=FALSE)
  if(!identical(m$batch_id,v$batch_id))stop("batch identity mismatch")
  verifier<-"scripts/updater/experimental_w01_fast/verify_state_snapshot.R"
  z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
       c(verifier,"--snapshot-dir",v$snapshot_path),stdout=TRUE,stderr=TRUE))
  status<-attr(z,"status")
  if(!is.null(status)&&status!=0L)stop("corrupt referenced snapshot")
  list(present=TRUE,valid=TRUE,batch_id=v$batch_id,
       pointer_sha256=digest(file=path,algo="sha256"))
 },error=function(e)list(present=TRUE,valid=FALSE,reason=conditionMessage(e)))
}
current<-read_pointer(file.path(root,"CURRENT.json"))
backup<-read_pointer(file.path(root,"CURRENT.json.bak"))
assessment<-if(current$valid && !backup$present)"clean_current" else
 if(!current$present && backup$valid)"recoverable_backup_requires_manual_action" else
 if(current$valid && backup$valid)"ambiguous_both_valid_requires_manual_action" else
 "invalid_or_incomplete_requires_manual_action"
result<-list(schema="experimental-w01-fast-recovery-inspection-v1",
 current=current,backup=backup,assessment=assessment,
 automatic_recovery_permitted=FALSE)
cat(toJSON(result,auto_unbox=TRUE,pretty=TRUE), "\n")
if(assessment!="clean_current")quit(status=2L)
