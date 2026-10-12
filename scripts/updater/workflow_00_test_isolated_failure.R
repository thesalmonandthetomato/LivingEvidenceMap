#!/usr/bin/env Rscript
# Isolated test: failure event and stale run rejection, no live review state changes.
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet<-arg("--sheet-id");cred<-arg("--credential");review<-arg("--review-id");run<-arg("--run-id")
if(review!="almeria-map"||!grepl("^[0-9]+$",run))stop("Invalid identity",call.=FALSE)
suppressPackageStartupMessages(library(googlesheets4))
gs4_auth(path=cred,cache=FALSE)
operational<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
meta<-as.data.frame(read_sheet(sheet,sheet="w00_test_metadata",col_types="cc"))
events<-as.data.frame(read_sheet(sheet,sheet="w00_test_events",col_types="cccccccc"))
if(!identical(as.character(meta$value[match("review_id",meta$key)]),review))stop("Wrong test review",call.=FALSE)
# Prior synthetic success must remain protected.
prior_id<-as.character(meta$value[match("latest_w00_run_id",meta$key)])
prior_status<-as.character(meta$value[match("latest_w00_status",meta$key)])
if(prior_status!="success"||!grepl("^[0-9]+$",prior_id))stop("Expected earlier successful test",call.=FALSE)
invoke<-function(writer,id,expected_success=TRUE,additional=character()){
  args<-c(paste0("scripts/updater/workflow_00_record_review_",writer,".R"),
    "--sheet-id",sheet,"--credential",cred,"--run-id",id,
    if(writer!="receipt")c("--review-id",review),additional,"--isolated-test-tabs")
  out<-suppressWarnings(system2("Rscript",args,stdout=TRUE,stderr=TRUE))
  passed<-is.null(attr(out,"status"))||identical(as.integer(attr(out,"status")),0L)
  if(!identical(passed,expected_success))stop(paste(c("Unexpected writer outcome",out),collapse="\n"),call.=FALSE)
}
invoke("failure",prior_id,FALSE)
invoke("start",run)
invoke("failure",prior_id,FALSE)
invoke("failure",run)
meta2<-as.data.frame(read_sheet(sheet,sheet="w00_test_metadata",col_types="cc"))
stopifnot(identical(as.character(meta2$value[match("latest_w00_status",meta2$key)]),"failed"))
invoke("start",run)
# Starting the same failed run can currently restart: classify explicitly below.
meta3<-as.data.frame(read_sheet(sheet,sheet="w00_test_metadata",col_types="cc"))
stopifnot(as.character(meta3$value[match("latest_w00_status",meta3$key)])=="running")
invoke("failure",run)
events2<-as.data.frame(read_sheet(sheet,sheet="w00_test_events",col_types="cccccccc"))
stopifnot(sum(events2$event_id==paste0("W00:",run,":failed"))==1L)
after<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
stopifnot(identical(operational,after))
cat("PASS: isolated failure writer, stale-run rejection and idempotent events\n")
