#!/usr/bin/env Rscript
# Register a completed provider-discovery checkpoint for the next monthly run.
# Never mutate a previous month's accepted checkpoint or overwrite an unrelated
# checkpoint for the same month. Output written to a separate file for review.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=9L)stop("Usage: register_monthly_checkpoint.R registry.json month zenodo_id archive_sha256 candidates edges original_w08_run original_w08_sha256 output.json")
x<-fromJSON(a[[1]],simplifyVector=FALSE)
month<-a[[2]];id<-a[[3]];archive_sha<-tolower(a[[4]])
candidates<-suppressWarnings(as.integer(a[[5]]))
edges<-suppressWarnings(as.integer(a[[6]]))
w08run<-a[[7]];w08sha<-tolower(a[[8]])
if(!identical(x$schema,"workflow08b-monthly-checkpoint-registry-v1")||
 !grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month)||
 !grepl("^[0-9]+$",id)||!grepl("^[0-9]+$",w08run)||
 !grepl("^[a-f0-9]{64}$",archive_sha)||!grepl("^[a-f0-9]{64}$",w08sha)||
 anyNA(c(candidates,edges))||candidates<0||edges<0)
 stop("Invalid monthly checkpoint acceptance evidence")
previous<-format(as.Date(paste0(month,"-01"))-1L,"%Y-%m")
rows<-Filter(function(z)identical(as.character(z$month),previous),x$checkpoints)
if(length(rows)!=1L||!identical(rows[[1]]$status,"verified_archive"))
 stop("Cannot register a monthly checkpoint without the preceding accepted month")
existing<-Filter(function(z)identical(as.character(z$month),month),x$checkpoints)
if(length(existing)>1L)stop("Duplicate monthly registry entries")
if(length(existing)==1L) {
 z<-existing[[1]]
 if(!identical(as.character(z$discovery_zenodo_record_id),id)||
    !identical(tolower(as.character(z$discovery_archive_sha256)),archive_sha)||
    as.integer(z$provider_candidate_ids)!=candidates||
    as.integer(z$direction_edges)!=edges)
    stop("Conflicting checkpoint for this month; manual reconciliation required")
 cat("PASS: accepted same monthly checkpoint idempotently\n")
}else{
 x$checkpoints[[length(x$checkpoints)+1L]]<-list(
   month=month,discovery_zenodo_record_id=id,
   discovery_archive_sha256=archive_sha,
   archive_inventory_run_id=Sys.getenv("GITHUB_RUN_ID","0"),
   status="verified_archive",direction_edges=edges,
   provider_candidate_ids=candidates,
   post_chasing_w08_source_run_id="",
   post_chasing_w08_sha256="",
   original_w08_source_run_id=w08run,
   original_w08_sha256=w08sha,
   note="Complete discovery checkpoint. Final W08 SHA is added after supplemental publication.")
 x$latest_completed_month<-month
 cat("PASS: registered completed discovery checkpoint for ",month,"\n",sep="")
}
dir.create(dirname(a[[9]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(x,auto_unbox=TRUE,pretty=TRUE,null="null"),a[[9]])
