#!/usr/bin/env Rscript
# Read-only review-specific W00 first-run contract. No repository state fallback.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default="") {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop("Missing value for ",flag,call.=FALSE)
  args[[i+1L]]
}
flag <- tolower(trimws(arg("--first-run")))
if(!flag %in% c("true","false")) stop("first_run must be true or false",call.=FALSE)
csv_path <- arg("--metadata-csv")
sheet_id <- arg("--sheet-id")
if(nzchar(csv_path) == nzchar(sheet_id))
  stop("Specify exactly one of --metadata-csv or --sheet-id",call.=FALSE)
if(nzchar(csv_path)) {
  d <- read.csv(csv_path,stringsAsFactors=FALSE,check.names=FALSE)
} else {
  if(!requireNamespace("googlesheets4",quietly=TRUE))
    stop("googlesheets4 is required",call.=FALSE)
  credential <- arg("--credential")
  if(!nzchar(credential)||!file.exists(credential)) stop("Review Sheet credentials missing",call.=FALSE)
  googlesheets4::gs4_auth(path=credential,cache=FALSE)
  d <- tryCatch(as.data.frame(googlesheets4::read_sheet(sheet_id,sheet="review_metadata")),
    error=function(e) stop("Cannot read review_metadata from review-specific Sheet: ",conditionMessage(e),call.=FALSE))
}
if(!all(c("key","value")%in%names(d))) stop("review_metadata must have key and value columns",call.=FALSE)
keys <- trimws(as.character(d$key))
vals <- trimws(as.character(d$value))
if(anyDuplicated(keys)||any(!nzchar(keys))) stop("review_metadata has blank or duplicate keys",call.=FALSE)
get <- function(k) {i <- match(k,keys);if(is.na(i)) "" else vals[[i]]}
review_id <- get("review_id")
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review_id))
  stop("review_metadata review_id missing or invalid",call.=FALSE)
baseline <- tolower(get("authoritative_w08_baseline"))
if(!baseline %in% c("true","false"))
  stop("review_metadata authoritative_w08_baseline must be TRUE or FALSE",call.=FALSE)
record <- get("latest_w08_zenodo_record_id")
if(baseline=="true" && !grepl("^[0-9]+$",record))
  stop("Authoritative W08 baseline requires a Zenodo record ID",call.=FALSE)
if(flag=="true" && baseline=="true")
  stop("first_run=TRUE but this review already has an authoritative W08 baseline",call.=FALSE)
if(flag=="false" && baseline=="false")
  stop("first_run=FALSE but this review has no authoritative W08 baseline",call.=FALSE)
cat(sprintf("PASS: review-specific W00 first_run=%s review_id=%s baseline=%s (read-only)\n",
  toupper(flag),review_id,toupper(baseline)))
