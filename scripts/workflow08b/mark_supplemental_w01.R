#!/usr/bin/env Rscript
# Bind the automatically published supplementary W01 pointer to its original
# W08b generation before dispatching W02; never infer provenance from filename order.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: mark_supplemental_w01.R current_status.json routing_state.json new_w01_run_id")
status<-fromJSON(a[[1]],simplifyVector=FALSE)
if(!file.exists(a[[2]]))stop("No original W08b generation state")
state<-fromJSON(a[[2]],simplifyVector=FALSE)
id<-as.character(a[[3]])
if(!grepl("^[0-9]+$",id))stop("Invalid new W01 run ID")
update<-as.character(status$update_id)
month<-substr(as.character(status$search$search_date),1L,7L)
if(!identical(as.character(state$update_id),update)||
   !identical(as.character(state$update_month),month)||
   !identical(as.character(status$workflow_runs$W08),as.character(state$original_w08_run_id))||
   !identical(as.character(status$workflow_runs$W01),id))
  stop("Supplemental W01 provenance does not match original update state")
w01pointer<-file.path("docs/deduplication/zenodo",paste0("run-",id,".json"))
if(!file.exists(w01pointer)||!identical(fromJSON(w01pointer)$status,"published"))
  stop("New W01 pointer must be published before marker transition")
release<-list(update_id=update,update_month=month,
  w08_run_id=as.character(state$original_w08_run_id),
  w08_canonical_sha256=as.character(state$original_w08_sha256),
  w01_run_id=id)
temp<-tempfile(fileext=".json");on.exit(unlink(temp))
writeLines(toJSON(release,auto_unbox=TRUE),temp)
result<-system2("Rscript",c("scripts/workflow08b/record_routing_event.R",
  "supplemental_w01_started",shQuote(temp),shQuote(a[[2]]),id))
if(result!=0L)stop("Failed supplemental W01 generation handoff")
cat("PASS: verified supplemental W01 belongs to the original W08b generation\n")
