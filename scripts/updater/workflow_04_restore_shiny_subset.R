#!/usr/bin/env Rscript
# Restore a review-scoped, immutable Shiny subset bundle and its archived W04
# prompt. This is an input adapter, NOT an alternative model screener.
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
  library(httr2)
})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop("Missing value for ",flag,call.=FALSE)
  args[[i+1L]]
}
deposit_id <- arg("--deposit-id")
bundle_name <- arg("--bundle-file")
bundle_sha <- tolower(arg("--bundle-sha256",""))
review_id <- arg("--review-id")
canonical_path <- arg("--canonical")
output_dir <- arg("--output-dir","inputs/shiny_w04")
if(!grepl("^[0-9]+$",deposit_id %||% ""))
  stop("Invalid Zenodo prompt draft ID",call.=FALSE)
if(!grepl("^w04-model-input-[0-9a-f]{20}\.json$",bundle_name %||% ""))
  stop("Invalid immutable subset bundle filename",call.=FALSE)
if(!grepl("^[0-9a-f]{64}$",bundle_sha))
  stop("Invalid bundle checksum",call.=FALSE)
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review_id %||% ""))
  stop("Invalid active review ID",call.=FALSE)
if(is.null(canonical_path)||!file.exists(canonical_path))
  stop("Current W03 canonical checkpoint is missing",call.=FALSE)
token <- Sys.getenv("ZENODO_ACCESS_TOKEN",unset="")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)
`%||%` <- function(x,y) if(is.null(x) || length(x)==0L) y else x
fetch <- function(url) {
  req <- request(url) |>
    req_headers(Authorization=paste("Bearer",token)) |>
    req_timeout(120)
  resp <- req_perform(req)
  if(resp_status(resp)!=200L) stop("Authenticated Zenodo download failed",call.=FALSE)
  resp_body_raw(resp)
}
draft <- fromJSON(rawToChar(fetch(paste0(
  "https://zenodo.org/api/deposit/depositions/",deposit_id))),simplifyVector=FALSE)
expected_title <- paste("Living Evidence Map W04 prompt development |",review_id)
if(!identical(as.character(draft$metadata$title %||% ""),expected_title) ||
   isTRUE(draft$submitted))
  stop("Zenodo prompt draft is not the active review's restricted draft",call.=FALSE)
files <- draft$files %||% list()
get_file <- function(name) {
  hits <- Filter(function(x)identical(as.character(x$filename %||% ""),name),files)
  if(length(hits)!=1L) stop("Expected one immutable Zenodo file: ",name,call.=FALSE)
  url <- as.character(hits[[1L]]$links$download %||% "")
  if(!startsWith(url,"https://zenodo.org/"))
    stop("Unexpected Zenodo file location",call.=FALSE)
  fetch(url)
}
bundle_bytes <- get_file(bundle_name)
if(!identical(digest(bundle_bytes,algo="sha256",serialize=FALSE),bundle_sha))
  stop("Shiny input bundle checksum mismatch",call.=FALSE)
bundle <- fromJSON(rawToChar(bundle_bytes),simplifyVector=FALSE)
if(!identical(bundle$schema,"lem-w04-shiny-subset-input-v1") ||
   !identical(bundle$review_id,review_id))
  stop("Shiny bundle schema or review identity mismatch",call.=FALSE)
ids <- unlist(bundle$record_ids,use.names=FALSE)
if(!is.character(ids)||!length(ids)||anyNA(ids)||any(!nzchar(ids))||
   anyDuplicated(ids))
  stop("Invalid or duplicated registered subset members",call.=FALSE)
if(!grepl("^w04-subset-[0-9a-f]{20}$",as.character(bundle$subset_id %||% "")) ||
   !grepl("^[0-9a-f]{64}$",as.character(bundle$queue_sha256 %||% "")))
  stop("Missing registered subset provenance",call.=FALSE)
source_sha <- tolower(as.character(bundle$source_checkpoint_sha256 %||% ""))
if(!grepl("^[0-9a-f]{64}$",source_sha) ||
   !identical(digest(file=canonical_path,algo="sha256",serialize=FALSE),source_sha))
  stop("Registered subset source checkpoint SHA differs from W03 input",call.=FALSE)
