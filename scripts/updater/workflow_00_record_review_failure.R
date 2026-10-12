#!/usr/bin/env Rscript
# Finalise failed Shiny W00 runs without touching repository state.
args<-commandArgs(trailingOnly=TRUE)
# Test routing is explicit; production defaults remain unchanged.
test_tabs <- "--isolated-test-tabs" %in% args
metadata_tab <- if(test_tabs) "w00_test_metadata" else "review_metadata"
events_tab <- if(test_tabs) "w00_test_events" else "workflow_events"

get<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet<-get("--sheet-id");cred<-get("--credential");run<-get("--run-id");review<-get("--review-id")
if(!grepl("^[0-9]+$",run)||!grepl("^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$",review))stop("Invalid identity",call.=FALSE)
if(!file.exists(cred))stop("Missing credential",call.=FALSE)
if(!requireNamespace("googlesheets4",quietly=TRUE))stop("Missing googlesheets4",call.=FALSE)
googlesheets4::gs4_auth(path=cred,cache=FALSE)
meta<-as.data.frame(googlesheets4::read_sheet(sheet,sheet=metadata_tab,col_types="cc"))
events<-as.data.frame(googlesheets4::read_sheet(sheet,sheet=events_tab,col_types="cccccccc"))
expected<-c("event_id","timestamp_utc","review_id","workflow","event_type","github_run_id","zenodo_record_id","details_json")
if(!identical(names(meta),c("key","value"))||!identical(names(events),expected))stop("Unexpected tab schema",call.=FALSE)
if(anyDuplicated(meta$key)||anyDuplicated(events$event_id))stop("Duplicate metadata",call.=FALSE)
lookup<-function(k){i<-match(k,meta$key);if(is.na(i))stop("Missing ",k,call.=FALSE);as.character(meta$value[[i]])}
source("scripts/updater/workflow_00_review_transition_rules.R")
decision<-w00_review_transition(meta,events,review,run,"failure")
if(decision$status!="failed")stop("Unexpected transition",call.=FALSE)
if(!identical(lookup("latest_w00_run_id"),run))stop("Refusing to overwrite newer or unrelated W00 state",call.=FALSE)
if(identical(tolower(lookup("latest_w00_status")),"success"))stop("Refusing to turn published W00 success into failure",call.=FALSE)
event_id<-paste0("W00:",run,":failed")
if(!event_id %in% events$event_id){
  row<-data.frame(event_id=event_id,timestamp_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
    review_id=review,workflow="W00",event_type="failed",github_run_id=run,
    zenodo_record_id="",details_json="{}",stringsAsFactors=FALSE)
  googlesheets4::sheet_append(sheet,row,sheet=events_tab)
}
idx<-match("latest_w00_status",meta$key)
googlesheets4::range_write(sheet,data.frame(value="failed"),sheet=metadata_tab,
  range=paste0("B",idx+1L),col_names=FALSE)
cat("PASS: review W00 failure recorded\n")
