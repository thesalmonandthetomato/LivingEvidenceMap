#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("restore-test-");dir.create(root)
artifact<-file.path(root,"sample.csv");writeLines("saved",artifact)
snapshot<-file.path(root,"snapshot")
runner<-file.path(R.home("bin"),"Rscript")
call<-function(file,args,ok=TRUE){
 z<-suppressWarnings(system2(runner,c(file,args),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste("Unexpected status",code,paste(z,collapse=" | ")))
}
prefix<-"scripts/updater/experimental_w01_fast/"
call(paste0(prefix,"create_state_snapshot.R"),
 c("--batch-id","fixed-one","--artifact",paste0("clusters=",artifact),"--output-dir",snapshot))
state<-file.path(root,"state")
call(paste0(prefix,"commit_verified_state.R"),
 c("--state-dir",state,"--snapshot-dir",snapshot,"--expected-parent-sha256","NONE"))
current<-file.path(state,"CURRENT.json");backup<-paste0(current,".bak")
hash<-digest(file=current,algo="sha256")
stopifnot(file.rename(current,backup))
recovery<-paste0(prefix,"restore_interrupted_pointer.R")
args<-c("--state-dir",state,"--expected-backup-sha256",hash)
call(recovery,c("--state-dir",state,"--expected-backup-sha256",paste(rep("0",64),collapse="")),FALSE)
stopifnot(!file.exists(current),file.exists(backup))
call(recovery,args)
stopifnot(file.exists(current),!file.exists(backup),identical(hash,digest(file=current,algo="sha256")))
call(recovery,args,FALSE)
call(paste0(prefix,"verify_current_state.R"),c("--state-dir",state))
# Reject a backup pointing to a corrupted snapshot without touching it.
stopifnot(file.rename(current,backup))
m<-fromJSON(file.path(snapshot,"manifest.json"))
obj<-file.path(snapshot,m$objects$clusters$object)
writeLines("corrupted",obj)
call(recovery,args,FALSE)
stopifnot(!file.exists(current),identical(hash,digest(file=backup,algo="sha256")))
cat("PASS: explicit interrupted-pointer recovery, stale hash rejection and corrupt backup rejection\n")
