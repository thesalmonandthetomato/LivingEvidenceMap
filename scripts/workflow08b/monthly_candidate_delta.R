#!/usr/bin/env Rscript
# Determine newly observed provider-specific citation candidates across monthly
# W08b checkpoints. Never equate Lens IDs to OpenAlex IDs without a crosswalk.
# Usage: monthly_candidate_delta.R current_edges.csv previous_candidates.csv out_dir
a <- commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: monthly_candidate_delta.R current_edges.csv previous_candidates.csv out_dir")
current_path<-a[[1]];previous_path<-a[[2]];out<-a[[3]]
if(!file.exists(current_path)||!file.exists(previous_path))
  stop("Both current edges and a verified previous candidate register are required")
read_table<-function(path,cols){
  d<-read.csv(path,stringsAsFactors=FALSE,check.names=FALSE,na.strings=NULL)
  if(!all(cols%in%names(d)))stop("Missing columns in ",path,": ",paste(setdiff(cols,names(d)),collapse=", "))
  for(k in cols){
    d[[k]]<-trimws(as.character(d[[k]]))
    if(any(is.na(d[[k]])|!nzchar(d[[k]])))stop("Missing ",k," in ",path)
  }
  d
}
edgecols<-c("seed_record_id","provider","related_provider_id","direction")
keycols<-c("provider","related_provider_id")
current<-read_table(current_path,edgecols)
previous<-read_table(previous_path,keycols)
if(any(!current$provider%in%c("lens","openalex"))||
   any(!previous$provider%in%c("lens","openalex")))
  stop("Unexpected citation provider")
if(any(!current$direction%in%c("backward","forward","both")))stop("Invalid citation direction")
# Unit separator avoids collisions between concatenated provider and ID fields.
key<-function(d)paste(d$provider,d$related_provider_id,sep="\037")
if(anyDuplicated(key(previous)))stop("Previous candidate register contains duplicate provider IDs")
current<-unique(current[,edgecols,drop=FALSE])
current_keys<-unique(current[,keycols,drop=FALSE])
old_key<-key(previous)
is_new<-!(key(current_keys)%in%old_key)
new_keys<-current_keys[is_new,,drop=FALSE]
new_edges<-current[key(current)%in%key(new_keys),,drop=FALSE]
combined<-unique(rbind(previous,current_keys))
ord<-function(d)if(nrow(d))d[order(d$provider,d$related_provider_id),,drop=FALSE] else d
dir.create(out,recursive=TRUE,showWarnings=FALSE)
write.csv(ord(new_keys),file.path(out,"new_provider_candidate_ids.csv"),row.names=FALSE,na="")
write.csv(ord(combined),file.path(out,"cumulative_provider_candidate_ids.csv"),row.names=FALSE,na="")
write.csv(new_edges,file.path(out,"new_candidate_citation_edges.csv"),row.names=FALSE,na="")
summary<-list(schema="workflow08b-monthly-candidate-delta-v1",
 historical_provider_candidates=nrow(previous),
 current_provider_candidates=nrow(current_keys),
 new_provider_candidates=nrow(new_keys),
 cumulative_provider_candidates=nrow(combined),
 new_candidate_direction_edges=nrow(new_edges),
 cross_provider_reconciliation_required=TRUE,
 previously_known_candidates_excluded_from_retrieval=TRUE,
 bibliography_retrieval_performed=FALSE)
if(!requireNamespace("jsonlite",quietly=TRUE))stop("jsonlite required")
writeLines(jsonlite::toJSON(summary,auto_unbox=TRUE,pretty=TRUE),
           file.path(out,"summary.json"))
cat("PASS: new provider-specific candidates=",nrow(new_keys),
    " previously observed=",nrow(current_keys)-nrow(new_keys),"\n",sep="")
