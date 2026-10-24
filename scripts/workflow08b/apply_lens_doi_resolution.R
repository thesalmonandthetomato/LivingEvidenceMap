#!/usr/bin/env Rscript
# Merge checkpointed Lens DOI resolutions back onto full verified W08/W01 crosswalk.
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: apply_lens_doi_resolution.R full_crosswalk.csv doi_journal.jsonl output.csv")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
if(anyDuplicated(d$record_id))stop("Duplicate W08 seed")
journal<-list()
if(file.exists(a[[2]]))for(line in readLines(a[[2]],warn=FALSE)){
 if(!nzchar(line))next
 z<-fromJSON(line,simplifyVector=FALSE);journal[[as.character(z$record_id)]]<-z
}
for(i in seq_len(nrow(d))){
 if(d$preferred_route[[i]]!="lens_doi_lookup"||d$identifier_conflict[[i]])next
 z<-journal[[d$record_id[[i]]]]
 if(is.null(z))next
 if(identical(z$status,"resolved")){
  if(!nzchar(as.character(z$lens_id)))stop("Empty resolved Lens ID")
  d$lens_id[[i]]<-as.character(z$lens_id)
  d$preferred_route[[i]]<-"lens"
 }else if(identical(z$status,"not_found")&&nzchar(d$openalex_id[[i]])){
  d$preferred_route[[i]]<-"openalex"
 }else if(identical(z$status,"ambiguous"))d$preferred_route[[i]]<-"identity_conflict"
}
if(anyDuplicated(d$record_id))stop("Identity mutation")
write.csv(d,a[[3]],row.names=FALSE)
cat("PASS: applied Lens DOI resolution to full verified seed crosswalk\n")
