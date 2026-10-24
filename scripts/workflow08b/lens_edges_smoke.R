#!/usr/bin/env Rscript
# One-seed Lens citation edge extraction, no candidate bibliographic lookup.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=1L)stop("Usage: lens_edges_smoke.R <output-summary.json>")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("Missing LENS_API_TOKEN")
id<-"033-262-857-738-715"
payload<-list(query=list(terms=list(lens_id=list(id))),
 include=c("lens_id","references_count","references_resolved_count","scholarly_citations_count","references","scholarly_citations"),
 size=1L)
resp<-request("https://api.lens.org/scholarly/search") |>
 req_headers(Authorization=paste("Bearer",token),Accept="application/json",`Content-Type`="application/json") |>
 req_body_json(payload,auto_unbox=TRUE) |> req_timeout(90) |>
 req_error(is_error=function(x)FALSE) |> req_perform()
if(resp_status(resp)!=200L)stop("Lens HTTP ",resp_status(resp),": ",substr(resp_body_string(resp),1L,700L))
body<-resp_body_json(resp,simplifyVector=FALSE)
if(length(body$data)!=1L)stop("Sentinel did not resolve uniquely")
r<-body$data[[1L]]
if(!identical(as.character(r$lens_id),id))stop("Sentinel mismatch")
items<-function(v)if(is.null(v))list() else if(is.list(v))v else as.list(v)
extract<-function(v){
 x<-items(v)
 if(!length(x))return(character())
 ids<-vapply(x,function(z){
   if(is.list(z)) {y<-z$lens_id;if(is.null(y))return("");return(as.character(y[[1L]]))}
   if(is.character(z)&&length(z)==1L)return(z)
   ""
 },character(1))
 unique(trimws(ids[nzchar(trimws(ids))]))
}
back<-extract(r$references)
forward<-extract(r$scholarly_citations)
# We require only that relationships are recognized or explicitly incomplete.
back_count<-as.integer(r$references_count %||% NA_integer_)
forward_count<-as.integer(r$scholarly_citations_count %||% NA_integer_)
if(is.na(back_count)||is.na(forward_count))stop("Missing provider counts")
edges<-data.frame(related_lens_id=c(back,forward),direction=c(rep("backward",length(back)),rep("forward",length(forward))),stringsAsFactors=FALSE)
if(nrow(edges))edges<-unique(edges)
summary<-list(schema="workflow08b-lens-edge-smoke-v1",
  requests=1L,seed_matched=TRUE,
  backward_count_reported=back_count,backward_ids_extracted=length(back),
  forward_count_reported=forward_count,forward_ids_extracted=length(forward),
  overlap_ids=length(intersect(back,forward)),
  missing_backward_ids=max(0L,back_count-length(back)),
  missing_forward_ids=max(0L,forward_count-length(forward)),
  backward_complete=(length(back)>=back_count),
  forward_complete=(length(forward)>=forward_count),
  candidate_records_downloaded=0L)
dir.create(dirname(a[[1L]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),a[[1L]])
cat("PASS: extracted Lens relationship IDs; completeness separately recorded\n")