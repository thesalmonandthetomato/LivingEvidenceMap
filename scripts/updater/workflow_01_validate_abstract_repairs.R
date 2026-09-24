#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
queue_path <- arg("--queue")
output_path <- arg("--output")
if(any(vapply(list(queue_path,output_path),is.null,logical(1)))) stop("Required: --queue --output",call.=FALSE)

read_jsonl <- function(path){
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
q <- read_jsonl(queue_path)

keys <- character()
for(z in q){
  required <- c("review_case_id","pair_key","source","source_record_id","workflow01_action",
                "downstream_workflow","downstream_queue","downstream_status")
  miss <- required[vapply(required,function(n)is.null(z[[n]])||!nzchar(trimws(as.character(z[[n]]))),logical(1))]
  if(length(miss)) stop(sprintf("Handoff item missing fields: %s",paste(miss,collapse=", ")),call.=FALSE)
  if(!identical(as.character(z$workflow01_action),"strip_incorrect_abstract")) stop("Invalid Workflow 01 action",call.=FALSE)
  if(!identical(as.character(z$downstream_workflow),"03")) stop("Abstract mismatch must hand off to Workflow 03",call.=FALSE)
  if(!identical(as.character(z$downstream_queue),"abstract_repair")) stop("Invalid Workflow 03 queue",call.=FALSE)
  key <- paste(z$source,z$source_record_id,sep=":")
  if(key %in% keys) stop(sprintf("Duplicate source record in Workflow 03 handoff: %s",key),call.=FALSE)
  keys <- c(keys,key)
}

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
manifest <- list(
  schema="living-evidence-map-workflow01-workflow03-handoff-validation-v1",
  queue_sha256=digest(file=queue_path,algo="sha256",serialize=FALSE),
  handoff_records=length(q),
  unique_source_records=length(keys),
  workflow01_deduplication_complete_independently=TRUE,
  downstream_workflow="03",
  downstream_queue="abstract_repair",
  rerun_deduplication=FALSE
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),output_path,useBytes=TRUE)
cat(sprintf("PASS: validated %d-record Workflow 03 abstract-repair handoff; no deduplication rerun required\n",length(q)))
