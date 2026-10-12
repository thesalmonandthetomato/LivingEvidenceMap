#!/usr/bin/env Rscript
# Controlled integration probe: one labelled synthetic event, no operational metadata updates.
args <- commandArgs(trailingOnly=TRUE)
arg <- function(k) { i<-match(k,args); if(is.na(i)||i==length(args)) stop("Missing ",k,call.=FALSE); args[[i+1L]] }
sheet <- arg("--sheet-id"); cred <- arg("--credential"); review <- arg("--review-id"); run <- arg("--run-id")
if(!identical(review,"almeria-map")||!grepl("^[0-9]+$",run)) stop("Invalid test identity",call.=FALSE)
if(!file.exists(cred)) stop("Credential missing",call.=FALSE)
suppressPackageStartupMessages(library(googlesheets4))
gs4_auth(path=cred,cache=FALSE)
meta <- as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
events <- as.data.frame(read_sheet(sheet,sheet="workflow_events",col_types="cccccccc"))
columns <- c("event_id","timestamp_utc","review_id","workflow","event_type","github_run_id","zenodo_record_id","details_json")
if(!identical(names(meta),c("key","value"))||!identical(names(events),columns))
  stop("Review tab schema mismatch; no writes",call.=FALSE)
if(anyDuplicated(meta$key)||anyDuplicated(events$event_id)) stop("Duplicate keys or events",call.=FALSE)
value <- function(k){i<-match(k,meta$key);if(is.na(i))stop("Missing key ",k,call.=FALSE);as.character(meta$value[[i]])}
if(!identical(value("review_id"),review)) stop("Wrong review spreadsheet",call.=FALSE)
id <- paste0("W00:",run,":integration_test")
if(!id %in% events$event_id){
  event <- data.frame(event_id=id,timestamp_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
    review_id=review,workflow="W00",event_type="integration_test",
    github_run_id=run,zenodo_record_id="",details_json='{"synthetic":true,"purpose":"sheets_read_write_check"}',
    stringsAsFactors=FALSE)
  sheet_append(sheet,event,sheet="workflow_events")
}
after <- as.data.frame(read_sheet(sheet,sheet="workflow_events",col_types="cccccccc"))
row <- after[after$event_id==id,,drop=FALSE]
if(nrow(row)!=1L||!identical(as.character(row$review_id[[1]]),review)||
   !identical(as.character(row$event_type[[1]]),"integration_test"))
  stop("Synthetic event not verified after write",call.=FALSE)
meta_after <- as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
if(!identical(meta,meta_after)) stop("Operational review metadata unexpectedly changed",call.=FALSE)
cat("PASS: review-isolated synthetic event appended and read back; metadata unchanged\n")
