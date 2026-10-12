#!/usr/bin/env Rscript
# Review-scoped W00 start state; never reads or modifies repository current-run files.
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k) {i<-match(k,args);if(is.na(i)||i==length(args)) stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet <- arg("--sheet-id")
credential <- arg("--credential")
run_id <- arg("--run-id")
review <- arg("--review-id")
if(!grepl("^[0-9]+$",run_id)||!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review))
  stop("Invalid run or review identity",call.=FALSE)
if(!file.exists(credential)) stop("Credential not found",call.=FALSE)
if(!requireNamespace("googlesheets4",quietly=TRUE)) stop("googlesheets4 unavailable",call.=FALSE)
googlesheets4::gs4_auth(path=credential,cache=FALSE)
meta <- as.data.frame(googlesheets4::read_sheet(sheet,sheet="review_metadata",col_types="cc"))
events <- as.data.frame(googlesheets4::read_sheet(sheet,sheet="workflow_events",col_types="cccccccc"))
cols <- c("event_id","timestamp_utc","review_id","workflow","event_type","github_run_id","zenodo_record_id","details_json")
if(!identical(names(meta),c("key","value"))||!identical(names(events),cols))
  stop("Review metadata/events schema mismatch",call.=FALSE)
if(anyDuplicated(meta$key)||anyDuplicated(events$event_id)) stop("Duplicate review keys/events",call.=FALSE)
key <- function(k) {i<-match(k,meta$key);if(is.na(i)) stop("Missing metadata key ",k,call.=FALSE);as.character(meta$value[[i]])}
if(!identical(key("review_id"),review)) stop("Review ID mismatch",call.=FALSE)
old_run <- key("latest_w00_run_id")
old_status <- tolower(key("latest_w00_status"))
if(old_status %in% c("queued","pending","running","in_progress") && nzchar(old_run) && old_run!=run_id)
  stop("Another review W00 run is active",call.=FALSE)
event <- paste0("W00:",run_id,":started")
if(!event %in% events$event_id) {
  row <- data.frame(event_id=event,timestamp_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
    review_id=review,workflow="W00",event_type="started",github_run_id=run_id,
    zenodo_record_id="",details_json="{}",stringsAsFactors=FALSE)
  googlesheets4::sheet_append(sheet,row,sheet="workflow_events")
}
for(k in c("latest_w00_run_id","latest_w00_status")) {
  idx<-match(k,meta$key)
  val<-if(k=="latest_w00_run_id")run_id else "running"
  if(is.na(idx)) stop("Missing required key ",k,call.=FALSE)
  googlesheets4::range_write(sheet,data.frame(value=val),sheet="review_metadata",
    range=paste0("B",idx+1L),col_names=FALSE)
}
cat("PASS: review-specific W00 start event and running status recorded\n")
