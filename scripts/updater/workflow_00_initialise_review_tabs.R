#!/usr/bin/env Rscript
# Initialise, never reset, review-specific metadata tabs.
# Explicit --apply required; without it only report intended operations.
suppressPackageStartupMessages(library(googlesheets4))
args <- commandArgs(trailingOnly=TRUE)
get_arg <- function(name, default="") {
  pos <- match(name,args)
  if(is.na(pos)) return(default)
  if(pos==length(args)) stop("Missing ",name,call.=FALSE)
  args[[pos+1L]]
}
sheet_id <- get_arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID",""))
credential <- get_arg("--credential","")
review_id <- get_arg("--review-id","")
apply <- "--apply" %in% args
if(!nzchar(sheet_id)||!nzchar(credential)||!file.exists(credential))
  stop("Explicit Sheet ID and credential file are required",call.=FALSE)
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review_id))
  stop("Valid review ID required",call.=FALSE)
gs4_auth(path=credential,cache=FALSE)
tabs <- sheet_names(sheet_id)
required <- c("review_metadata","workflow_events")
# Fail closed: never modify an existing tab until its schema is checked.
for(tab in intersect(required,tabs)) {
  existing <- as.data.frame(read_sheet(sheet_id,sheet=tab,n_max=1))
  expected <- if(tab=="review_metadata") c("key","value") else
    c("event_id","timestamp_utc","review_id","workflow","event_type","github_run_id","zenodo_record_id","details_json")
  if(!identical(names(existing),expected))
    stop(sprintf("Existing %s tab has unexpected column schema: aborting without modification",tab),call.=FALSE)
}
if("review_metadata" %in% tabs) {
  existing <- as.data.frame(read_sheet(sheet_id,sheet="review_metadata",col_types="cc"))
  keys <- trimws(as.character(existing$key))
  if(anyDuplicated(keys)) stop("Duplicate metadata keys",call.=FALSE)
  stored <- as.character(existing$value[match("review_id",keys)])
  if(length(stored)!=1L||is.na(stored)||!identical(stored,review_id))
    stop("Existing review_metadata belongs to another review (or lacks review_id)",call.=FALSE)
}
missing <- setdiff(required,tabs)
cat("Missing review tabs:",if(length(missing))paste(missing,collapse=", ") else "none","\n")
if(!apply) {
  cat("DRY RUN: no spreadsheet changes\n")
  quit(status=0L)
}
# Create metadata last: a partial initialisation cannot masquerade as a complete review.
if("workflow_events" %in% missing) {
  sheet_add(sheet_id,sheet="workflow_events")
  sheet_write(data.frame(
    event_id=character(),timestamp_utc=character(),review_id=character(),
    workflow=character(),event_type=character(),github_run_id=character(),
    zenodo_record_id=character(),details_json=character()),
    ss=sheet_id,sheet="workflow_events")
}
if("review_metadata" %in% missing) {
  sheet_add(sheet_id,sheet="review_metadata")
  sheet_write(data.frame(key=c("review_id","review_status","authoritative_w08_baseline",
    "latest_w08_zenodo_record_id","latest_w00_run_id","latest_w00_status"),
    value=c(review_id,"initialising","FALSE","","",""),
    stringsAsFactors=FALSE),ss=sheet_id,sheet="review_metadata")
}
cat("PASS: review tabs initialised or already valid; no existing content cleared\n")
