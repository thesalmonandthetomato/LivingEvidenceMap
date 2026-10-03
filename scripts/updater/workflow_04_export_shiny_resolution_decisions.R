#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(googlesheets4);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
batch_id<-arg("--batch-id");queue_sha<-tolower(arg("--queue-sha256",""));source_run_id<-arg("--source-run-id")
sheet_id<-arg("--sheet-id");credential<-arg("--credential");output<-arg("--output");manifest_out<-arg("--manifest")
queue_tab<-arg("--queue-tab","queue_w04_resolution_active");decision_tab<-arg("--decision-tab","decisions_w04_resolution")
if(any(vapply(list(batch_id,queue_sha,source_run_id,sheet_id,credential,output,manifest_out),is.null,logical(1))))stop("Required W04 resolution export argument missing",call.=FALSE)
if(!grepl("^[0-9a-f]{64}$",queue_sha))stop("Invalid queue SHA",call.=FALSE)
gs4_auth(path=credential,cache=FALSE)
q<-read_sheet(sheet_id,sheet=queue_tab,col_types="c")
req<-c("batch_id","queue_sha256","case_index","review_case_id","case_json")
if(!all(req%in%names(q))||!nrow(q))stop("W04 resolution queue missing/malformed",call.=FALSE)
q<-q[order(as.integer(q$case_index)),,drop=FALSE]
if(length(unique(q$batch_id))!=1L||as.character(unique(q$batch_id)[[1L]])!=batch_id)stop("W04 resolution batch ID mismatch",call.=FALSE)
if(length(unique(q$queue_sha256))!=1L||tolower(as.character(unique(q$queue_sha256)[[1L]]))!=queue_sha)stop("W04 resolution queue SHA metadata mismatch",call.=FALSE)
if("review_mode"%in%names(q)&&nzchar(as.character(q$review_mode[[1L]]))&&!identical(as.character(q$review_mode[[1L]]),"resolution"))stop("W04 queue is not a resolution batch",call.=FALSE)
if("source_run_id"%in%names(q)&&nzchar(as.character(q$source_run_id[[1L]]))&&!identical(as.character(q$source_run_id[[1L]]),as.character(source_run_id)))stop("W04 resolution source run mismatch",call.=FALSE)
reconstructed<-paste0(paste(q$case_json,collapse="\n"),"\n")
if(tolower(digest(reconstructed,algo="sha256",serialize=FALSE))!=queue_sha)stop("W04 resolution queue reconstruction SHA mismatch",call.=FALSE)
cases<-lapply(q$case_json,fromJSON,simplifyVector=FALSE)
record_ids<-vapply(cases,function(z)as.character(z$record_id),character(1))

d<-read_sheet(sheet_id,sheet=decision_tab,col_types="c")
needed<-c("decision_id","review_case_id","record_id","decision","rationale","reviewer","resolved_at_utc","queue_sha256")
if(!all(needed%in%names(d)))stop("W04 decision sheet missing required columns",call.=FALSE)
d<-d[tolower(as.character(d$queue_sha256))==queue_sha,,drop=FALSE]
if(!nrow(d))stop("No W04 resolution decisions found",call.=FALSE)
d<-d[order(as.character(d$resolved_at_utc),seq_len(nrow(d)),decreasing=TRUE),,drop=FALSE]
active<-d[!duplicated(as.character(d$review_case_id)),,drop=FALSE]
active<-active[match(as.character(q$review_case_id),as.character(active$review_case_id)),,drop=FALSE]
if(any(is.na(active$review_case_id)))stop("W04 resolution batch is incomplete",call.=FALSE)
if(any(!as.character(active$decision)%in%c("retain","exclude")))stop("W04 resolution decisions must be retain/exclude only",call.=FALSE)
if(!identical(as.character(active$record_id),record_ids))stop("W04 resolution decision record IDs do not match queue",call.=FALSE)

dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
con<-file(output,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
for(i in seq_len(nrow(active))){
  z<-list(record_id=as.character(active$record_id[[i]]),decision=as.character(active$decision[[i]]),
          rationale=as.character(active$rationale[[i]]),reviewer=as.character(active$reviewer[[i]]),
          adjudicated_at_utc=as.character(active$resolved_at_utc[[i]]))
  writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}
close(con);on.exit(NULL,add=FALSE)
out_sha<-digest(file=output,algo="sha256",serialize=FALSE)
writeLines(toJSON(list(schema="living-evidence-map-workflow04-resolution-export-v1",status="PASS",
  source_run_id=as.character(source_run_id),batch_id=batch_id,queue_sha256=queue_sha,records=nrow(active),
  decision_file_sha256=out_sha,exported_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")),
  auto_unbox=TRUE,pretty=TRUE),manifest_out,useBytes=TRUE)
cat(sprintf("PASS: exported %d completed W04 resolution decisions\n",nrow(active)))
