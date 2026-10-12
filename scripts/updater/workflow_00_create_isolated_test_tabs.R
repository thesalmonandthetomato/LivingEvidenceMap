#!/usr/bin/env Rscript
# Isolated W00 testing: never modify operational tabs.
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet<-arg("--sheet-id");credential<-arg("--credential");review<-arg("--review-id")
if(review!="almeria-map"||!file.exists(credential))stop("Review or credentials invalid",call.=FALSE)
suppressPackageStartupMessages(library(googlesheets4))
gs4_auth(path=credential,cache=FALSE)
tabs<-sheet_names(sheet)
if(!all(c("review_metadata","workflow_events")%in%tabs))stop("Operational tabs missing",call.=FALSE)
live<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
if(!identical(as.character(live$value[match("review_id",live$key)]),review))stop("Review mismatch",call.=FALSE)
test<-c("w00_test_metadata","w00_test_events")
if(any(test%in%tabs))stop("Test tabs already exist; refusing to reset",call.=FALSE)
sheet_add(sheet,sheet=test[[1]])
sheet_write(data.frame(key=c("review_id","latest_w00_run_id","latest_w00_status"),
  value=c(review,"",""),stringsAsFactors=FALSE),ss=sheet,sheet=test[[1]])
sheet_add(sheet,sheet=test[[2]])
sheet_write(data.frame(event_id=character(),timestamp_utc=character(),review_id=character(),
workflow=character(),event_type=character(),github_run_id=character(),
zenodo_record_id=character(),details_json=character()),ss=sheet,sheet=test[[2]])
cat("PASS: isolated W00 test tabs created without editing operational tabs\n")
