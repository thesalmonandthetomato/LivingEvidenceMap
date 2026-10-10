#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}

zero_path<-arg("--zero-records")
current_records_path<-arg("--current-records")
prior_records_path<-arg("--prior-records","")
prior_zero_path<-arg("--prior-zero-rescreen","")
output_dir<-arg("--output-dir","outputs/workflow07_zero_prepare")
if(any(vapply(c(zero_path,current_records_path),function(p)is.null(p)||!file.exists(p),logical(1))))stop("Required zero/current W07 inputs missing",call.=FALSE)
for(p in c(prior_records_path,prior_zero_path))if(nzchar(p)&&!file.exists(p))stop(sprintf("Prior zero-rescreen input missing: %s",p),call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

zero<-read_csv(zero_path,show_col_types=FALSE,progress=FALSE)
current<-read_csv(current_records_path,show_col_types=FALSE,progress=FALSE)
if(!"record_id"%in%names(zero)||anyDuplicated(zero$record_id))stop("Invalid W07 zero-topic record set",call.=FALSE)
if(!all(c("record_id","title","abstract","topic_input_sha256")%in%names(current)))stop("Current W07 records lack required text/fingerprint fields",call.=FALSE)
if(anyDuplicated(current$record_id))stop("Duplicate current W07 record IDs",call.=FALSE)
if(length(setdiff(zero$record_id,current$record_id)))stop("Zero-topic set contains IDs outside current W07 population",call.=FALSE)

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

prior_zero<-read_jsonl(prior_zero_path)
prior_zero_ids<-if(length(prior_zero))vapply(prior_zero,function(z)scalar(z$record_id),character(1))else character()
if(any(!nzchar(prior_zero_ids))||anyDuplicated(prior_zero_ids))stop("Prior zero-topic rescreen identity invariant failed",call.=FALSE)
prior_zero_map<-setNames(prior_zero,prior_zero_ids)

reuse_ids<-character()
if(nzchar(prior_records_path)&&length(prior_zero)){
  prior_records<-read_csv(prior_records_path,show_col_types=FALSE,progress=FALSE)
  if(!all(c("record_id","topic_input_sha256")%in%names(prior_records))||anyDuplicated(prior_records$record_id))stop("Prior W07 records invalid for zero-topic reuse",call.=FALSE)
  cur_fp<-setNames(as.character(current$topic_input_sha256),current$record_id)
  old_fp<-setNames(as.character(prior_records$topic_input_sha256),prior_records$record_id)
  candidates<-intersect(as.character(zero$record_id),intersect(prior_zero_ids,names(old_fp)))
  reuse_ids<-candidates[cur_fp[candidates]==old_fp[candidates]]
}

queue_ids<-setdiff(as.character(zero$record_id),reuse_ids)
curmap<-current |> filter(record_id%in%zero$record_id)
queue<-curmap |> filter(record_id%in%queue_ids) |> select(record_id,title,abstract,topic_input_sha256)
reuse_rows<-if(length(reuse_ids))unname(prior_zero_map[reuse_ids])else list()

write_csv(queue,file.path(output_dir,"zero_topic_rescreen_queue.csv"),na="")
write_jsonl(reuse_rows,file.path(output_dir,"reused_zero_topic_rescreen.jsonl"))

manifest<-list(
  schema="living-evidence-map-workflow07-zero-rescreen-prepare-v1",status="PASS",
  zero_topic_records=nrow(zero),reused_zero_rescreen=length(reuse_ids),
  zero_rescreen_queue_records=nrow(queue),
  reuse_basis="same record_id and unchanged title/abstract fingerprint with prior zero-topic decision",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(manifest,file.path(output_dir,"zero_prepare_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: W07 zero-topic preparation zero=%d reuse=%d rescreen=%d\n",nrow(zero),length(reuse_ids),nrow(queue)))
