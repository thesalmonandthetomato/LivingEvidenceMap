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
   as.integer(x$canonical_records)!=19117L) {
  stop("Pointer is not a published final Workflow 08 canonical dataset",call.=FALSE)
}

expected_sha <- tolower(as.character(x$final_canonical_jsonl_sha256))
if(!grepl("^[0-9a-f]{64}$",expected_sha)) stop("Workflow 08 pointer has invalid canonical SHA-256",call.=FALSE)

archive_name <- if(!is.null(x$canonical_archive_filename)) {
  as.character(x$canonical_archive_filename)
} else {
  "living_evidence_map_canonical_final.jsonl"
}
file_meta <- Filter(function(z) identical(as.character(z$filename),archive_name),x$files)
if(length(file_meta)!=1L) stop("Workflow 08 pointer does not identify exactly one canonical archive",call.=FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)

dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
url <- paste0("https://zenodo.org/api/records/",x$zenodo_record_id,"/files/",archive_name,"/content")
resp <- request(url) |>
  req_headers(Authorization=paste("Bearer",token)) |>
  req_timeout(1800) |>
  req_error(is_error=function(resp)FALSE) |>
  req_perform()
if(resp_status(resp)!=200L) stop(sprintf("Zenodo download HTTP %d",resp_status(resp)),call.=FALSE)

raw <- resp_body_raw(resp)
if(identical(as.character(x$canonical_archive_compression),"gzip") || grepl("\\.gz$",archive_name)){
  tmp <- tempfile(fileext=".jsonl.gz")
  writeBin(raw,tmp)
  in_con <- gzfile(tmp,"rb")
  out_con <- file(output,"wb")
  on.exit({try(close(in_con),silent=TRUE);try(close(out_con),silent=TRUE)},add=TRUE)
  repeat {
    buf <- readBin(in_con,"raw",n=1024L*1024L)
    if(!length(buf)) break
    writeBin(buf,out_con)
  }
  close(in_con); close(out_con); on.exit(NULL,add=FALSE)
  unlink(tmp)
} else {
  writeBin(raw,output)
}

actual_sha <- tolower(digest(file=output,algo="sha256",serialize=FALSE))
if(!identical(actual_sha,expected_sha)) stop(sprintf("Canonical checksum mismatch: expected %s; found %s",expected_sha,actual_sha),call.=FALSE)

con <- file(output,"rt",encoding="UTF-8");on.exit(close(con),add=TRUE)
n <- 0L
repeat { z<-readLines(con,n=1000L,warn=FALSE); if(!length(z))break; n<-n+sum(nzchar(trimws(z))) }
if(n!=19117L) stop(sprintf("Canonical record-count mismatch: expected 19117; found %d",n),call.=FALSE)

cat(sprintf("PASS: restored authoritative Workflow 08 canonical: %d records; SHA256=%s\n",n,actual_sha))