prompt_version <- as.character(bundle$prompt_version_id %||% "")
prompt_expected <- tolower(as.character(bundle$prompt_sha256 %||% ""))
if(!grepl("^w04-[0-9a-f]{20}$",prompt_version) ||
   !grepl("^[0-9a-f]{64}$",prompt_expected))
  stop("Invalid archived W04 prompt identity",call.=FALSE)
version <- fromJSON(rawToChar(get_file(paste0(prompt_version,".json"))),
                    simplifyVector=FALSE)
prompt <- as.character(version$content %||% "")
if(!identical(version$review_id,review_id) ||
   !identical(version$version_id,prompt_version) ||
   !identical(tolower(as.character(version$sha256)),prompt_expected) ||
   !identical(digest(prompt,algo="sha256",serialize=FALSE),prompt_expected))
  stop("Archived W04 prompt identity or checksum mismatch",call.=FALSE)
lines <- readLines(canonical_path,warn=FALSE,encoding="UTF-8")
rows <- lapply(lines[nzchar(trimws(lines))],fromJSON,simplifyVector=FALSE)
row_ids <- vapply(rows,function(r)as.character(
  (r$identity %||% list())$record_id %||% ""),character(1))
if(any(!nzchar(row_ids))||anyDuplicated(row_ids)||
   length(setdiff(ids,row_ids)))
  stop("Shiny subset members do not match canonical record identities",call.=FALSE)
positions <- match(ids,row_ids)
corrections <- bundle$abstract_corrections %||% list()
edit_ids <- vapply(corrections,function(e)as.character(e$record_id %||% ""),
                   character(1))
if(any(!nzchar(edit_ids))||anyDuplicated(edit_ids)||
   length(setdiff(edit_ids,ids)))
  stop("Invalid or duplicated Shiny abstract corrections",call.=FALSE)
if(length(corrections)) for(e in corrections) {
  id <- as.character(e$record_id)
  abstract <- as.character(e$abstract %||% "")
  case_id <- as.character(e$review_case_id %||% "")
  if(length(abstract)!=1L||!nzchar(trimws(abstract))||
     !identical(case_id,paste0(bundle$subset_id,"|",id)))
    stop("Invalid abstract correction record or text",call.=FALSE)
  j <- match(id,row_ids)
  if(is.null(rows[[j]]$canonical)||!is.list(rows[[j]]$canonical))
    rows[[j]]$canonical <- list()
  rows[[j]]$canonical[["abstract"]] <- abstract
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
writeLines(ids,file.path(output_dir,"selected_record_ids.txt"),useBytes=TRUE)
canonical_overlay_path <- file.path(output_dir,"canonical_with_edits.jsonl")
writeLines(vapply(rows,function(r)toJSON(r,auto_unbox=TRUE,null="null",
  na="null",digits=NA),character(1)),canonical_overlay_path,useBytes=TRUE)
prompt_path <- file.path(output_dir,"screening_prompt.txt")
writeLines(prompt,prompt_path,useBytes=TRUE)
cfg <- fromJSON("user_input/workflow04_screening_config.json",
                simplifyVector=FALSE)
cfg$prompt_path <- prompt_path
cfg$prompt_version <- prompt_version
cfg$expected_prompt_sha256 <- prompt_expected
config_path <- file.path(output_dir,"screening_config.json")
write_json(cfg,config_path,auto_unbox=TRUE,pretty=TRUE)
manifest <- list(schema="lem-w04-shiny-subset-restoration-v1",review_id=review_id,
  subset_id=bundle$subset_id,queue_sha256=bundle$queue_sha256,
  source_checkpoint_sha256=source_sha,record_count=length(ids),
  correction_count=length(corrections),bundle_sha256=bundle_sha,
  prompt_version_id=prompt_version,prompt_sha256=prompt_expected)
write_json(manifest,file.path(output_dir,"input_manifest.json"),
           auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS Shiny W04 input: %d selected records, %d corrections, prompt %s\\n",
            length(ids),length(corrections),prompt_version))
