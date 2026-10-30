#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=4L)stop("Usage: prepare_w01_status.R prior_status.json w00_receipt.json latest_w01_pointer.json output.json")
s<-fromJSON(a[[1]],simplifyVector=FALSE)
p<-fromJSON(a[[2]],simplifyVector=FALSE)
w<-fromJSON(a[[3]],simplifyVector=FALSE)
if(!identical(p$status,"published")||!identical(p$run_type,"citation_chasing"))stop("Not a published citation-chasing archive")
if(!identical(w$status,"published")||!w$state%in%c("delta","final"))stop("Not a valid W01 historical pointer")
if(!identical(s$progress$W10$status,"complete"))stop("Prior update is not complete; refuse concurrent update")
# Read actual campaign provider counts; never fix monthly numbers in code.
source_dirs<-list.dirs(file.path("w08b_stage","harvests"),recursive=FALSE,full.names=TRUE)
n<-integer()
for(root in source_dirs){
 src<-basename(root)
 path<-file.path(root,"source_delta","reconciliation_manifest.json")
 if(!file.exists(path))next
 z<-fromJSON(path,simplifyVector=FALSE)
 if(!identical(z$status,"success"))stop("Unreconciled citation source: ",src)
 count<-as.integer(z$current_raw_records %||% z$current_unique_records)
 fresh<-as.integer(z$new_native_ids)
 if(length(count)!=1L||is.na(count)||count<0L||length(fresh)!=1L||
    is.na(fresh)||fresh<0L||fresh>count)stop("Invalid citation source count: ",src)
 if(count>0L)n[src]<-count
}
if(!length(n))stop("No positive citation-chasing source counts")
# The last completed W09 figure is the reconciled baseline, including
# any database acquisitions that followed the earlier release snapshot.
flow_path<-"docs/reporting/workflow_09/flow_counts.json"
flow<-fromJSON(flow_path,simplifyVector=FALSE)
if(!identical(as.character(flow$source_runs$W01),as.character(w$github_run_id)))
 stop("Historical W09 baseline is not tied to the selected W01 archive")
baseline_hits<-as.integer(flow$counts$combined_search_results)
source_rows<-flow$counts$source_searches
prior_cc<-sum(vapply(source_rows,function(z)if(identical(as.character(z$code),"citation_chasing"))as.integer(z$hits) else 0L,integer(1)))
source_rows<-Filter(function(z)!identical(as.character(z$code),"citation_chasing"),source_rows)
if(length(baseline_hits)!=1L||is.na(baseline_hits)||baseline_hits<0L||
   !length(source_rows))stop("Historical W09 source counts missing")
raw<-data.frame(
 source_code=vapply(source_rows,function(z)as.character(z$code),character(1)),
 hits=vapply(source_rows,function(z)as.integer(z$hits),integer(1)),
 stringsAsFactors=FALSE)
if(anyDuplicated(raw$source_code)||anyNA(raw$hits)||
   sum(raw$hits)+prior_cc!=baseline_hits)stop("Historical database source counts do not reconcile")
out_sources<-"docs/reporting/workflow_09_inputs/current/w00_database_search_hits.csv"
dir.create(dirname(out_sources),recursive=TRUE,showWarnings=FALSE)
write.csv(raw,out_sources,row.names=FALSE,quote=TRUE)
s$baseline$previous_counts$search_results<-baseline_hits
s$search$database_search_results<-sum(raw$hits)
s$update_id<-paste0("w08b-citation-run-",p$github_run_id)
s$started_at_utc<-format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")
s$last_updated_at_utc<-s$started_at_utc
s$baseline$workflow01_source_run_id<-as.character(w$github_run_id)
s$baseline$workflow01_pointer<-paste0("docs/deduplication/zenodo/run-",w$github_run_id,".json")
s$search<-list(workflow00_run_id=as.character(p$github_run_id),
 search_date=format(Sys.Date(),"%Y-%m-%d"),search_results=as.integer(sum(n)),
 sources=lapply(n,function(z)list(reported_search_results=as.integer(z),successfully_downloaded_results=as.integer(z))),
 database_search_results=as.integer(sum(raw$hits)),
 citation_chasing_total_results=as.integer(prior_cc+sum(n)))
# W00 cumulative hits are additive: historical database searches plus raw
# citation-chasing retrievals, before W01 deduplication or provider filtering.
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
