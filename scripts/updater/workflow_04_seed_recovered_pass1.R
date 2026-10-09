#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical");recovery_path<-arg("--recovered-pass1");out_root<-arg("--output-root");shard_count<-as.integer(arg("--shard-count","8"))
if(any(vapply(list(canonical_path,recovery_path,out_root),is.null,logical(1))))stop("Required: --canonical --recovered-pass1 --output-root",call.=FALSE)
`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))}
q<-read_jsonl(canonical_path);qids<-sort(vapply(q,function(r)scalar((r$identity%||%list())$record_id),character(1)))
if(any(!nzchar(qids))||anyDuplicated(qids))stop("Queue identity invariant failed",call.=FALSE)
rec<-read_jsonl(recovery_path);rids<-vapply(rec,function(r)scalar(r$record_id),character(1))
if(any(!nzchar(rids))||anyDuplicated(rids))stop("Recovery identity invariant failed",call.=FALSE)
not_queue<-setdiff(rids,qids)
if(length(not_queue))stop(sprintf("Recovery contains %d IDs absent from current W04 queue",length(not_queue)),call.=FALSE)
shard<-setNames(((seq_along(qids)-1L)%%shard_count)+1L,qids)
dir.create(out_root,recursive=TRUE,showWarnings=FALSE)
counts<-integer(shard_count)
for(s in seq_len(shard_count)){
  rows<-rec[shard[rids]==s];counts[[s]]<-length(rows)
  d<-file.path(out_root,paste0("shard-",s));dir.create(d,recursive=TRUE,showWarnings=FALSE)
  con<-file(file.path(d,"pass1.jsonl"),"wt",encoding="UTF-8")
  if(length(rows))for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
  close(con)
}
writeLines(toJSON(list(schema="living-evidence-map-workflow04-pass1-seed-v1",status="PASS",
  queue_records=length(qids),recovered_pass1_records=length(rec),shard_count=shard_count,
  recovered_by_shard=as.list(counts)),auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out_root,"seed_report.json"),useBytes=TRUE)
cat(sprintf("PASS: seeded %d recovered pass-1 decisions across %d shards: %s\n",length(rec),shard_count,paste(counts,collapse=",")))
