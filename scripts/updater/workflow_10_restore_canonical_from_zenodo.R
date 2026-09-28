#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
pointer <- arg("--pointer")
output <- arg("--output")
if(is.null(pointer)||is.null(output)) stop("Required: --pointer --output",call.=FALSE)
if(!file.exists(pointer)) stop("Workflow 08 pointer not found: ",pointer,call.=FALSE)

x <- fromJSON(pointer,simplifyVector=FALSE)
if(!identical(x$status,"published") ||
   !identical(x$workflow,"08") ||
   !identical(x$state,"corrected_final_adjudicated_canonical") ||
   as.character(x$zenodo_record_id)!="22998934" ||
   as.integer(x$canonical_records)!=19117L) {
  stop("Pointer is not the authoritative corrected Workflow 08 canonical dataset",call.=FALSE)
}

expected_sha <- tolower(as.character(x$final_canonical_jsonl_sha256))
if(!identical(expected_sha,"ab5f10fd7b70c5a210c06770ab1f7548a5eac4b48cb9f0326fede6d751e8df67")) {
  stop("Unexpected authoritative Workflow 08 canonical SHA-256",call.=FALSE)
}

file_meta <- Filter(function(z) identical(as.character(z$filename),"living_evidence_map_canonical_final.jsonl"),x$files)
if(length(file_meta)!=1L) stop("Workflow 08 pointer does not identify exactly one final canonical JSONL",call.=FALSE)
if(!identical(tolower(as.character(file_meta[[1L]]$sha256)),expected_sha)) stop("Pointer checksum disagreement",call.=FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)

dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
url <- paste0("https://zenodo.org/api/records/",x$zenodo_record_id,"/files/living_evidence_map_canonical_final.jsonl/content")
resp <- request(url) |>
  req_headers(Authorization=paste("Bearer",token)) |>
  req_timeout(1800) |>
  req_error(is_error=function(resp)FALSE) |>
  req_perform()
if(resp_status(resp)!=200L) stop(sprintf("Zenodo download HTTP %d",resp_status(resp)),call.=FALSE)
writeBin(resp_body_raw(resp),output)

actual_sha <- tolower(digest(file=output,algo="sha256",serialize=FALSE))
if(!identical(actual_sha,expected_sha)) stop(sprintf("Canonical checksum mismatch: expected %s; found %s",expected_sha,actual_sha),call.=FALSE)

con <- file(output,"rt",encoding="UTF-8");on.exit(close(con),add=TRUE)
n <- 0L
repeat { z<-readLines(con,n=1000L,warn=FALSE); if(!length(z))break; n<-n+sum(nzchar(trimws(z))) }
if(n!=19117L) stop(sprintf("Canonical record-count mismatch: expected 19117; found %d",n),call.=FALSE)

cat(sprintf("PASS: restored authoritative Workflow 08 canonical: %d records; SHA256=%s\n",n,actual_sha))
