#!/usr/bin/env Rscript
# W07 Shiny-only read-only input restoration. Does not publish or call a model.
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})
source("shiny_w07/R/w05_w07_bridge.R")
env <- function(name) Sys.getenv(name,unset="")
review <- env("W07_REVIEW_ID")
id <- env("W07_W05_DEPOSIT_ID")
token <- env("ZENODO_ACCESS_TOKEN")
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review) ||
   !grepl("^[0-9]+$",id) || !nzchar(token))
  stop("Missing or invalid W07 Shiny review, W05 ID or Zenodo credentials",call.=FALSE)
request_bytes <- function(url) {
  req <- httr2::request(url) |> httr2::req_auth_bearer_token(token) |>
    httr2::req_timeout(180)
  res <- httr2::req_perform(httr2::req_error(req,is_error=function(x) FALSE))
  if(httr2::resp_status(res)!=200L)return(NULL)
  httr2::resp_body_raw(res)
}
url <- paste0("https://zenodo.org/api/deposit/depositions/",id)
dep_bytes <- request_bytes(url)
if(is.null(dep_bytes))stop("W05 Zenodo deposit metadata unavailable",call.=FALSE)
dep <- jsonlite::fromJSON(rawToChar(dep_bytes),simplifyVector=FALSE)
if(!isTRUE(dep$submitted) ||
   !identical(as.character(dep$metadata$title),
     paste("Living Evidence Map W05 crop coding |",review)) ||
   !identical(as.character(dep$metadata$access_right),"restricted"))
  stop("W07 requires the matching published restricted W05 source",call.=FALSE)
read_file <- function(filename) {
  found <- Filter(function(x)identical(as.character(x$filename %||% ""),filename),
    dep$files %||% list())
  if(length(found)!=1L)stop("W05 source file missing or duplicated: ",filename,call.=FALSE)
  file_url <- as.character(found[[1L]]$links$download %||% "")
  if(!startsWith(file_url,"https://zenodo.org/"))
    stop("Untrusted W05 download URL",call.=FALSE)
  bytes <- request_bytes(file_url)
  if(is.null(bytes)) {
    bytes <- request_bytes(paste0("https://zenodo.org/api/records/",id,
      "/files/",utils::URLencode(filename,reserved=TRUE),"/content"))
  }
  if(is.null(bytes))stop("Published W05 file not retrievable: ",filename,call.=FALSE)
  bytes
}
manifest <- jsonlite::fromJSON(rawToChar(read_file("w05-final-manifest.json")),
  simplifyVector=FALSE)
names <- vapply(dep$files %||% list(),
  function(f)as.character(f$filename %||% ""),character(1))
input_name <- grep("^w05-shiny-w04-input-[a-f0-9]{20}\\.jsonl$",names,value=TRUE)
if(length(input_name)!=1L)
  stop("Expected one canonical W05 JSONL source",call.=FALSE)
input_bytes <- read_file(input_name)
records <- w07_bridge_records(input_bytes,manifest)
receipt <- w07_bridge_receipt(records,review,id,w07_bridge_sha(input_bytes))
out <- file.path(env("RUNNER_TEMP") %||% tempdir(),"w07-shiny-input")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
utils::write.csv(records,file.path(out,"w07_records.csv"),row.names=FALSE,na="")
jsonlite::write_json(receipt,file.path(out,"w07_input_manifest.json"),
  auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS isolated W05 to W07 bridge: %d records; no W06 dependency or model calls\\n",
  nrow(records)))
