#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=3L)stop("Usage: openalex_species_not_farming_test.R provider_ids.csv strategy.json result.json")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
cfg<-fromJSON(a[[2]],simplifyVector=FALSE)
stopifnot(identical(cfg$search_version,"v2"),"maricultur*"%in%cfg$farm_terms)
ids<-sort(unique(as.character(d$related_provider_id[d$provider=="openalex"])))
ids<-toupper(sub("^https?://openalex[.]org/","",ids,ignore.case=TRUE))
ids<-unique(ids[grepl("^W[0-9]+$",ids)])
if(!length(ids))stop("No OpenAlex-specific citation IDs in archived provider register; stop rather than invent a count")
ids<-ids[unique(round(seq(1,length(ids),length.out=min(length(ids),30L))))]
sp<-paste(cfg$species_terms,collapse=" OR ")
fm<-paste(cfg$farm_terms,collapse=" OR ")
get<-function(kind){
 q<-request("https://api.openalex.org/works")|>
  req_url_query(filter=paste0("ids.openalex:",paste(ids,collapse="|")),per_page=100,select="id")
 if(kind!="all"){
  term<-if(kind=="species")paste0("(",sp,")") else paste0("(",sp,") NOT (",fm,")")
  q<-req_url_query(q,search.title_abstract_keywords.exact=term)
 }
 key<-Sys.getenv("OPENALEX_API_KEY","")
 if(nzchar(key))q<-req_url_query(q,api_key=key)
 response<-req_perform(req_error(req_timeout(q,120),is_error=function(x)FALSE))
 if(resp_status(response)!=200L)stop(kind,": OpenAlex HTTP ",resp_status(response),": ",substr(resp_body_string(response),1L,600))
 body<-resp_body_json(response,simplifyVector=FALSE)
 got<-unique(toupper(sub("^https?://openalex[.]org/","",vapply(body$results,function(x)as.character(x$id),character(1)))))
 if(any(!got%in%ids)||length(got)!=as.integer(body$meta$count))stop("Unexpected identities or incomplete response in ",kind)
 got
}
before<-get("all");Sys.sleep(1)
species<-get("species");Sys.sleep(1)
final<-get("species_not_farming")
if(!all(final%in%species)||!all(species%in%before))stop("OpenAlex Boolean subset invariant failed")
summary<-list(schema="w08b-openalex-boolean-smoke-v1",provider_ids_available=length(unique(d$related_provider_id[d$provider=="openalex"])),
sample_size=length(ids),baseline=length(before),species=length(species),
species_not_farming=length(final),farming_excluded=length(setdiff(species,final)),
subset_valid=TRUE)
dir.create(dirname(a[[3]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),a[[3]])
cat("PASS: OpenAlex sampled=",length(ids),"; species=",length(species),"; species AND NOT farming=",length(final),"\n",sep="")
