#!/usr/bin/env Rscript
# Read an immutable Shiny W04 reconciliation bundle and preserve the exact
# selected model-run/prompt map. The aggregate hash is a provenance-map hash,
# not the hash of any single model prompt.
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k) {i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
deposit <- arg("--deposit-id"); filename <- arg("--bundle-file")
sha <- tolower(arg("--bundle-sha256")); output <- arg("--output")
if(!grepl("^[0-9]+$",deposit) ||
   !grepl("^w04-model-input-[0-9a-f]{20}\\.json$",filename) ||
   !grepl("^[0-9a-f]{64}$",sha))stop("Invalid immutable W04 bundle identity",call.=FALSE)
token <- Sys.getenv("ZENODO_ACCESS_TOKEN",unset="")
if(!nzchar(token))stop("Restricted Zenodo token required",call.=FALSE)
get <- function(url) {
  res <- request(url) |> req_headers(Authorization=paste("Bearer",token)) |>
    req_timeout(120) |> req_perform()
  if(resp_status(res)!=200L)stop("Zenodo authenticated read failed",call.=FALSE)
  resp_body_raw(res)
}
draft <- fromJSON(rawToChar(get(paste0("https://zenodo.org/api/deposit/depositions/",deposit))),
                  simplifyVector=FALSE)
if(isTRUE(draft$submitted))stop("Shiny draft was already submitted",call.=FALSE)
hits <- Filter(function(x)identical(as.character(x$filename),filename),draft$files)
if(length(hits)!=1L)stop("Archived W04 bundle not unique",call.=FALSE)
url <- as.character(hits[[1L]]$links$download)
if(!startsWith(url,"https://zenodo.org/"))stop("Untrusted W04 bundle URL",call.=FALSE)
bytes <- get(url)
if(!identical(digest(bytes,algo="sha256",serialize=FALSE),sha))
  stop("W04 bundle checksum mismatch",call.=FALSE)
bundle <- fromJSON(rawToChar(bytes),simplifyVector=FALSE)
if(!identical(bundle$schema,"lem-w04-reconciled-finalise-input-v1"))
  stop("Unexpected W04 reconciliation schema",call.=FALSE)
runs <- bundle$selected_model_runs
if(is.null(runs)||!length(runs))stop("No selected model runs archived",call.=FALSE)
keys <- vapply(runs,function(x)as.character(x$subset_id),character(1))
ids <- vapply(runs,function(x)as.character(x$run_id),character(1))
prompts <- vapply(runs,function(x)tolower(as.character(x$prompt_sha256)),character(1))
versions <- vapply(runs,function(x)as.character(x$prompt_version_id),character(1))
if(any(!nzchar(keys))||anyDuplicated(keys)||anyDuplicated(ids)||
   any(!grepl("^[0-9]+$",ids))||any(!grepl("^[0-9a-f]{64}$",prompts))||
   any(!nzchar(versions)))
  stop("Invalid or duplicate selected W04 model-run provenance",call.=FALSE)
ord <- order(keys)
selected <- lapply(ord,function(i)list(subset_id=keys[[i]],run_id=ids[[i]],
  prompt_version_id=versions[[i]],prompt_sha256=prompts[[i]]))
map <- toJSON(selected,auto_unbox=TRUE,null="null",digits=NA)
aggregate <- digest(map,algo="sha256",serialize=FALSE)
result <- list(schema="lem-w04-selected-model-prompt-provenance-v1",
  prompt_sha256=aggregate,prompt_sha256_semantics="sha256_of_sorted_selected_run_prompt_map",
  review_id=as.character(bundle$review_id),source_bundle_sha256=sha,
  selected_model_runs=selected)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
write_json(result,output,auto_unbox=TRUE,pretty=TRUE)
cat("PASS: verified prompt provenance for",length(selected),"selected model runs\\n")
