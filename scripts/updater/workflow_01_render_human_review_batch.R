#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

queue_path <- arg("--queue")
output_dir <- arg("--output-dir")
start <- as.integer(arg("--start","1"))
size <- as.integer(arg("--size","10"))
if (is.null(queue_path)||is.null(output_dir)) stop("Required: --queue --output-dir",call.=FALSE)
if (is.na(start)||start<1L||is.na(size)||size<1L) stop("--start and --size must be positive integers",call.=FALSE)

read_jsonl <- function(path) {
  if(!file.exists(path)) stop(sprintf("File not found: %s",path),call.=FALSE)
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
write_jsonl <- function(x,path) {
  con <- file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for(z in x) writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}
required_record_fields <- c("source","source_record_id","title","abstract","keywords","journal","year","authors","volume","issue","pages","doi")

queue <- read_jsonl(queue_path)
if (!length(queue)) stop("Human-review queue is empty",call.=FALSE)
queue_ids <- vapply(queue,function(z)as.character(z$review_case_id),character(1))
if (anyDuplicated(queue_ids)) stop("Queue contains duplicate review_case_id",call.=FALSE)
for(z in queue) {
  if (is.null(z$pair_key)||!nzchar(as.character(z$pair_key))) stop("Queue case missing pair_key",call.=FALSE)
  for(side in c("record_i","record_j")) {
    rec <- z[[side]]
    if (is.null(rec)) stop(sprintf("Queue case %s missing %s",z$review_case_id,side),call.=FALSE)
    miss <- setdiff(required_record_fields,names(rec))
    if(length(miss)) stop(sprintf("Queue case %s %s missing fields: %s",z$review_case_id,side,paste(miss,collapse=", ")),call.=FALSE)
    if(is.null(rec$source_record_id)||!nzchar(as.character(rec$source_record_id))) stop("source_record_id is required",call.=FALSE)
  }
}

end <- min(length(queue),start+size-1L)
if(start>length(queue)) stop(sprintf("--start %d exceeds queue length %d",start,length(queue)),call.=FALSE)
sel <- queue[start:end]
queue_sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)
batch_id <- sprintf("hrbatch-%04d-%04d-%s",start,end,substr(queue_sha,1,12))

for(k in seq_along(sel)) {
  sel[[k]]$review_batch <- list(
    batch_id=batch_id,
    queue_sha256=queue_sha,
    queue_ordinal=start+k-1L,
    batch_ordinal=k
  )
}

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
batch_path <- file.path(output_dir,"batch.jsonl")
write_jsonl(sel,batch_path)

fmt <- function(x) {
  if(is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(as.character(x)))) return("[missing]")
  as.character(x)
}
md <- c(
  sprintf("# Workflow 01 human-review batch %s",batch_id),
  "",
  sprintf("- Queue SHA-256: `%s`",queue_sha),
  sprintf("- Queue range: %d–%d of %d",start,end,length(queue)),
  "- This file is mechanically rendered from the immutable queue. Do not substitute cases from conversation memory.",
  ""
)
for(k in seq_along(sel)) {
  z <- sel[[k]]
  md <- c(md,
    sprintf("## %d. `%s`",start+k-1L,z$review_case_id),
    sprintf("- Pair key: `%s`",z$pair_key),
    "",
    "### Record A",
    sprintf("- Source: `%s`",fmt(z$record_i$source)),
    sprintf("- Source record ID: `%s`",fmt(z$record_i$source_record_id)),
    sprintf("- Title: %s",fmt(z$record_i$title)),
    sprintf("- Authors: %s",fmt(z$record_i$authors)),
    sprintf("- Year: %s",fmt(z$record_i$year)),
    sprintf("- Journal/source: %s",fmt(z$record_i$journal)),
    sprintf("- Volume/issue/pages: %s / %s / %s",fmt(z$record_i$volume),fmt(z$record_i$issue),fmt(z$record_i$pages)),
    sprintf("- DOI: %s",fmt(z$record_i$doi)),
    sprintf("- Keywords: %s",fmt(z$record_i$keywords)),
    "",
    "**Abstract A**",
    "",
    fmt(z$record_i$abstract),
    "",
    "### Record B",
    sprintf("- Source: `%s`",fmt(z$record_j$source)),
    sprintf("- Source record ID: `%s`",fmt(z$record_j$source_record_id)),
    sprintf("- Title: %s",fmt(z$record_j$title)),
    sprintf("- Authors: %s",fmt(z$record_j$authors)),
    sprintf("- Year: %s",fmt(z$record_j$year)),
    sprintf("- Journal/source: %s",fmt(z$record_j$journal)),
    sprintf("- Volume/issue/pages: %s / %s / %s",fmt(z$record_j$volume),fmt(z$record_j$issue),fmt(z$record_j$pages)),
    sprintf("- DOI: %s",fmt(z$record_j$doi)),
    sprintf("- Keywords: %s",fmt(z$record_j$keywords)),
    "",
    "**Abstract B**",
    "",
    fmt(z$record_j$abstract),
    "",
    "### Deterministic evidence",
    "",
    paste(capture.output(str(z$deterministic_evidence,give.attr=FALSE)),collapse="
"),
    ""
  )
}
writeLines(md,file.path(output_dir,"batch_review.md"),useBytes=TRUE)

manifest <- list(
  schema="living-evidence-map-workflow01-human-review-batch-v1",
  batch_id=batch_id,
  queue_sha256=queue_sha,
  queue_size=length(queue),
  start=start,
  end=end,
  size=length(sel),
  batch_sha256=digest(file=batch_path,algo="sha256",serialize=FALSE),
  expected_review_case_ids=vapply(sel,function(z)as.character(z$review_case_id),character(1)),
  expected_pairs=lapply(sel,function(z)list(
    review_case_id=as.character(z$review_case_id),
    pair_key=as.character(z$pair_key),
    record_i=list(source=as.character(z$record_i$source),source_record_id=as.character(z$record_i$source_record_id)),
    record_j=list(source=as.character(z$record_j$source),source_record_id=as.character(z$record_j$source_record_id))
  ))
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"batch_manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: rendered %s with %d cases from queue SHA %s\n",batch_id,length(sel),queue_sha))
