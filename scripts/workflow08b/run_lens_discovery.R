#!/usr/bin/env Rscript
# W08b Lens-first citation discovery. Isolated manual runner, no W01 or Zenodo writes.
# Usage: Rscript scripts/workflow08b/run_lens_discovery.R crosswalk.csv output_dir [max_requests]
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
args<-commandArgs(trailingOnly=TRUE)
if(length(args)<2L||length(args)>3L)stop("Usage: run_lens_discovery.R crosswalk.csv output_dir [max_requests]")
input<-args[[1L]];out<-args[[2L]]
limit<-if(length(args)==3L)as.integer(args[[3L]])else 10L
if(is.na(limit)||limit<1L||limit>100L)stop("max_requests must be 1..100 for isolated development")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("LENS_API_TOKEN absent")
d<-read.csv(input,stringsAsFactors=FALSE,na.strings=NULL)
reqcols<-c("record_id","lens_id","doi","preferred_route","identifier_conflict")
if(!all(reqcols%in%names(d))||anyDuplicated(d$record_id))stop("Invalid seed register")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
# Preserve all previously accepted edges across monthly calls. Checkpoints are
# append-only; retries of incomplete seeds never mark the work as completed.
ledger<-file.path(out,"lens_seed_status.jsonl")
edgefile<-file.path(out,"lens_edges_input.jsonl")
existing<-list()
if(file.exists(ledger)){
 for(l in readLines(ledger,warn=FALSE)){if(!nzchar(l))next
  x<-fromJSON(l,simplifyVector=FALSE);existing[[as.character(x$record_id)]]<-x}
}
s<-d[d$preferred_route=="lens" & !d$identifier_conflict & nzchar(d$lens_id),,drop=FALSE]
s<-s[order(s$record_id),,drop=FALSE]
selected<-0L
now<-function()format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
get_ids<-function(xs){
 if(is.null(xs))return(character())
 z<-vapply(xs,function(x){
   if(is.list(x)&&!is.null(x$lens_id))return(as.character(x$lens_id[[1L]]))
   if(is.character(x)&&length(x)==1L)return(x)
   ""
 },character(1))
 unique(z[nzchar(z)])
}
# One query per seed. Response counts are checked before marking complete.
for(i in seq_len(nrow(s))){
 id<-s$record_id[[i]];lid<-s$lens_id[[i]]
 if(grepl("|",lid,fixed=TRUE))next
 previous<-existing[[id]]
 if(!is.null(previous)&&identical(previous$status,"complete"))next
 if(selected>=limit)break
 selected<-selected+1L
 payload<-list(query=list(terms=list(lens_id=list(lid))),
   include=c("lens_id","references_count","references_resolved_count",
             "scholarly_citations_count","references","scholarly_citations"),size=1L)
 response<-tryCatch(request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json",
              `Content-Type`="application/json") |>
  req_body_json(payload,auto_unbox=TRUE) |> req_timeout(90) |>
  req_error(is_error=function(x)FALSE) |> req_perform(),error=identity)
 status<-"incomplete";back<-character();forward<-character();bc<-NA_integer_;fc<-NA_integer_
 error_text<-NULL
 if(inherits(response,"error"))error_text<-conditionMessage(response)
 else if(resp_status(response)!=200L)error_text<-paste0("Lens HTTP ",resp_status(response))
 else{
  body<-resp_body_json(response,simplifyVector=FALSE)
  if(length(body$data)==1L&&identical(as.character(body$data[[1L]]$lens_id),lid)){
    rec<-body$data[[1L]];back<-get_ids(rec$references);forward<-get_ids(rec$scholarly_citations)
    bc<-as.integer(rec$references_count);fc<-as.integer(rec$scholarly_citations_count)
    if(length(bc)==1L&&length(fc)==1L&&!is.na(bc)&&!is.na(fc)&&
       length(back)>=bc&&length(forward)>=fc)status<-"complete"
    else error_text<-"Citation ID counts do not match Lens totals; no completion claimed"
  }else error_text<-"Seed not uniquely returned by Lens"
 }
 # Persist only complete edges; failed requests are retryable without losing provenance.
 if(status=="complete"){
   con<-file(edgefile,"at");writeLines(toJSON(list(seed_record_id=id,provider="lens",
      backward_ids=back,forward_ids=forward),auto_unbox=TRUE),con);close(con)
 }
 x<-list(record_id=id,lens_id=lid,provider="lens",status=status,
    reference_count=if(length(bc)==1L)bc else NULL,
    scholarly_citations_count=if(length(fc)==1L)fc else NULL,
    backward_ids=length(back),forward_ids=length(forward),
    last_checked_utc=now(),error=error_text)
 con<-file(ledger,"at");writeLines(toJSON(x,auto_unbox=TRUE,null="null"),con);close(con)
 existing[[id]]<-x
}
# Reconcile append-only edge journal by writing an explicitly labelled merged view.
if(file.exists(edgefile)&&file.info(edgefile)$size>0){
 script<-"scripts/workflow08b/merge_edges.R"
 code<-system2("Rscript",c(shQuote(script),shQuote(edgefile),shQuote(file.path(out,"merged"))))
 if(code!=0L)stop("Citation edge merging failed")
}
summary<-list(schema="workflow08b-lens-discovery-dev-v1",requests_this_execution=selected,
 complete_seeds=sum(vapply(existing,function(x)identical(x$status,"complete"),logical(1))),
 incomplete_seeds=sum(vapply(existing,function(x)!identical(x$status,"complete"),logical(1))),
 restricted_to_lens_id_seeds=TRUE,openalex_not_queried=TRUE,
 candidate_bibliography_not_downloaded=TRUE,w01_handoff_not_enabled=TRUE)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),
           file.path(out,"discovery_summary.json"))
cat("W08b Lens discovery checkpoint: requests=",selected,
    "; complete=",summary$complete_seeds,"\n")
