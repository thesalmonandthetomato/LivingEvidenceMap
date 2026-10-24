#!/usr/bin/env Rscript
# W08b bounded Lens relationship API smoke-test (one seed, one request).
# Never expands citing IDs into full records and never calls OpenAlex.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: lens_relationship_smoke.R <private_trial_seeds.csv> <summary.json>")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("LENS_API_TOKEN is not configured")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
s<-d[d$preferred_route=="lens" & !d$identifier_conflict & nzchar(d$lens_id),,drop=FALSE]
if(!nrow(s))stop("No unambiguous Lens seed")
id<-s$lens_id[[1L]]
if(grepl("|",id,fixed=TRUE))stop("Conflicting Lens IDs must not be queried")
fields<-c("lens_id","reference_count","referenced_by_count","references","referenced_by")
payload<-list(query=list(term=list(lens_id=id)),include=fields,size=1L)
req<-request("https://api.lens.org/scholarly/search") |>
 req_headers(Authorization=paste("Bearer",token),Accept="application/json",`Content-Type`="application/json") |>
 req_body_json(payload,auto_unbox=TRUE) |> req_timeout(90) |>
 req_error(is_error=function(resp)FALSE)
response<-req_perform(req); status<-resp_status(response)
if(status!=200L)stop("Lens smoke request returned HTTP ",status)
body<-resp_body_json(response,simplifyVector=FALSE)
n<-length(body$data %||% list())
if(n>1L)stop("Exceeded one-result hard cap")
if(n==1L && !identical(as.character(body$data[[1L]]$lens_id),id))
 stop("Returned Lens ID does not match requested seed")
record<-if(n)body$data[[1L]] else list()
result<-list(schema="workflow08b-lens-smoke-v1",query_count=1L,
             expected_max_records=1L,matched_records=n,
             reference_count=record$reference_count %||% NULL,
             referenced_by_count=record$referenced_by_count %||% NULL,
             has_references_field=!is.null(record$references),
             has_referenced_by_field=!is.null(record$referenced_by),
             no_candidate_downloads=TRUE)
dir.create(dirname(a[[2L]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE,null="null"),a[[2L]])
cat("PASS: Lens one-seed relationship schema smoke request; matched=",n,"\n")
`%||%`<-function(x,y)if(is.null(x))y else x
