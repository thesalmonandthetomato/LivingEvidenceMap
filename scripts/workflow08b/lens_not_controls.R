#!/usr/bin/env Rscript
# Bounded Lens NOT-filter positive and negative controls; max three one-result requests.
suppressPackageStartupMessages({library(httr2);library(jsonlite)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: lens_not_controls.R <strategy.json> <summary.json>")
cfg<-fromJSON(a[[1]],simplifyVector=FALSE)
stopifnot(identical(cfg$search_version,"v2"),"maricultur*" %in% unlist(cfg$farm_terms))
clause<-function(terms)paste(vapply(c("title","abstract","keyword"),function(f)paste0(f,":(",paste(terms,collapse=" OR "),")"),character(1)),collapse=" OR ")
topic<-paste0("(",clause(unlist(cfg$species_terms)),") AND (",clause(unlist(cfg$farm_terms)),")")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("Missing Lens token")
fetch<-function(query){
 response<-request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json",`Content-Type`="application/json") |>
  req_body_json(list(query=query,include=c("lens_id","title"),size=1L),auto_unbox=TRUE) |>
  req_timeout(90) |> req_error(is_error=function(resp)FALSE) |> req_perform()
 status<-resp_status(response)
 if(status!=200L)stop("Lens HTTP ",status,": ",substr(resp_body_string(response),1L,900L))
 x<-resp_body_json(response,simplifyVector=FALSE)$data
 if(length(x)>1L)stop("One-record response limit breached")
 if(length(x))as.character(x[[1L]]$lens_id) else ""
}
by_id<-function(id,exclude=FALSE){
 q<-list(bool=list(must=list(list(terms=list(lens_id=list(id))))))
 if(exclude)q$bool$must_not<-list(list(query_string=list(query=topic)))
 fetch(q)
}
topical_id<-"033-262-857-738-715"
topical_without<-by_id(topical_id,FALSE)
if(!identical(topical_without,topical_id))stop("Topical control record not found")
topical_with<-by_id(topical_id,TRUE)
if(nzchar(topical_with))stop("Topical sentinel was not excluded by NOT filter")
# Discover one control where topical exclusion does not match, using only a single
# title-scoped quantum computing search. It is not downloaded as a candidate.
non_topic_id<-fetch(list(query_string=list(query="title:(quantum computing)")))
if(!nzchar(non_topic_id))stop("No non-topic control found")
# Four bounded calls including discovering the control, all with size=1.
non_topic_with<-by_id(non_topic_id,TRUE)
if(!identical(non_topic_with,non_topic_id))stop("Non-topical control was incorrectly excluded")
result<-list(schema="workflow08b-lens-not-controls-v1",search_strategy_version="v2",
 maricultur_included=grepl("maricultur*",topic,fixed=TRUE),
 topical_control_found=TRUE,topical_control_excluded=TRUE,
 unrelated_control_found=TRUE,unrelated_control_retained=TRUE,
 requests=4L,max_response_records_each=1L)
dir.create(dirname(a[[2L]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE),a[[2L]])
cat("PASS: Lens v2 NOT excludes topical sentinel and retains unrelated title control\n")
