#!/usr/bin/env Rscript
# Expand every manifestation ID of each canonical W08 seed for citation queries.
# Multiple IDs are valid; they must not be silently dropped. No provider calls.
# Usage: expand_seed_identifiers.R seed_identifier_crosswalk.csv output_dir
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: expand_seed_identifiers.R crosswalk.csv output_dir")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-a[[2]]
required<-c("record_id","lens_id","openalex_id","doi")
if(!all(required%in%names(d))||anyDuplicated(d$record_id))stop("Invalid seed crosswalk")
split_ids<-function(x,kind){
  v<-trimws(strsplit(as.character(x), "|", fixed=TRUE)[[1]])
  v<-unique(v[!is.na(v)&nzchar(v)])
  if(kind=="openalex"){
    v<-toupper(sub("^https?://openalex[.]org/","",v,ignore.case=TRUE))
    if(any(!grepl("^W[0-9]+$",v)))stop("Invalid OpenAlex identifier")
  } else if(kind=="doi"){
    v<-tolower(sub("^doi:[[:space:]]*","",sub("^https?://(dx\\.)?doi[.]org/","",v,ignore.case=TRUE)))
  }
  if(any(grepl("[[:space:]]",v)))stop("Whitespace inside identifier")
  v
}
rows<-list();n<-0L
for(i in seq_len(nrow(d))){
  seed<-d$record_id[[i]]
  if(!nzchar(seed))stop("Missing canonical record ID")
  for(kind in c("lens","openalex","doi")){
    field<-if(kind=="lens")"lens_id" else if(kind=="openalex")"openalex_id" else "doi"
    values<-split_ids(d[[field]][[i]],kind)
    for(v in values){
      n<-n+1L
      rows[[n]]<-data.frame(seed_record_id=seed,provider=if(kind=="openalex")"openalex" else "lens",
        identifier_type=kind,query_identifier=v,stringsAsFactors=FALSE)
    }
  }
}
empty<-data.frame(seed_record_id=character(),provider=character(),identifier_type=character(),query_identifier=character())
raw<-if(length(rows))do.call(rbind,rows) else empty
queries<-unique(raw)
queries<-queries[order(queries$seed_record_id,queries$identifier_type,queries$query_identifier),,drop=FALSE]
dir.create(out,recursive=TRUE,showWarnings=FALSE)
write.csv(queries,file.path(out,"seed_identifier_queries.csv"),row.names=FALSE,na="")
# Shared IDs can map to several canonical seed records; query each provider ID
# only once, but preserve the one-to-many mapping for provenance.
unique_queries<-unique(queries[,c("provider","identifier_type","query_identifier"),drop=FALSE])
unique_queries<-unique_queries[order(unique_queries$provider,unique_queries$identifier_type,unique_queries$query_identifier),,drop=FALSE]
write.csv(unique_queries,file.path(out,"unique_identifier_queries.csv"),row.names=FALSE,na="")
multi<-sum(vapply(seq_len(nrow(d)),function(i)any(vapply(c("lens_id","openalex_id","doi"),function(k)
  length(split_ids(d[[k]][[i]],if(k=="lens_id")"lens" else if(k=="openalex_id")"openalex" else "doi"))>1L,logical(1))),logical(1)))
summary<-list(schema="workflow08b-expanded-identifiers-v1",
  canonical_seeds=nrow(d),seeds_with_multiple_ids=multi,
  seed_identifier_edges=nrow(queries),unique_identifier_queries=nrow(unique_queries),
  lens_ids=sum(queries$identifier_type=="lens"),
  openalex_ids=sum(queries$identifier_type=="openalex"),
  doi_ids=sum(queries$identifier_type=="doi"),
  all_valid_manifestation_ids_retained=TRUE,
  multiple_ids_are_not_exclusions=TRUE,provider_calls_performed=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
cat("PASS: ",nrow(d)," seeds expanded into ",nrow(queries),
    " seed-identifier edges and ",nrow(unique_queries)," distinct provider/type queries\\n",sep="")
