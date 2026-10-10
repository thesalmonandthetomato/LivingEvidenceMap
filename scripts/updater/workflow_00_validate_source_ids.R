#!/usr/bin/env Rscript
# Check source-native identifiers in normalized W00 records before durable handoff.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
at <- function(flag,default=NULL){
 i<-match(flag,args)
 if(is.na(i))return(default)
 if(i==length(args))stop("Missing value for ",flag,call.=FALSE)
 args[[i+1L]]
}
root<-at("--root")
if(is.null(root)||!dir.exists(root))stop("Required: --root existing source-output folder",call.=FALSE)
paths<-list.files(root,pattern="records[.]jsonl$",recursive=TRUE,full.names=TRUE)
# Some providers emit raw records; their normalized identities are validated in
# the W01 adapter and source-union boundary instead.
checked<-0L
for(path in paths) {
 lines<-readLines(path,warn=FALSE,encoding="UTF-8")
 lines<-lines[nzchar(trimws(lines))]
 if(!length(lines))next
 z<-lapply(lines,fromJSON,simplifyVector=FALSE)
 get_id<-function(x) {
   if(!is.null(x$sidecar_identity$sidecar_record_id))
     return(as.character(x$sidecar_identity$sidecar_record_id))
   if(!is.null(x$identity$lens_id))
     return(as.character(x$identity$lens_id))
   if(!is.null(x$identity$record_id))
     return(as.character(x$identity$record_id))
   ""
 }
 ids<-vapply(z,get_id,character(1))
 if(!any(nzchar(ids)))next # raw, pre-normalisation W00 provider payload
 if(any(!nzchar(trimws(ids)))||anyDuplicated(ids))
   stop("Normalized W00 source records contain absent/duplicate native IDs: ",path,call.=FALSE)
 checked<-checked+1L
 cat(sprintf("PASS: %s has %d unique source-native identifiers\n",path,length(ids)))
}
cat(sprintf("W00 identity preflight checked %d normalized files; W01 validates adapted source identities again\n",checked))
