#!/usr/bin/env Rscript
# W08b: one-request, one-seed validation of Lens v2 topical NOT expression.
# Validates server query acceptance; not proof of recall or equivalent OpenAlex semantics.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L) stop("Usage: lens_not_smoke.R <v2_strategy.json> <output_summary.json>")
cfg<-fromJSON(a[[1]],simplifyVector=FALSE)
stopifnot(identical(cfg$search_version,"v2"),"maricultur*" %in% unlist(cfg$farm_terms))
species<-unlist(cfg$species_terms);farm<-unlist(cfg$farm_terms)
stopifnot(length(species)>0L,length(farm)>0L)
clause<-function(terms) paste(vapply(c("title","abstract","keyword"),function(f){
 paste0(f,":(",paste(terms,collapse=" OR "),")")
},character(1)),collapse=" OR ")
topic<-paste0("(",clause(species),") AND (",clause(farm),")")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("Lens API credential absent")
sentinel<-"033-262-857-738-715"
payload<-list(query=list(bool=list(
 must=list(list(terms=list(lens_id=list(sentinel)))),
 must_not=list(list(query_string=list(query=topic)))
)),include=c("lens_id","title"),size=1L)
response<-request("https://api.lens.org/scholarly/search") |>
 req_headers(Authorization=paste("Bearer",token),Accept="application/json",`Content-Type`="application/json") |>
 req_body_json(payload,auto_unbox=TRUE) |> req_timeout(90) |>
 req_error(is_error=function(resp)FALSE) |> req_perform()
code<-resp_status(response)
if(code!=200L)stop("Lens NOT test HTTP ",code,": ",substr(resp_body_string(response),1L,1000L))
body<-resp_body_json(response,simplifyVector=FALSE)
rows<-body$data
if(length(rows)>1L)stop("One-seed cap breached")
if(length(rows)==1L && !identical(as.character(rows[[1]]$lens_id),sentinel))
 stop("Returned an unexpected Lens ID")
result<-list(schema="workflow08b-lens-not-smoke-v1",strategy="v2",
 included_maricultur=grepl("maricultur*",topic,fixed=TRUE),
 query_accepted=TRUE,query_count=1L,max_results=1L,returned=length(rows),
 validated_as_candidate_filter=FALSE)
dir.create(dirname(a[[2L]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE),a[[2L]])
cat("PASS: Lens accepted v2 NOT query including maricultur*; returned ",length(rows)," seed records\n",sep="")
