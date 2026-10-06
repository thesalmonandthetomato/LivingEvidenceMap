#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(googlesheets4);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
sheet_id<-arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential<-arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
queue_tab<-arg("--queue-tab","queue_w04_resolution_active")
decision_tab<-arg("--decision-tab","decisions_w04_resolution")
output<-arg("--output")
manifest_out<-arg("--manifest")
if(any(vapply(list(sheet_id,credential,output,manifest_out),is.null,logical(1))))stop("Required argument missing",call.=FALSE)
if(!file.exists(credential))stop("Google credential file missing",call.=FALSE)

gs4_auth(path=credential,cache=FALSE)
q<-read_sheet(sheet_id,sheet=queue_tab,col_types="c")
req<-c("batch_id","queue_sha256","case_index","review_case_id","case_json")
if(!all(req%in%names(q))||!nrow(q))stop("Active W04 resolution queue missing/malformed",call.=FALSE)
q<-q[order(as.integer(q$case_index)),,drop=FALSE]
batch_id<-as.character(unique(q$batch_id))
queue_sha<-tolower(as.character(unique(q$queue_sha256)))
if(length(batch_id)!=1L||!nzchar(batch_id))stop("Active W04 batch ID invariant failed",call.=FALSE)
if(length(queue_sha)!=1L||!grepl("^[0-9a-f]{64}$",queue_sha))stop("Active W04 queue SHA invariant failed",call.=FALSE)
reconstructed<-paste0(paste(q$case_json,collapse="\n"),"\n")
if(tolower(digest(reconstructed,algo="sha256",serialize=FALSE))!=queue_sha)stop("Active W04 queue reconstruction SHA mismatch",call.=FALSE)
cases<-lapply(q$case_json,fromJSON,simplifyVector=FALSE)
record_ids<-vapply(cases,function(z)as.character(z$record_id),character(1))
case_ids<-as.character(q$review_case_id)

d<-read_sheet(sheet_id,sheet=decision_tab,col_types="c")
needed<-c("decision_id","review_case_id","record_id","decision","rationale","reviewer","resolved_at_utc","queue_sha256")
if(!all(needed%in%names(d)))stop("W04 decision sheet missing required columns",call.=FALSE)
d<-d[tolower(as.character(d$queue_sha256))==queue_sha,,drop=FALSE]
if(nrow(d)){
  d<-d[order(as.character(d$resolved_at_utc),seq_len(nrow(d)),decreasing=TRUE),,drop=FALSE]
  d<-d[!duplicated(as.character(d$review_case_id)),,drop=FALSE]
  d<-d[as.character(d$review_case_id)%in%case_ids,,drop=FALSE]
}
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
con<-file(output,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
if(nrow(d)){
  for(i in seq_len(nrow(d))){
    if(!as.character(d$decision[[i]])%in%c("retain","exclude"))next
    z<-list(
      record_id=as.character(d$record_id[[i]]),
      review_case_id=as.character(d$review_case_id[[i]]),
      decision=as.character(d$decision[[i]]),
      rationale=as.character(d$rationale[[i]]),
      reviewer=as.character(d$reviewer[[i]]),
      adjudicated_at_utc=as.character(d$resolved_at_utc[[i]]),
      source_batch_id=batch_id,
      source_queue_sha256=queue_sha
    )
    writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
  }
}
close(con);on.exit(NULL,add=FALSE)
out_lines<-readLines(output,warn=FALSE)
out_rows<-if(length(out_lines))lapply(out_lines,fromJSON,simplifyVector=FALSE)else list()
out_ids<-if(length(out_rows))vapply(out_rows,function(z)as.character(z$record_id),character(1))else character()
if(any(!out_ids%in%record_ids))stop("Exported decision refers to record outside active queue",call.=FALSE)
writeLines(toJSON(list(
  schema="living-evidence-map-w04-partial-resolution-export-v1",status="PASS",
  batch_id=batch_id,queue_sha256=queue_sha,
  queue_records=length(record_ids),completed_records=length(out_rows),
  exported_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
),auto_unbox=TRUE,pretty=TRUE),manifest_out,useBytes=TRUE)
cat(sprintf("PASS: exported %d completed decisions from active W04 queue of %d records\n",length(out_rows),length(record_ids)))
