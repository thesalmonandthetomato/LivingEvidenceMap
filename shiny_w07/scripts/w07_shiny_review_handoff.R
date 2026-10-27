#!/usr/bin/env Rscript
# Experimental W07 human-review handoff. Read only; never invokes models or W08.
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
`%||%` <- function(a,b) if(is.null(a)||!length(a))b else a
source("shiny_w07/R/w07_shiny_review_contract.R")
env <- function(k)Sys.getenv(k,unset="")
review <- env("W07_REVIEW_ID")
run_id <- env("W07_SOURCE_RUN_ID")
draft <- env("W07_CONFIG_DEPOSIT_ID")
filename <- env("W07_ARCHIVE_FILENAME")
expected <- env("W07_ARCHIVE_SHA256")
token <- env("ZENODO_ACCESS_TOKEN")
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review) ||
   !grepl("^[0-9]+$",run_id) || !grepl("^[0-9]+$",draft) ||
   !grepl("^[a-f0-9]{64}$",expected) ||
   !identical(filename,paste0("w07-reviewed-",run_id,"-",expected,".json")) ||
   !nzchar(token))
  stop("Invalid W07 experimental handoff request",call.=FALSE)
fetch <- function(url) {
  if(!startsWith(url,"https://zenodo.org/"))
    stop("Untrusted W07 archive URL",call.=FALSE)
  resp <- req_perform(request(url) |> req_auth_bearer_token(token) |>
                        req_timeout(120))
  resp_body_raw(resp)
}
dep <- fromJSON(rawToChar(fetch(paste0(
  "https://zenodo.org/api/deposit/depositions/",draft))),simplifyVector=FALSE)
if(isTRUE(dep$submitted) ||
   !identical(as.character(dep$metadata$access_right),"restricted") ||
   !identical(as.character(dep$metadata$title),
     paste("Living Evidence Map W07 topic configuration |",review)))
  stop("W07 archive deposit identity mismatch",call.=FALSE)
files <- Filter(function(z)identical(as.character(z$filename %||% ""),filename),
                dep$files %||% list())
if(length(files)!=1L)stop("Missing or duplicate reviewed-trial archive",call.=FALSE)
bytes <- fetch(as.character(files[[1L]]$links$download %||% ""))
if(!identical(digest(bytes,algo="sha256",serialize=FALSE),expected))
  stop("W07 reviewed-trial archive checksum mismatch",call.=FALSE)
payload <- fromJSON(rawToChar(bytes),simplifyVector=FALSE)
w07_review_handoff_validate(payload,review,run_id)
out <- file.path(env("RUNNER_TEMP"),"w07-reviewed-handoff")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
writeBin(bytes,file.path(out,filename))
write_json(list(schema="lem-w07-handoff-receipt-v1",
  review_id=review,source_run_id=run_id,archive_deposit_id=draft,
  archive_filename=filename,sha256=expected,
  records=length(payload$model_results),status="verified_not_published"),
  file.path(out,"w07_handoff_receipt.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS W07 reviewed trial: %d records, SHA-256 %s\n",
            length(payload$model_results),expected))
