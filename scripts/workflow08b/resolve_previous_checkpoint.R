#!/usr/bin/env Rscript
# W08b: select exactly the previous completed monthly checkpoint, read-only.
# Usage: Rscript resolve_previous_checkpoint.R registry.json target_YYYY-MM output.json
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: resolve_previous_checkpoint.R registry.json YYYY-MM output.json")
registry<-a[[1L]];month<-a[[2L]];output<-a[[3L]]
if(!file.exists(registry)||!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month))stop("Invalid input")
target<-as.Date(paste0(month,"-01"))
previous<-format(target-1L,"%Y-%m")
x<-fromJSON(registry,simplifyVector=FALSE)
if(!identical(x$schema,"workflow08b-monthly-checkpoint-registry-v1"))stop("Invalid checkpoint registry schema")
rows<-Filter(function(z)identical(as.character(z$month),previous),x$checkpoints)
if(length(rows)!=1L)stop("Expected exactly one previous-month checkpoint for ",previous)
z<-rows[[1L]]
if(!identical(as.character(z$status),"verified_archive"))stop("Previous checkpoint not accepted")
id<-as.character(z$discovery_zenodo_record_id)
if(!grepl("^[0-9]+$",id))stop("Invalid previous checkpoint Zenodo ID")
if(as.integer(z$provider_candidate_ids)<0L||as.integer(z$direction_edges)<0L)stop("Missing candidate/edge counts")
result<-list(schema="workflow08b-previous-checkpoint-selection-v1",
 target_month=month,previous_month=previous,zenodo_record_id=id,
 inventory_run_id=as.character(z$archive_inventory_run_id),
 previous_provider_candidates=as.integer(z$provider_candidate_ids),
 previous_direction_edges=as.integer(z$direction_edges),
 previous_w08_sha256=as.character(z$post_chasing_w08_sha256),
 provider_calls_authorised=FALSE,archive_integrity_check_required=TRUE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE,null="null"),output)
cat("PASS: selected ",previous," W08b checkpoint ",id," for ",month,"\n",sep="")
