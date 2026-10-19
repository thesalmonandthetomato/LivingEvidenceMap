#!/usr/bin/env Rscript
# Combined W04 publication preflight. Read-only; never writes to Google Sheets.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
`%||%` <- function(x,y)if(is.null(x)||!length(x))y else x
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k) {j<-match(k,args);if(is.na(j)||j>=length(args))stop("Missing ",k,call.=FALSE);args[[j+1L]]}
manifest_path <- arg("--input-manifest")
merged_path <- arg("--merged")
selected_path <- arg("--selected-ids")
manifest <- fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(manifest$schema,"lem-w04-combined-restoration-v1"))
  stop("Not a combined W04 restoration manifest",call.=FALSE)
if(!grepl("^[a-f0-9]{64}$",as.character(manifest$batch_membership_sha256 %||% "")) ||
   !grepl("^[a-f0-9]{64}$",as.character(manifest$prompt_sha256 %||% "")))
  stop("Combined manifest has invalid checksums",call.=FALSE)
selected <- readLines(selected_path,warn=FALSE,encoding="UTF-8")
if(!length(selected)||anyDuplicated(selected)||any(!nzchar(selected)) ||
   length(selected)!=as.integer(manifest$record_count))
  stop("Selected record set invalid",call.=FALSE)
hash_members <- function(x)digest(paste(x,collapse="\\n"),algo="sha256",serialize=FALSE)
if(!identical(hash_members(selected),as.character(manifest$batch_membership_sha256)))
  stop("Combined selected record checksum mismatch",call.=FALSE)
lines <- readLines(merged_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
if(length(lines)!=length(selected))
  stop("Combined model return does not cover exact selected batch",call.=FALSE)
rows <- lapply(lines,fromJSON,simplifyVector=FALSE)
ids <- vapply(rows,function(x)as.character(x$record_id %||% ""),character(1))
decisions <- vapply(rows,function(x)as.character(
  (x$screening %||% list())$decision %||% ""),character(1))
shas <- vapply(rows,function(x)as.character(
  (x$screening %||% list())$prompt_sha256 %||% ""),character(1))
if(any(!nzchar(ids))||anyDuplicated(ids)||!setequal(ids,selected) ||
   any(!decisions%in%c("retain","exclude","uncertain")) ||
   any(shas!=as.character(manifest$prompt_sha256)))
  stop("Combined return membership, decisions or prompt provenance mismatch",call.=FALSE)
cat(sprintf("PASS combined W04 return: %s, %d rows (%d retain, %d exclude, %d uncertain)\\n",
 as.character(manifest$batch_key),length(rows),
 sum(decisions=="retain"),sum(decisions=="exclude"),sum(decisions=="uncertain")))
