#!/usr/bin/env Rscript
# Restore an immutable combined W04 batch. Separate from registered-subset restore.
# This adapter only prepares inputs; it never dispatches screening or publishes.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(httr2)})
`%||%` <- function(x,y)if(is.null(x)||!length(x))y else x
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
review <- arg("--review-id")
deposit_id <- arg("--deposit-id")
filename <- arg("--manifest-file")
expected_sha <- tolower(arg("--manifest-sha256"))
index <- suppressWarnings(as.integer(arg("--batch-index")))
canonical_path <- arg("--canonical")
output_dir <- arg("--output-dir")
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review) ||
   !grepl("^[0-9]+$",deposit_id) ||
   !grepl("^w04-combined-plan-[a-f0-9]{64}[.]json$",filename) ||
   !grepl("^[0-9a-f]{64}$",expected_sha) ||
   length(index)!=1L || is.na(index)||index<1L ||
   !file.exists(canonical_path))
  stop("Invalid immutable combined batch input arguments",call.=FALSE)
token <- Sys.getenv("ZENODO_ACCESS_TOKEN",unset="")
if(!nzchar(token))stop("ZENODO_ACCESS_TOKEN required",call.=FALSE)
fetch <- function(url){
  r <- req_perform(req_timeout(req_headers(request(url),
    Authorization=paste("Bearer",token)),120))
  if(resp_status(r)!=200L)stop("Authenticated Zenodo read failed",call.=FALSE)
  resp_body_raw(r)
}
draft <- fromJSON(rawToChar(fetch(paste0(
  "https://zenodo.org/api/deposit/depositions/",deposit_id))),simplifyVector=FALSE)
if(!identical(as.character(draft$metadata$title %||% ""),
              paste("Living Evidence Map W04 prompt development |",review)) ||
   isTRUE(draft$submitted))
  stop("Zenodo draft review identity or status mismatch",call.=FALSE)
get_file <- function(name){
  hits <- Filter(function(f)identical(as.character(f$filename %||% ""),name),
                 draft$files %||% list())
  if(length(hits)!=1L)stop("Expected one immutable archived file: ",name,call.=FALSE)
  url <- as.character(hits[[1L]]$links$download %||% "")
  if(!startsWith(url,"https://zenodo.org/"))
    stop("Unexpected archived file location",call.=FALSE)
  fetch(url)
}
bytes <- get_file(filename)
if(!identical(digest(bytes,algo="sha256",serialize=FALSE),expected_sha) ||
   !identical(filename,paste0("w04-combined-plan-",expected_sha,".json")))
  stop("Combined manifest checksum mismatch",call.=FALSE)
plan <- fromJSON(rawToChar(bytes),simplifyVector=FALSE)
if(!identical(plan$schema,"lem-w04-combined-plan-v1") ||
   !identical(as.character(plan$review_id),review) ||
   !identical(plan$dispatch_enabled,FALSE) ||
   length(plan$batches)!=as.integer(plan$batch_count) ||
   index>length(plan$batches))
  stop("Invalid combined manifest schema, review or batch index",call.=FALSE)
batch <- plan$batches[[index]]
ids <- unlist(batch$record_ids,use.names=FALSE)
sha <- function(ids) digest(paste(ids,collapse="\\n"),algo="sha256",serialize=FALSE)
if(!is.character(ids)||!length(ids)||anyNA(ids)||any(!nzchar(ids))||
   anyDuplicated(ids) || !identical(sha(ids),as.character(batch$membership_sha256)) ||
   length(ids)!=as.integer(batch$record_count) ||
   !identical(as.integer(batch$batch_index),index))
  stop("Combined batch has invalid canonical membership",call.=FALSE)
source_sha <- digest(file=canonical_path,algo="sha256",serialize=FALSE)
if(!identical(source_sha,as.character(plan$source_checkpoint_sha256)))
  stop("Combined batch source canonical checkpoint mismatch",call.=FALSE)
prompt_id <- as.character(plan$prompt_version_id %||% "")
prompt_sha <- as.character(plan$prompt_sha256 %||% "")
if(!grepl("^w04-[a-f0-9]{20}$",prompt_id) ||
   !grepl("^[a-f0-9]{64}$",prompt_sha))
  stop("Invalid combined prompt identity",call.=FALSE)
v <- fromJSON(rawToChar(get_file(paste0(prompt_id,".json"))),simplifyVector=FALSE)
prompt <- as.character(v$content %||% "")
if(!identical(as.character(v$review_id),review) ||
   !identical(as.character(v$version_id),prompt_id) ||
   !identical(as.character(v$sha256),prompt_sha) ||
   !identical(digest(prompt,algo="sha256",serialize=FALSE),prompt_sha))
  stop("Combined prompt checksum or provenance mismatch",call.=FALSE)
rows <- readLines(canonical_path,warn=FALSE,encoding="UTF-8")
records <- lapply(rows[nzchar(trimws(rows))],fromJSON,simplifyVector=FALSE)
row_ids <- vapply(records,function(r)as.character(
  (r$identity %||% list())$record_id %||% ""),character(1))
if(any(!nzchar(row_ids))||anyDuplicated(row_ids)||length(setdiff(ids,row_ids)))
  stop("Combined selected IDs are absent from canonical source",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
writeLines(ids,file.path(output_dir,"selected_record_ids.txt"),useBytes=TRUE)
prompt_path <- file.path(output_dir,"screening_prompt.txt")
cat(prompt,file=prompt_path)
if(!identical(digest(file=prompt_path,algo="sha256",serialize=FALSE),prompt_sha))
  stop("Persisted combined prompt byte checksum mismatch",call.=FALSE)
cfg <- fromJSON("user_input/workflow04_screening_config.json",simplifyVector=FALSE)
cfg$prompt_path <- prompt_path
cfg$prompt_version <- prompt_id
cfg$expected_prompt_sha256 <- prompt_sha
write_json(cfg,file.path(output_dir,"screening_config.json"),auto_unbox=TRUE,pretty=TRUE)
write_json(list(schema="lem-w04-combined-restoration-v1",review_id=review,
  run_key=plan$run_key,batch_key=batch$batch_key,batch_index=index,
  source_checkpoint_sha256=source_sha,selection_sha256=plan$selection_sha256,
  record_count=length(ids),batch_membership_sha256=batch$membership_sha256,
  prompt_version_id=prompt_id,prompt_sha256=prompt_sha,
  input_manifest_sha256=expected_sha),
  file.path(output_dir,"input_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS combined W04 batch %s: %d canonical records\\n",
  as.character(batch$batch_key),length(ids)))
