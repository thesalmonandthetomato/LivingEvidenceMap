#!/usr/bin/env Rscript
# W08b: join provider-ID precheck, Lens bibliography, and registered strategy
# filter. No screening handoff while missing metadata or duplicate DOIs remain.
suppressPackageStartupMessages(library(jsonlite))
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<4L||length(a)>5L)stop("Usage: reconcile_lens_candidates.R precheck.csv metadata.jsonl strategy.csv output_dir [historical_doi_index.csv]")
p<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
f<-read.csv(a[[3]],stringsAsFactors=FALSE,na.strings=NULL)
if(!all(c("provider","related_provider_id","existing_w01_record_id")%in%names(p)))stop("Invalid W01 precheck")
if(!all(c("candidate_key","status")%in%names(f)))stop("Invalid strategy classification")
dir.create(a[[4]],recursive=TRUE,showWarnings=FALSE)
meta<-list()
for(line in readLines(a[[2]],warn=FALSE)){
 if(!nzchar(line))next
 z<-fromJSON(line,simplifyVector=FALSE)
 id<-as.character(z$candidate_key)
 meta[[id]]<-z
}
normdoi<-function(x){
 if(is.null(x))return("")
 v<-tolower(trimws(as.character(x)));v<-sub("^https?://(dx[.])?doi[.]org/","",v)
 sub("^doi:[[:space:]]*","",v)
}
lookup<-setNames(f$status,f$candidate_key)
rows<-lapply(seq_len(nrow(p)),function(i){
 z<-p[i,,drop=FALSE];id<-paste0(z$provider[[1]],":",z$related_provider_id[[1]])
 m<-meta[[id]]
 known<-nzchar(z$existing_w01_record_id[[1]])
 doi<-if(is.null(m))"" else normdoi(m$doi)
 filter_status<-lookup[[id]] %||% "metadata_unavailable"
 state<-if(known)"already_in_w01_provider_id" else
  if(is.null(m))"metadata_unavailable" else
  if(!nzchar(doi))"doi_missing_require_further_identity_check" else
  if(filter_status=="original_strategy_match")"original_search_match" else
  if(filter_status=="metadata_incomplete")"metadata_incomplete" else
  if(filter_status=="not_matched")"pending_doi_crosscheck" else "unresolved"
 data.frame(candidate_key=id,provider=z$provider[[1]],provider_id=z$related_provider_id[[1]],
 doi=doi,known_w01_id=z$existing_w01_record_id[[1]],strategy_status=filter_status,
 reconciliation_status=state,stringsAsFactors=FALSE)
})
d<-if(length(rows))do.call(rbind,rows)else data.frame()
# Never choose one record arbitrarily when distinct Lens IDs share a DOI.
if(nrow(d)){
 collide<-nzchar(d$doi)&(duplicated(d$doi)|duplicated(d$doi,fromLast=TRUE))
 d$reconciliation_status[collide & d$reconciliation_status=="pending_doi_crosscheck"]<-"doi_identity_collision"
}
if(length(a)==5L){
 history<-read.csv(a[[5]],stringsAsFactors=FALSE,na.strings=NULL)
 if(anyDuplicated(history$doi))stop("Historical DOI index not unique")
 matched<-match(d$doi,history$doi)
 found<-!is.na(matched)&nzchar(d$doi)
 d$historical_doi_status<-ifelse(found,history$identity_status[matched],"not_found")
 d$historical_doi_w01_ids<-ifelse(found,history$w01_record_ids[matched],"")
 d$reconciliation_status[found & d$reconciliation_status=="pending_doi_crosscheck" &
  history$identity_status[matched]=="unique_historical_w01"]<-"already_in_w01_doi"
 d$reconciliation_status[found & d$reconciliation_status=="pending_doi_crosscheck" &
  history$identity_status[matched]=="ambiguous_historical_w01"]<-"historical_doi_ambiguous"
 d$reconciliation_status[!found & d$reconciliation_status=="pending_doi_crosscheck"]<-"new_doi_requires_other_identity_checks"
}
write.csv(d,file.path(a[[4]],"reconciliation.csv"),row.names=FALSE)
summary<-list(schema="workflow08b-reconciliation-v1",candidates=nrow(d),
 statuses=as.list(table(d$reconciliation_status)),historical_doi_verified=length(a)==5L,
 candidate_handoff_authorised=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(a[[4]],"summary.json"))
cat("PASS: candidate reconciliation staged; no premature W01 handoff\n")
