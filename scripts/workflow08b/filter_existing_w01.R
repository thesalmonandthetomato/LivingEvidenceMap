#!/usr/bin/env Rscript
# Offline historical W01 identity guard for W08b Lens candidates.
# All W01 canonical records are scanned, NOT only W08 included records.
# Usage: Rscript scripts/workflow08b/filter_existing_w01.R <w01/canonical/records.jsonl> <provider_candidate_ids.csv> <output-dir>
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: filter_existing_w01.R w01.jsonl provider_candidate_ids.csv output-dir")
if(!file.exists(a[[1]])||!file.exists(a[[2]]))stop("Missing verified W01 state or candidate register")
out<-a[[3]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
candidates<-read.csv(a[[2]],stringsAsFactors=FALSE,na.strings=NULL)
if(!all(c("provider","related_provider_id")%in%names(candidates)))stop("Invalid candidate register")
if(anyDuplicated(candidates[c("provider","related_provider_id")]))stop("Candidate register contains duplicates")
if(any(!candidates$provider%in%c("lens","openalex")))stop("Unsupported source provider")
scalar<-function(x){z<-unlist(x,use.names=FALSE);if(!length(z))return("");v<-as.character(z[[1L]]);if(is.na(v))"" else trimws(v)}
norm_doi<-function(x){v<-tolower(scalar(x));v<-sub("^https?://(dx[.])?doi[.]org/","",v);sub("^doi:[[:space:]]*","",v)}
norm_oa<-function(x){v<-toupper(sub("^https?://openalex[.]org/","",scalar(x),ignore.case=TRUE));if(grepl("^W[0-9]+$",v))v else ""}
# Only compare identifiers that are actually present in the authoritative source.
lens_owner<-new.env(hash=TRUE,parent=emptyenv())
oa_owner<-new.env(hash=TRUE,parent=emptyenv())
doi_owner<-new.env(hash=TRUE,parent=emptyenv())
put<-function(env,key,owner){
 if(!nzchar(key))return()
 if(exists(key,envir=env,inherits=FALSE)&&
    !identical(get(key,envir=env,inherits=FALSE),owner))
   stop("Historical W01 identifier collision: ",key)
 assign(key,owner,envir=env)
}
con<-file(a[[1]],"rt");on.exit(close(con),add=TRUE)
n<-0L
repeat{
 lines<-readLines(con,n=500L,warn=FALSE)
 if(!length(lines))break
 for(line in lines){
  if(!nzchar(line))next
  z<-fromJSON(line,simplifyVector=FALSE)
  id<-scalar(z$identity$record_id);if(!nzchar(id))stop("W01 canonical record lacks identity")
  n<-n+1L
  put(doi_owner,norm_doi(z$canonical$doi),id)
  for(m in (z$manifestations %||% list())){
   src<-scalar(m$source);mid<-m$manifestation_metadata
   put(doi_owner,norm_doi(m$doi),id)
   if(src=="lens"){
    put(lens_owner,scalar(mid$source_identity$lens_id),id)
    put(lens_owner,scalar(m$source_record_id),id)
   }
   if(src=="openalex"){
    put(oa_owner,norm_oa(mid$source_identity$openalex_id),id)
    put(oa_owner,norm_oa(m$source_record_id),id)
   }
   put(oa_owner,norm_oa(mid$identifiers$openalex_id),id)
  }
 }
}
`%||%`<-function(x,y)if(is.null(x))y else x
get_owner<-function(env,key)if(nzchar(key)&&exists(key,envir=env,inherits=FALSE))get(key,envir=env,inherits=FALSE)else ""
candidates$existing_w01_record_id<-vapply(seq_len(nrow(candidates)),function(i){
 p<-candidates$provider[[i]];k<-candidates$related_provider_id[[i]]
 if(p=="lens")get_owner(lens_owner,k)else get_owner(oa_owner,norm_oa(k))
},character(1))
candidates$identity_status<-ifelse(nzchar(candidates$existing_w01_record_id),"already_in_w01","needs_bibliographic_identity_check")
write.csv(candidates,file.path(out,"candidate_identity_precheck.csv"),row.names=FALSE)
write.csv(candidates[!nzchar(candidates$existing_w01_record_id),,drop=FALSE],
 file.path(out,"candidates_not_matched_by_provider_id.csv"),row.names=FALSE)
info<-list(schema="workflow08b-w01-provider-id-precheck-v1",
 historical_w01_canonical=n,provider_candidates=nrow(candidates),
 matched_existing_w01=sum(candidates$identity_status=="already_in_w01"),
 requires_metadata_and_doi_check=sum(candidates$identity_status=="needs_bibliographic_identity_check"),
 w01_handoff_authorised=FALSE)
writeLines(toJSON(info,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: screened ",nrow(candidates)," provider candidates against ",n," historical W01 works; identity precheck only\n",sep="")
