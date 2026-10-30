#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: prepare_w01_status.R prior_status.json w00_receipt.json latest_w01_pointer.json output.json")
s<-fromJSON(a[[1]],simplifyVector=FALSE)
p<-fromJSON(a[[2]],simplifyVector=FALSE)
w<-fromJSON(a[[3]],simplifyVector=FALSE)
if(!identical(p$status,"published")||!identical(p$run_type,"citation_chasing"))stop("Not a published citation-chasing archive")
if(!identical(w$status,"published")||!w$state%in%c("delta","final"))stop("Not a valid W01 historical pointer")
if(!identical(s$progress$W10$status,"complete"))stop("Prior update is not complete; refuse concurrent update")
n<-c(lens=31449L,openalex=1867L)
# Source-native counts are independently checked from the two reconciliation manifests.
for(src in names(n)){
 path<-file.path("w08b_stage","harvests",src,"source_delta","reconciliation_manifest.json")
 z<-fromJSON(path,simplifyVector=FALSE)
 if(!identical(z$status,"success")||as.integer(z$current_unique_records)!=n[[src]]||
   as.integer(z$new_native_ids)<0L||as.integer(z$new_native_ids)>n[[src]])
   stop("Unreconciled citation source: ",src)
}
s$update_id<-paste0("w08b-citation-run-",p$github_run_id)
s$started_at_utc<-format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")
s$last_updated_at_utc<-s$started_at_utc
s$baseline$workflow01_source_run_id<-as.character(w$github_run_id)
s$baseline$workflow01_pointer<-paste0("docs/deduplication/zenodo/run-",w$github_run_id,".json")
s$search<-list(workflow00_run_id=as.character(p$github_run_id),
 search_date=format(Sys.Date(),"%Y-%m-%d"),search_results=as.integer(sum(n)),
 sources=lapply(n,function(z)list(reported_search_results=as.integer(z),successfully_downloaded_results=as.integer(z))))
# W00 cumulative hits are additive: historical database searches plus raw
# citation-chasing retrievals, before W01 deduplication or provider filtering.
baseline_hits<-as.integer(s$baseline$previous_counts$search_results)
if(length(baseline_hits)!=1L||is.na(baseline_hits)||baseline_hits<0L)
  stop("Missing authoritative baseline W00 search-hit total")
s$counts$search_results<-as.integer(baseline_hits+sum(n))
s$workflow_runs$W00<-as.character(p$github_run_id)
s$workflow_runs$W01<-NULL
for(step in sprintf("W%02d",1:10))s$progress[[step]]$status<-"pending"
s$progress$current_stage<-"W01"
s$progress$completed_through<-1L
s$progress$status_label<-"Citation-chasing supplemental update"
dir.create(dirname(a[[4]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(s,pretty=TRUE,auto_unbox=TRUE,null="null"),a[[4]])
cat("PASS: prepared citation-chasing W01 handoff status using latest published W01 historical state ",w$github_run_id,"\n",sep="")
