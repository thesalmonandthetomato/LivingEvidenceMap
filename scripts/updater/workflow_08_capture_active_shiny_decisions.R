#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(googlesheets4)
  library(jsonlite)
})

`%||%`<-function(x,y)if(is.null(x)||length(x)==0L)y else x

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i))return(default)
  if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
sheet_id<-arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential<-arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
output<-arg("--output")
if(any(vapply(c(sheet_id,credential,output),function(x)is.null(x)||!nzchar(x),logical(1))))stop("Missing required argument",call.=FALSE)
if(!file.exists(credential))stop("Credential file missing",call.=FALSE)

gs4_auth(path=credential,cache=FALSE)
tabs<-sheet_names(sheet_id)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
if(!all(c("queue_w08_active","decisions_w08")%in%tabs)){
  file.create(output)
  cat("PASS: no active W08 Shiny queue/decision tabs to capture\n")
  quit(status=0)
}

q<-read_sheet(sheet_id,sheet="queue_w08_active",col_types="c")
d<-read_sheet(sheet_id,sheet="decisions_w08",col_types="c")
if(!nrow(q)||!nrow(d)){
  file.create(output)
  cat("PASS: no active W08 Shiny decisions to capture\n")
  quit(status=0)
}

required_q<-c("batch_id","queue_sha256","record_id")
required_d<-c("record_id","queue_sha256","issue_decisions_json","resolved_at_utc")
if(!all(required_q%in%names(q))||!all(required_d%in%names(d)))stop("W08 Shiny schema mismatch",call.=FALSE)
batch<-unique(as.character(q$batch_id))
sha<-unique(tolower(as.character(q$queue_sha256)))
if(length(batch)!=1L||length(sha)!=1L)stop("Active W08 queue metadata is not singular",call.=FALSE)

d<-d[tolower(as.character(d$queue_sha256))==sha[[1L]],,drop=FALSE]
if(!nrow(d)){
  file.create(output)
  cat("PASS: no completed decisions exist for active W08 queue\n")
  quit(status=0)
}

d<-d[order(as.character(d$resolved_at_utc),seq_len(nrow(d)),decreasing=TRUE),,drop=FALSE]
d<-d[!duplicated(as.character(d$record_id)),,drop=FALSE]

rows<-list()
for(i in seq_len(nrow(d))){
  got<-fromJSON(as.character(d$issue_decisions_json[[i]]),simplifyVector=FALSE)
  if(!is.list(got))stop("Malformed issue_decisions_json",call.=FALSE)
  for(z in got){
    key<-as.character(z$review_key %||% "")
    h<-as.character(z$issue_state_sha256 %||% "")
    if(!nzchar(key)||!nzchar(h))stop("Captured W08 decision lacks review_key or issue_state_sha256",call.=FALSE)
    z$captured_from_active_shiny_batch<-batch[[1L]]
    z$captured_from_queue_sha256<-sha[[1L]]
    rows[[length(rows)+1L]]<-z
  }
}
keys<-vapply(rows,function(z)as.character(z$review_key),character(1))
if(anyDuplicated(keys))stop("Captured active W08 decisions contain duplicate review_key",call.=FALSE)

con<-file(output,"wt",encoding="UTF-8")
for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con)
cat(sprintf("PASS: captured %d completed W08 issue decisions from active Shiny batch %s\n",length(rows),batch[[1L]]))
