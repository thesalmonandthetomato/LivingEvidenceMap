#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

zero_path<-arg("--zero-records")
reused_path<-arg("--reused")
fresh_path<-arg("--fresh","")
output_dir<-arg("--output-dir","outputs/workflow07_zero_complete")
if(any(vapply(c(zero_path,reused_path),function(p)is.null(p)||!file.exists(p),logical(1))))stop("Required W07 zero merge input missing",call.=FALSE)
if(nzchar(fresh_path)&&!file.exists(fresh_path))stop("Fresh zero-topic rescreen file missing",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

read_jsonl<-function(path){
  if(!nzchar(path)||!file.exists(path))return(list())
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))
}
write_jsonl<-function(rows,path){
  con<-file(path,"wt",encoding="UTF-8");on.exit(close(con),add=TRUE)
  if(length(rows))for(z in rows)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}

zero<-read_csv(zero_path,show_col_types=FALSE,progress=FALSE)
if(!"record_id"%in%names(zero)||anyDuplicated(zero$record_id))stop("Invalid current zero-topic record set",call.=FALSE)
reuse<-read_jsonl(reused_path)
fresh<-read_jsonl(fresh_path)
reuse_ids<-if(length(reuse))vapply(reuse,function(z)scalar(z$record_id),character(1))else character()
fresh_ids<-if(length(fresh))vapply(fresh,function(z)scalar(z$record_id),character(1))else character()
if(any(!nzchar(c(reuse_ids,fresh_ids))))stop("Zero-topic rescreen row missing record_id",call.=FALSE)
if(anyDuplicated(reuse_ids)||anyDuplicated(fresh_ids)||length(intersect(reuse_ids,fresh_ids)))stop("Duplicate/overlapping reused and fresh zero-topic decisions",call.=FALSE)
if(!setequal(c(reuse_ids,fresh_ids),as.character(zero$record_id)))stop("Complete zero-topic rescreen coverage does not match current zero-topic records",call.=FALSE)

rows<-c(reuse,fresh)
ids<-c(reuse_ids,fresh_ids)
if(length(rows)){
  dec<-vapply(rows,function(z)tolower(scalar(z$decision)),character(1))
  if(any(!dec%in%c("include","exclude","uncertain")))stop("Invalid zero-topic rescreen decision",call.=FALSE)
  ord<-match(as.character(zero$record_id),ids)
  rows<-rows[ord]
}
write_jsonl(rows,file.path(output_dir,"workflow07_zero_topic_targeted_rescreen.jsonl"))
write_jsonl(Filter(function(z)tolower(scalar(z$decision))=="uncertain",rows),file.path(output_dir,"workflow07_zero_topic_human_review_candidates.jsonl"))
write_jsonl(Filter(function(z)tolower(scalar(z$decision))=="exclude",rows),file.path(output_dir,"workflow07_zero_topic_late_automatic_exclusions.jsonl"))
write_jsonl(Filter(function(z)tolower(scalar(z$decision))=="include",rows),file.path(output_dir,"workflow07_zero_topic_included_uncoded.jsonl"))

summary<-list(
  schema="living-evidence-map-workflow07-zero-rescreen-complete-v1",
  status="PASS",zero_topic_records=nrow(zero),
  reused_decisions=length(reuse),fresh_decisions=length(fresh),
  include=sum(vapply(rows,function(z)tolower(scalar(z$decision))=="include",logical(1))),
  exclude=sum(vapply(rows,function(z)tolower(scalar(z$decision))=="exclude",logical(1))),
  uncertain=sum(vapply(rows,function(z)tolower(scalar(z$decision))=="uncertain",logical(1))),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(output_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: complete W07 zero-topic decisions=%d reuse=%d fresh=%d\n",summary$zero_topic_records,summary$reused_decisions,summary$fresh_decisions))
