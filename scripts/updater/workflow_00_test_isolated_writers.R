#!/usr/bin/env Rscript
# Run state writers against isolated tabs only. Synthetic Zenodo receipt: never publish.
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop("Missing ",k,call.=FALSE);args[[i+1L]]}
sheet<-arg("--sheet-id");cred<-arg("--credential");review<-arg("--review-id");run<-arg("--run-id")
if(review!="almeria-map"||!grepl("^[0-9]+$",run))stop("Invalid test identity",call.=FALSE)
suppressPackageStartupMessages(library(googlesheets4))
gs4_auth(path=cred,cache=FALSE)
before<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
call_writer<-function(name,extra=character()){
  cmd<-c(paste0("scripts/updater/workflow_00_record_review_",name,".R"),
    "--sheet-id",sheet,"--credential",cred,"--run-id",run,
    if(name!="receipt")c("--review-id",review),extra,"--isolated-test-tabs")
  out<-system2("Rscript",cmd,stdout=TRUE,stderr=TRUE)
  if(!is.null(attr(out,"status"))&&attr(out,"status")!=0L)stop(paste(out,collapse="\n"),call.=FALSE)
}
call_writer("start")
m<-as.data.frame(read_sheet(sheet,sheet="w00_test_metadata",col_types="cc"))
stopifnot(identical(as.character(m$value[match("latest_w00_status",m$key)]),"running"))
tmp<-tempfile(fileext=".json")
jsonlite::write_json(list(status="published",github_run_id=run,zenodo_record_id="123456789",
  published_at_utc="2026-10-12T00:00:00Z",doi="10.5281/zenodo.123456789",
  record_url="https://zenodo.org/records/123456789",manifest_sha256="synthetic",sources=list("test")),
  tmp,auto_unbox=TRUE)
# No real Zenodo operation: this fixture only verifies Sheet transitions.
call_writer("receipt",c("--receipt",tmp))
m<-as.data.frame(read_sheet(sheet,sheet="w00_test_metadata",col_types="cc"))
stopifnot(identical(as.character(m$value[match("latest_w00_status",m$key)]),"success"))
e<-as.data.frame(read_sheet(sheet,sheet="w00_test_events",col_types="cccccccc"))
stopifnot(all(c(paste0("W00:",run,":started"),paste0("W00:",run,":zenodo_published"))%in%e$event_id))
after<-as.data.frame(read_sheet(sheet,sheet="review_metadata",col_types="cc"))
stopifnot(identical(before,after))
cat("PASS: real Sheet start/publication writers operate only on test tabs\n")
