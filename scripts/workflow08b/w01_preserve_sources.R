#!/usr/bin/env Rscript
# W08b-only historical-source coverage adapter: zero new records for untouched W00 sources.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=5L)stop("Usage: w01_preserve_sources.R prior_w00_pointer.json current_status.json stage_dir output_status.json source_list.txt")
p<-fromJSON(a[[1]],simplifyVector=FALSE)
s<-fromJSON(a[[2]],simplifyVector=FALSE)
if(!identical(p$status,"published")||!identical(p$visibility,"restricted"))stop("Not a published prior W00 archive")
if(!identical(s$progress$current_stage,"W01")||!grepl("^w08b-citation-run-",s$update_id))stop("Not a W08b W01 pending status")
sources<-unique(as.character(unlist(p$sources,use.names=FALSE)))
if(!all(c("lens","openalex")%in%sources))stop("Historical source set must contain both providers")
if(anyDuplicated(sources)||any(!grepl("^[a-z0-9][a-z0-9_-]*$",sources)))stop("Invalid historical sources")
stage<-a[[3]]
for(src in setdiff(sources,c("lens","openalex"))){
 root<-file.path(stage,"harvests",src,"source_delta")
 dir.create(file.path(root,"filtered_source"),recursive=TRUE,showWarnings=FALSE)
 file.create(file.path(root,"filtered_source","records.jsonl"))
 manifest<-list(workflow="00_native_id_reconciliation",status="success",
  source=src,run_type="citation_chasing",current_raw_records=0L,current_unique_records=0L,
  historical_unique_native_ids=NA,already_known_native_ids=0L,new_native_ids=0L,
  records_passed_downstream=0L,bibliographic_deduplication_performed=FALSE,
  downstream_deduplication="Workflow 01")
 writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
  file.path(root,"reconciliation_manifest.json"))
 s$search$sources[[src]]<-list(reported_search_results=0L,successfully_downloaded_results=0L)
}
if(!all(names(s$search$sources)%in%sources))stop("Unexpected source in current status")
writeLines(toJSON(s,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),a[[4]])
writeLines(paste(sources,collapse=","),a[[5]])
cat("PASS: included ",length(sources)," W00 sources (",length(sources)-2L,
 " unchanged historical sources); W08b Lens/OpenAlex deltas unchanged\n",sep="")
