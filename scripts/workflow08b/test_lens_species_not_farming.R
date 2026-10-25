#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
or_null<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: test_lens_species_not_farming.R ids.csv strategy.json output.json")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
cfg<-fromJSON(a[[2]],simplifyVector=FALSE)
stopifnot(identical(cfg$search_version,"v2"),"maricultur*"%in%cfg$farm_terms)
ids<-sort(unique(d$related_provider_id[d$provider=="lens"]))
if(length(ids)<100L)stop("Insufficient Lens IDs")
ids<-ids[unique(round(seq(1,length(ids),length.out=100L)))]
clause<-function(terms)paste(vapply(c("title","abstract","keyword"),function(field)
 paste0(field,":(",paste(terms,collapse=" OR "),")"),character(1)),collapse=" OR ")
sp<-clause(cfg$species_terms);fm<-clause(cfg$farm_terms)
token<-Sys.getenv("LENS_API_TOKEN","");if(!nzchar(token))stop("Missing Lens token")
query<-function(kind){
 must<-list(list(terms=list(lens_id=as.list(ids))))
 if(kind!="all")must<-append(must,list(list(query_string=list(query=sp))))
 q<-list(bool=list(must=must))
 if(kind=="species_not_farming")q$bool$must_not<-list(list(query_string=list(query=fm)))
 response<-request("https://api.lens.org/scholarly/search")|>
 req_headers(Authorization=paste("Bearer",token),Accept="application/json")|>
 req_body_json(list(query=q,size=500L),auto_unbox=TRUE)|>req_timeout(180)|>
 req_error(is_error=function(x)FALSE)|>req_perform()
 if(resp_status(response)!=200L)stop(kind," Lens HTTP ",resp_status(response),": ",substr(resp_body_string(response),1,500))
 z<-resp_body_json(response,simplifyVector=FALSE)
 got<-vapply(or_null(z$data,list()),function(x)as.character(or_null(x$lens_id,"")),character(1))
 if(anyDuplicated(got)||any(!got%in%ids)||as.integer(z$total)!=length(got))
  stop(kind," response truncated or unexpected/duplicated IDs")
 list(ids=got,count=length(got))
}
allids<-query("all");Sys.sleep(2)
species<-query("species");Sys.sleep(2)
remaining<-query("species_not_farming")
if(!all(remaining$ids %in% species$ids)||!all(species$ids %in% allids$ids))
 stop("Boolean nesting failed")
excluded<-setdiff(species$ids,remaining$ids)
result<-list(schema="w08b-lens-species-not-farming-test-v1",
 submitted_lens_ids=length(ids),found_by_id=allids$count,
 species_matched=species$count,species_not_farming=remaining$count,
 removed_by_farming=length(excluded),nested_result_valid=TRUE,
 sample_rule="100 equally spaced IDs from sorted unique Lens candidate-ID register")
dir.create(dirname(a[[3]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,pretty=TRUE,auto_unbox=TRUE),a[[3]])
cat("PASS: sample=",length(ids),"; found=",allids$count,
 "; species=",species$count,"; species AND NOT farming=",remaining$count,
 "; removed farming=",length(excluded),"\n",sep="")
