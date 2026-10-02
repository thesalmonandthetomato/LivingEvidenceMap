#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
recovery_path<-arg("--recovery-pass1")
canonical_path<-arg("--canonical")
config_path<-arg("--screening-config","user_input/workflow04_screening_config.json")
output_path<-arg("--output")
shard_index<-as.integer(arg("--shard-index","1"))
shard_count<-as.integer(arg("--shard-count","1"))
if(any(vapply(list(recovery_path,canonical_path,output_path),is.null,logical(1))))stop("Required: --recovery-pass1 --canonical --output",call.=FALSE)
if(!file.exists(recovery_path)||!file.exists(canonical_path)||!file.exists(config_path))stop("Recovery/canonical/config input missing",call.=FALSE)
if(is.na(shard_index)||is.na(shard_count)||shard_count<1L||shard_index<1L||shard_index>shard_count)stop("Invalid shard index/count",call.=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))}
rid<-function(r)scalar((r$identity%||%list())$record_id)

cfg<-fromJSON(config_path,simplifyVector=FALSE)
prompt_path<-scalar(cfg$prompt_path);expected_sha<-scalar(cfg$expected_prompt_sha256)
prompt<-paste(readLines(prompt_path,warn=FALSE,encoding="UTF-8"),collapse="\n")
actual_sha<-digest(prompt,algo="sha256",serialize=FALSE)
if(!identical(actual_sha,expected_sha))stop("Current W04 prompt does not match immutable config",call.=FALSE)

can<-read_jsonl(canonical_path)
ids<-vapply(can,rid,character(1))
if(any(!nzchar(ids))||anyDuplicated(ids))stop("Current W04 queue record_id invariant failed",call.=FALSE)
ids<-sort(ids)
membership<-((seq_along(ids)-1L)%%shard_count)+1L
shard_ids<-ids[membership==shard_index]

rec<-read_jsonl(recovery_path)
rec_ids<-vapply(rec,function(x)scalar(x$record_id),character(1))
if(any(!nzchar(rec_ids))||anyDuplicated(rec_ids))stop("Recovered pass-1 record_id invariant failed",call.=FALSE)
if(any(vapply(rec,function(x)as.integer(x$pass%||%NA_integer_)!=1L,logical(1))))stop("Recovery file contains non-pass-1 rows",call.=FALSE)
rec_prompt<-unique(vapply(rec,function(x)scalar(x$prompt_sha256),character(1)))
if(length(rec_prompt)!=1L||!identical(rec_prompt[[1L]],actual_sha))stop("Recovered pass-1 prompt SHA does not match current W04 prompt",call.=FALSE)

keep<-rec_ids%in%shard_ids
seed<-rec[keep]
seed_ids<-rec_ids[keep]
unknown<-setdiff(rec_ids,ids)
# Recovery may contain rows that are intentionally absent from this queue
# (e.g. prior-decision rescreens removed by the corrected reuse rule). They are
# ignored, not treated as errors. Only rows present in this queue can be seeded.

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
con<-file(output_path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
if(length(seed))for(x in seed)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con);on.exit(NULL,add=FALSE)
cat(sprintf("PASS: seeded shard %d/%d with %d recovered pass-1 decisions; %d recovery rows are outside the corrected queue\n",shard_index,shard_count,length(seed),length(unknown)))
