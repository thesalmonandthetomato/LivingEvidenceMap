#!/usr/bin/env Rscript
# W08b Lens-first citation discovery. Isolated manual runner, no W01 or Zenodo writes.
# Usage: Rscript scripts/workflow08b/run_lens_discovery.R crosswalk.csv output_dir [max_requests]
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
args<-commandArgs(trailingOnly=TRUE)
if(length(args)<2L||length(args)>4L)stop("Usage: run_lens_discovery.R crosswalk.csv output_dir [max_requests] [update_id]")
input<-args[[1L]];out<-args[[2L]]
limit<-if(length(args)==3L)as.integer(args[[3L]])else 10L
update_id<-if(length(args)==4L)as.character(args[[4L]])else ""
if(nzchar(update_id)&&!grepl("^[A-Za-z0-9._-]+$",update_id))stop("Invalid update_id")
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
 if(!nzchar(update_id)&&!is.null(previous)&&identical(previous$status,"complete"))next
 if(nzchar(update_id)&&!is.null(previous)&&identical(as.character(previous$update_id %||% "" ),update_id) && identical(previous$status,"complete"))next
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
    # Lens may omit a count for a direction with no returned relationships.
    # Only infer zero when both the count and corresponding list are absent.
    bc<-if(is.null(rec$references_count) && is.null(rec$references)) 0L else as.integer(rec$references_count)
    fc<-if(is.null(rec$scholarly_citations_count) && is.null(rec$scholarly_citations)) 0L else as.integer(rec$scholarly_citations_count)
    if(length(bc)==1L&&length(fc)==1L&&!is.na(bc)&&!is.na(fc)&&
       length(back)>=bc&&length(forward)>=fc)status<-"complete"
    else error_text<-"Citation ID counts do not match Lens totals; no completion claimed"
  }else error_text<-"Seed not uniquely returned by Lens"
 }
 # Persist only complete edges; failed requests are retryable without losing provenance.
 if(status=="complete"){
   # On monthly checks the API supplies both directions. Forward edges always
   # refresh; backward edges are only re-emitted if a seed is new, previously
   # incomplete, or the reported reference count has increased. Historical
   # edges are never deleted from the append-only journal.
   prior_bc<-if(is.null(previous)) NA_integer_ else
     suppressWarnings(as.integer(previous$reference_count %||% NA_integer_))
   previously_complete<-!is.null(previous)&&identical(previous$status,"complete")
   recheck_backward<-!previously_complete||is.na(prior_bc)||bc>prior_bc
   if(nzchar(update_id)&&!recheck_backward)back<-character()
   backward_retrieved_this_update<-recheck_backward
   con<-file(edgefile,"at");writeLines(toJSON(list(seed_record_id=id,provider="lens",
      backward_ids=back,forward_ids=forward),auto_unbox=TRUE),con);close(con)
 }
 x<-list(record_id=id,lens_id=lid,provider="lens",status=status,
    update_id=if(nzchar(update_id))update_id else NULL,
    reference_count=if(length(bc)==1L)bc else NULL,
    scholarly_citations_count=if(length(fc)==1L)fc else NULL,
    backward_ids=if(status=="complete" && nzchar(update_id) && !backward_retrieved_this_update) as.integer(previous$backward_ids %||% 0L) else length(back),
    backward_refreshed=if(status=="complete" && nzchar(update_id)) backward_retrieved_this_update else (status=="complete"),
    forward_ids=length(forward),
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
# Summarise failure mechanisms without exposing source identifiers to public logs.
incomplete<-Filter(function(x)!identical(x$status,"complete"),existing)
reasons<-vapply(incomplete,function(x){
 e<-as.character(x$error %||% "unknown")
 if(grepl("^Lens HTTP",e))return("api_http_failure")
 if(grepl("Citation ID counts",e,fixed=TRUE))return("citation_count_mismatch")
 if(grepl("not uniquely",e,fixed=TRUE))return("seed_not_uniquely_resolved")
 if(grepl("timeout|timed out",e,ignore.case=TRUE))return("request_timeout")
 "other_request_error"
},character(1))
summary$incomplete_by_reason<-as.list(table(reasons))
if(length(incomplete)){
  message("W08b incomplete seed categories: ",
    paste(sprintf("%s=%d",names(summary$incomplete_by_reason),
      unlist(summary$incomplete_by_reason)),collapse=", "))
}
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),
           file.path(out,"discovery_summary.json"))
cat("W08b Lens discovery checkpoint: requests=",selected,
    "; complete=",summary$complete_seeds,"\n")
