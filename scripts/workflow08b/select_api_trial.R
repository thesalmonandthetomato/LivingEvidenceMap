#!/usr/bin/env Rscript
# Prepare a bounded, private W08b API trial cohort from the verified W01/W08 crosswalk.
# No API request is made by this script.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
if(length(args)!=2L)stop("Usage: select_api_trial.R <seed_identifier_crosswalk.csv> <output_dir>")
input<-args[[1]];out<-args[[2]]
if(!file.exists(input))stop("Crosswalk not found")
d<-read.csv(input,stringsAsFactors=FALSE,check.names=FALSE,na.strings=NULL)
required<-c("record_id","lens_id","openalex_id","doi","preferred_route","identifier_conflict")
if(!all(required%in%names(d))||anyDuplicated(d$record_id))stop("Invalid crosswalk")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
groups<-c(lens=4L,openalex=3L,lens_doi_lookup=2L,unresolved=1L,identity_conflict=2L)
# Deterministic selection independent of input order; no random sample or accidental bulk requests.
selected<-do.call(rbind,lapply(names(groups),function(g){
 z<-d[d$preferred_route==g,,drop=FALSE]
 if(!nrow(z))return(NULL)
 z<-z[order(z$record_id),,drop=FALSE]
 head(z,groups[[g]])
}))
if(is.null(selected)||!nrow(selected))stop("No candidate records for API preflight")
write.csv(selected,file.path(out,"private_trial_seeds.csv"),row.names=FALSE,quote=TRUE)
summary<-list(schema="workflow08b-api-trial-cohort-v1",total=nrow(selected),
             provider_queries_authorised=FALSE,stages="selection_only",
             source_counts=as.list(table(selected$preferred_route)))
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"trial_summary.json"))
cat("PASS: selected",nrow(selected),"private trial seeds. No provider API requests.\n")
