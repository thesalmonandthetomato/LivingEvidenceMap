#!/usr/bin/env Rscript
# Shiny pathway only. Publish the existing review-bound W05 restricted Zenodo
# draft after independently verifying a fresh full-corpus deterministic run.
suppressPackageStartupMessages({library(jsonlite);library(digest);library(httr2)})
one <- function(key) Sys.getenv(key,unset="")
token <- one("ZENODO_ACCESS_TOKEN")
id <- one("W05_DRAFT_ID")
review <- one("W05_REVIEW_ID")
expected_input <- tolower(one("W05_INPUT_SHA"))
expected_dictionary <- tolower(one("W05_DICT_SHA"))
dir <- file.path(one("RUNNER_TEMP"),"w05-shiny-results")
if(!nzchar(token)||!grepl("^[0-9]+$",id) ||
   !grepl("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$",review) ||
   !all(grepl("^[a-f0-9]{64}$",c(expected_input,expected_dictionary))))
  stop("Invalid W05 final-publication credentials, identity or checksums",call.=FALSE)
paths <- file.path(dir,c("w05_crop_assignments.csv","w05_crop_frequencies.csv",
                         "w05_crop_manifest.json","w05_unspecified_crop_evidence.csv"))
if(!all(file.exists(paths)))stop("W05 complete result files missing",call.=FALSE)
manifest <- fromJSON(paths[[3L]],simplifyVector=FALSE)
if(!identical(as.character(manifest$mode),"full_corpus") ||
   !identical(as.character(manifest$schema),"lem-w05-crop-test-v1") ||
   !identical(as.character(manifest$input_sha256),expected_input) ||
   !identical(as.character(manifest$dictionary_sha256),expected_dictionary) ||
   as.integer(manifest$processed_records)!=as.integer(manifest$input_records) ||
   as.integer(manifest$processed_records)<1L)
  stop("W05 final manifest fails full-corpus integrity conditions",call.=FALSE)
assign <- read.csv(paths[[1L]],stringsAsFactors=FALSE)
freq <- read.csv(paths[[2L]],stringsAsFactors=FALSE)
evidence <- read.csv(paths[[4L]],stringsAsFactors=FALSE)
if(!identical(names(assign),c("record_id","entity","code")) ||
   !identical(names(freq),c("entity","code","records")) ||
   !identical(names(evidence),c("record_id","title","abstract")) ||
   anyDuplicated(assign) || anyDuplicated(evidence$record_id) ||
   length(unique(assign$record_id))!=as.integer(manifest$processed_records) ||
   sum(freq$records)!=nrow(assign) ||
   !setequal(evidence$record_id,assign$record_id[
      assign$entity=="crop" & assign$code=="unspecified_horticultural_crop"]))
  stop("W05 final assignments, frequencies or provenance fail validation",call.=FALSE)
call <- function(url,method="GET",file=NULL){
  req <- request(url) |> req_headers(Authorization=paste("Bearer",token))
  if(identical(method,"PUT"))req <- req |> req_method("PUT") |> req_body_file(file,type="application/octet-stream")
  if(identical(method,"POST"))req <- req |> req_method("POST")
  req_perform(req_timeout(req,180))
}
base <- paste0("https://zenodo.org/api/deposit/depositions/",id)
deposit <- resp_body_json(call(base),simplifyVector=FALSE)
if(isTRUE(deposit$submitted) ||
   !identical(as.character(deposit$metadata$title),
              paste("Living Evidence Map W05 crop coding |",review)))
  stop("Final publication requires the matching unpublished W05 review draft",call.=FALSE)
if(!identical(as.character(deposit$metadata$access_right),"restricted"))
  stop("W05 final publication must remain restricted",call.=FALSE)
bucket <- as.character(deposit$links$bucket)
if(!startsWith(bucket,"https://zenodo.org/api/files/"))
  stop("Unexpected restricted Zenodo W05 bucket",call.=FALSE)
names <- c("w05-final-assignments.csv","w05-final-frequencies.csv",
           "w05-final-manifest.json","w05-final-unspecified-evidence.csv")
# Zenodo deposition checksums are MD5 digests; the API may return a bare
# digest or an md5:-prefixed digest. Never accept any other checksum algorithm.
md5_value <- function(x) {
  v <- tolower(as.character(x %||% ""))
  v <- sub("^md5:", "", v)
  if(length(v)!=1L || !grepl("^[0-9a-f]{32}$",v)) return(NA_character_)
  v
}
`%||%` <- function(x,y) if(is.null(x)||!length(x)) y else x
matching_file <- function(deposition,name) {
  files <- deposition$files %||% list()
  Filter(function(f)identical(as.character(f$filename %||% ""),name),files)
}
verify_file <- function(deposition,name,path) {
  matching <- matching_file(deposition,name)
  if(length(matching)!=1L)
    stop(sprintf("W05 Zenodo file %s missing or duplicated",name),call.=FALSE)
  expected <- unname(tools::md5sum(path))
  actual <- md5_value(matching[[1L]]$checksum)
  if(is.na(actual) || !identical(actual,expected))
    stop(sprintf("W05 Zenodo checksum mismatch for %s (expected md5 %s; received %s); publication blocked",
      name,expected,as.character(matching[[1L]]$checksum %||% "<missing>")),call.=FALSE)
}
# Idempotent only for byte-identical outputs. Never replace existing files.
for(i in seq_along(paths)) {
  existing <- matching_file(deposit,names[[i]])
  if(length(existing)>1L)
    stop(sprintf("Duplicate final W05 filename: %s",names[[i]]),call.=FALSE)
  if(length(existing)==1L) {
    verify_file(deposit,names[[i]],paths[[i]])
    cat(sprintf("PASS reuse checksum-verified existing W05 file %s\\n",names[[i]]))
  } else {
    call(paste0(sub("/$","",bucket),"/",names[[i]]),"PUT",paths[[i]])
    cat(sprintf("Uploaded new W05 final file %s\\n",names[[i]]))
  }
}
# Re-read draft and verify every file before publication.
verified <- resp_body_json(call(base),simplifyVector=FALSE)
for(i in seq_along(paths)) verify_file(verified,names[[i]],paths[[i]])
published <- resp_body_json(call(paste0(base,"/actions/publish"),"POST"),simplifyVector=FALSE)
if(!isTRUE(published$submitted))
  stop("Zenodo did not confirm final W05 publication",call.=FALSE)
receipt <- list(schema="lem-w05-shiny-final-publication-v1",
  review_id=review, github_run_id=one("GITHUB_RUN_ID"),
  zenodo_record_id=id,doi=published$doi,
  input_sha256=expected_input,dictionary_sha256=expected_dictionary,
  processed_records=manifest$processed_records,
  files=names,published_at=published$created)
write_json(receipt,file.path(dir,"w05_final_publication_receipt.json"),
           auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS final W05 published %s complete records to restricted Zenodo %s\n",
            manifest$processed_records,id))
