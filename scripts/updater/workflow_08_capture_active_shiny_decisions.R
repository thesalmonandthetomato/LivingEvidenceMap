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
history_output<-arg("--history-output","")
if(any(vapply(c(sheet_id,credential,output),function(x)is.null(x)||!nzchar(x),logical(1))))stop("Missing required argument",call.=FALSE)
if(!file.exists(credential))stop("Credential file missing",call.=FALSE)

gs4_auth(path=credential,cache=FALSE)
tabs<-sheet_names(sheet_id)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
if(nzchar(history_output))dir.create(dirname(history_output),recursive=TRUE,showWarnings=FALSE)
if(!all(c("queue_w08_active","decisions_w08")%in%tabs)){
  file.create(output)
  cat("PASS: no active W08 Shiny queue/decision tabs to capture\n")
  quit(status=0)
}

q<-read_sheet(sheet_id,sheet="queue_w08_active",col_types="c")
d<-read_sheet(sheet_id,sheet="decisions_w08",col_types="c")
if(!nrow(q)||!nrow(d)){
  file.create(output)
  if(nzchar(history_output))file.create(history_output)
  cat("PASS: no active W08 Shiny decisions to capture\n")
  quit(status=0)
}

required_q<-c("batch_id","queue_sha256","record_id")
required_d<-c("record_id","queue_sha256","issue_decisions_json","resolved_at_utc")
if(!all(required_q%in%names(q))||!all(required_d%in%names(d)))stop("W08 Shiny schema mismatch",call.=FALSE)
batch<-unique(as.character(q$batch_id))
sha<-unique(tolower(as.character(q$queue_sha256)))
if(length(batch)!=1L||length(sha)!=1L)stop("Active W08 queue metadata is not singular",call.=FALSE)

# Build a cumulative history of all persisted W08 decisions. Each decision
# remains reusable only when its review_key and issue_state_sha256 match a
# future current issue, so retaining history is safe while preventing a
# previously reused decision from disappearing on another regeneration.
all_d<-d[order(as.character(d$resolved_at_utc),seq_len(nrow(d)),decreasing=TRUE),,drop=FALSE]
history_rows<-list()
seen_keys<-character()
for(i in seq_len(nrow(all_d))){
  got<-fromJSON(as.character(all_d$issue_decisions_json[[i]]),simplifyVector=FALSE)
  if(!is.list(got))stop("Malformed issue_decisions_json",call.=FALSE)
  for(z in got){
    key<-as.character(z$review_key %||% "")
    h<-as.character(z$issue_state_sha256 %||% "")
    if(!nzchar(key)||!nzchar(h))stop("Captured W08 decision lacks review_key or issue_state_sha256",call.=FALSE)
    if(key%in%seen_keys)next
    seen_keys<-c(seen_keys,key)
    z$captured_from_queue_sha256<-as.character(all_d$queue_sha256[[i]])
    z$captured_resolved_at_utc<-as.character(all_d$resolved_at_utc[[i]])
    history_rows[[length(history_rows)+1L]]<-z
  }
}
if(nzchar(history_output)){
  con<-file(history_output,"wt",encoding="UTF-8")
  for(z in history_rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
  close(con)
}

active_d<-d[tolower(as.character(d$queue_sha256))==sha[[1L]],,drop=FALSE]
if(!nrow(active_d)){
  file.create(output)
  cat(sprintf("PASS: no completed decisions exist for active W08 queue; cumulative history=%d issues\n",length(history_rows)))
  quit(status=0)
}

active_d<-active_d[order(as.character(active_d$resolved_at_utc),seq_len(nrow(active_d)),decreasing=TRUE),,drop=FALSE]
active_d<-active_d[!duplicated(as.character(active_d$record_id)),,drop=FALSE]

rows<-list()
for(i in seq_len(nrow(active_d))){
  got<-fromJSON(as.character(active_d$issue_decisions_json[[i]]),simplifyVector=FALSE)
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
cat(sprintf("PASS: captured %d completed W08 issue decisions from active Shiny batch %s; cumulative history=%d issues\n",length(rows),batch[[1L]],length(history_rows)))
