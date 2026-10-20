#!/usr/bin/env Rscript
# Restore a checked, immutable W04 reconciliation bundle from the existing
# review-specific restricted Zenodo draft. Offline finalisation, no model calls.
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
args<-commandArgs(trailingOnly=TRUE)
arg<-function(x){i<-match(x,args);if(is.na(i)||i==length(args))stop("Missing ",x);args[[i+1L]]}
draft_id<-arg("--deposit-id");filename<-arg("--bundle-file")
sha<-tolower(arg("--bundle-sha256"));review<-arg("--review-id")
canonical<-arg("--canonical");output<-arg("--output")
if(!grepl("^[0-9]+$",draft_id) ||
   !grepl("^w04-model-input-[0-9a-f]{20}\\.json$",filename) ||
   !grepl("^[0-9a-f]{64}$",sha) ||
   !grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review))
  stop("Invalid immutable reconciliation input arguments",call.=FALSE)
token<-Sys.getenv("ZENODO_ACCESS_TOKEN",unset="")
if(!nzchar(token))stop("Restricted Zenodo credential required",call.=FALSE)
fetch<-function(url) {
  resp<-httr2::req_perform(httr2::req_timeout(httr2::req_headers(
    httr2::request(url),Authorization=paste("Bearer",token)),120))
  if(httr2::resp_status(resp)!=200L)stop("Authenticated Zenodo read failed",call.=FALSE)
  httr2::resp_body_raw(resp)
}
draft<-jsonlite::fromJSON(rawToChar(fetch(paste0(
 "https://zenodo.org/api/deposit/depositions/",draft_id))),simplifyVector=FALSE)
if(!identical(as.character(draft$metadata$title %||% ""),
              paste("Living Evidence Map W04 prompt development |",review)) ||
   isTRUE(draft$submitted))
  stop("Wrong review or submitted Zenodo draft",call.=FALSE)
matches<-Filter(function(x)identical(as.character(x$filename %||% ""),filename),
                draft$files %||% list())
if(length(matches)!=1L)stop("Immutable reconciliation bundle not uniquely archived",call.=FALSE)
url<-as.character(matches[[1L]]$links$download %||% "")
if(!startsWith(url,"https://zenodo.org/"))stop("Untrusted bundle URL",call.=FALSE)
bytes<-fetch(url)
if(!identical(digest::digest(bytes,algo="sha256",serialize=FALSE),sha))
 stop("Archived reconciliation SHA mismatch",call.=FALSE)
bundle<-jsonlite::fromJSON(rawToChar(bytes),simplifyVector=FALSE)
if(!identical(as.character(bundle$schema),"lem-w04-reconciled-finalise-input-v1") ||
   !identical(as.character(bundle$review_id),review) ||
   !identical(tolower(as.character(bundle$source_checkpoint_sha256)),
     digest::digest(file=canonical,algo="sha256",serialize=FALSE)))
 stop("Reconciliation schema, review or source checkpoint mismatch",call.=FALSE)
rows<-bundle$records %||% list()
if(length(rows)!=as.integer(bundle$record_count)||!length(rows))
 stop("Reconciliation count mismatch",call.=FALSE)
ids<-vapply(rows,function(x)as.character(x$record_id %||% ""),character(1))
if(anyDuplicated(ids)||any(!nzchar(ids)) ||
   any(vapply(rows,function(x)
    !identical(as.character(x$status %||% ""),"resolved") ||
    !as.character(x$decision %||% "") %in% c("retain","exclude"),logical(1))))
 stop("Invalid reconciled canonical ID decisions",call.=FALSE)
payload<-vapply(rows,function(x)jsonlite::toJSON(x,auto_unbox=TRUE,
 null="null",na="null",digits=NA),character(1))
if(!identical(digest::digest(paste(payload,collapse="\\n"),
  algo="sha256",serialize=FALSE),as.character(bundle$records_sha256)))
 stop("Reconciliation content digest mismatch",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(payload,output,useBytes=TRUE)
cat("PASS: verified immutable W04 reconciliation",length(rows),"records\\n")
