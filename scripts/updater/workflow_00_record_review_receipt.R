#!/usr/bin/env Rscript
# Append W00 Zenodo receipt to this review's Google Sheet, without repository writes.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
get <- function(k) {i<-match(k,args);if(is.na(i)||i==length(args)) stop("Missing ",k,call.=FALSE);args[[i+1L]]}
receipt <- fromJSON(get("--receipt"),simplifyVector=FALSE)
sheet_id <- get("--sheet-id")
credential <- get("--credential")
run_id <- get("--run-id")
if(!identical(receipt$status,"published")||!identical(as.character(receipt$github_run_id),run_id)||
   !grepl("^[0-9]+$",as.character(receipt$zenodo_record_id)))
  stop("Zenodo receipt not published or run mismatch",call.=FALSE)
if(!file.exists(credential)) stop("Credential file missing",call.=FALSE)
if(!requireNamespace("googlesheets4",quietly=TRUE)) stop("googlesheets4 missing",call.=FALSE)
googlesheets4::gs4_auth(path=credential,cache=FALSE)
expected_events <- c("event_id","timestamp_utc","review_id","workflow","event_type",
                     "github_run_id","zenodo_record_id","details_json")
metadata <- as.data.frame(googlesheets4::read_sheet(sheet_id,sheet="review_metadata",col_types="cc"))
events <- as.data.frame(googlesheets4::read_sheet(sheet_id,sheet="workflow_events",col_types="cccccccc"))
if(!identical(names(metadata),c("key","value"))||!identical(names(events),expected_events))
  stop("Missing or incompatible review tabs; initialise before W00",call.=FALSE)
if(anyDuplicated(metadata$key)||any(!nzchar(metadata$key))) stop("Invalid review metadata keys",call.=FALSE)
value <- function(k) {i<-match(k,metadata$key);if(is.na(i)) stop("Missing required key: ",k,call.=FALSE);as.character(metadata$value[[i]])}
review_id <- value("review_id")
if(!identical(value("latest_w00_run_id"),run_id))
  stop("Refusing to publish receipt against another or newer W00 run",call.=FALSE)
current_status <- tolower(value("latest_w00_status"))
if(!current_status %in% c("running","in_progress","success"))
  stop("Cannot finalise Zenodo receipt from inactive or failed W00 state",call.=FALSE)
if(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review_id)) stop("Invalid review ID",call.=FALSE)
event_id <- paste0("W00:",run_id,":zenodo_published")
if(event_id %in% events$event_id) {
  old <- events[events$event_id==event_id,,drop=FALSE]
  if(nrow(old)!=1L||!identical(as.character(old$zenodo_record_id[[1]]),as.character(receipt$zenodo_record_id)))
    stop("Conflicting existing event for W00 run",call.=FALSE)
  cat("PASS: previously recorded W00 publication (idempotent)\n")
} else {
  entry <- data.frame(event_id=event_id,
    timestamp_utc=as.character(receipt$published_at_utc),review_id=review_id,
    workflow="W00",event_type="zenodo_published",github_run_id=run_id,
    zenodo_record_id=as.character(receipt$zenodo_record_id),
    details_json=as.character(toJSON(list(doi=receipt$doi,record_url=receipt$record_url,
      manifest_sha256=receipt$manifest_sha256,source_ids=receipt$sources),auto_unbox=TRUE)),
    stringsAsFactors=FALSE)
  googlesheets4::sheet_append(sheet_id,entry,sheet="workflow_events")
}
# Metadata is updated only after the receipt is registered in the append-only log.
updates <- c(latest_w00_run_id=run_id,latest_w00_status="success",
             latest_w00_zenodo_record_id=as.character(receipt$zenodo_record_id))
for(k in names(updates)) {
  idx <- match(k,metadata$key)
  if(is.na(idx)) {
    googlesheets4::sheet_append(sheet_id,data.frame(key=k,value=updates[[k]]),
                                sheet="review_metadata")
  } else {
    googlesheets4::range_write(sheet_id,data.frame(value=updates[[k]]),
      sheet="review_metadata",range=paste0("B",idx+1L),col_names=FALSE)
  }
}
cat("PASS: review-specific W00 Zenodo receipt and event stored\n")
