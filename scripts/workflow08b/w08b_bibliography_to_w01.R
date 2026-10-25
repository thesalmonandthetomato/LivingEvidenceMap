#!/usr/bin/env Rscript
# W08b repeatable provider-specific bibliography retrieval and W01 staging.
# Inputs are the eligible provider ID outputs of the citation-chasing stage.
# No historical bibliography reuse; no modification of canonical W01.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x

args<-commandArgs(trailingOnly=TRUE)
if(length(args)!=5L)stop("Usage: w08b_bibliography_to_w01.R lens_ids.csv openalex_ids.csv lens_edges.csv openalex_edges.csv output_dir")
out<-args[[5]];dir.create(out,recursive=TRUE,showWarnings=FALSE)
for(p in args[1:4])if(!file.exists(p))stop("Missing input: ",p)
readids<-function(p,provider){
 x<-read.csv(p,stringsAsFactors=FALSE,na.strings=NULL)
 if(!all(c("provider","related_provider_id")%in%names(x)))stop("Invalid ID input ",p)
 unique(as.character(x$related_provider_id[x$provider==provider]))
}
lens_ids<-sort(readids(args[[1]],"lens"))
oa_ids<-sort(readids(args[[2]],"openalex"))
oa_ids<-toupper(sub("^https?://openalex[.]org/","",oa_ids,ignore.case=TRUE))
if(any(!grepl("^W[0-9]+$",oa_ids))||any(!nzchar(lens_ids)))stop("Invalid provider IDs")
lens_token<-Sys.getenv("LENS_API_TOKEN","");oa_key<-Sys.getenv("OPENALEX_API_KEY","")
if(!nzchar(lens_token)||!nzchar(oa_key))stop("Missing provider API credentials")
pathlens<-file.path(out,"lens","records.jsonl")
pathoa<-file.path(out,"openalex","openalex_sidecar_records.jsonl")
dir.create(dirname(pathlens),recursive=TRUE,showWarnings=FALSE)
dir.create(dirname(pathoa),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(out,"raw","lens"),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(out,"raw","openalex"),recursive=TRUE,showWarnings=FALSE)
get<-function(req,provider){
 for(attempt in seq_len(6L)){
  Sys.sleep(if(provider=="lens")1.5 else 0.15)
  r<-tryCatch(req_perform(req_error(req_timeout(req,180),is_error=function(x)FALSE)),error=identity)
  if(!inherits(r,"error")&&resp_status(r)==200L)return(resp_body_json(r,simplifyVector=FALSE))
  code<-if(inherits(r,"error"))0L else resp_status(r)
  if(!(code%in%c(0L,429L,500L,502L,503L,504L)))stop(provider," HTTP ",code,": ",substr(resp_body_string(r),1,250))
  if(attempt==6L)stop(provider," retries exhausted: ",code)
  Sys.sleep(if(code==429L)65 else min(2^attempt,30))
 }
}
scalar<-function(x){v<-unlist(x,use.names=FALSE);if(!length(v))return(NULL);v<-as.character(v[[1]]);if(is.na(v)||!nzchar(trimws(v)))NULL else v}
doi<-function(x){v<-scalar(x);if(is.null(v))return(NULL);tolower(sub("^https?://(dx[.])?doi[.]org/","",v))}
extract_doi<-function(x){for(z in x$external_ids%||%list())if(is.list(z)&&tolower(scalar(z$type)%||%"")=="doi")return(doi(z$value));NULL}
lens_abstract<-function(x){a<-x$abstract%||%NULL;if(is.character(a))return(paste(a,collapse=" "));if(is.list(a)){z<-unlist(lapply(a,function(y)if(is.list(y))y$text%||%NULL else y),use.names=FALSE);if(length(z))return(paste(z,collapse=" "))};NULL}
oa_abstract<-function(inv){
 if(is.null(inv)||!length(inv))return(NULL)
 p<-list();for(w in names(inv))for(i in inv[[w]])p[[as.character(as.integer(i))]]<-w
 if(!length(p))return(NULL)
 paste(unlist(p[order(as.integer(names(p)))],use.names=FALSE),collapse=" ")
}
writejson<-function(path,obj){cat(toJSON(obj,auto_unbox=TRUE,null="null",na="null",digits=NA),"\n",file=path,append=TRUE,sep="")}
read_done<-function(path){if(!file.exists(path))return(character());unique(readLines(path,warn=FALSE))}
stamp<-format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")
lens_done_path<-file.path(out,"lens_complete_ids.txt")
lens_done<-read_done(lens_done_path)
groups<-split(lens_ids,ceiling(seq_along(lens_ids)/500L))
for(i in seq_along(groups)){
 ids<-groups[[i]];todo<-setdiff(ids,lens_done)
 if(!length(todo))next
 payload<-list(query=list(terms=list(lens_id=as.list(todo))),size=500L)
 q<-request("https://api.lens.org/scholarly/search")|>
  req_headers(Authorization=paste("Bearer",lens_token),Accept="application/json")|>
  req_body_json(payload,auto_unbox=TRUE)
 z<-get(q,"lens")
 records<-z$data%||%list()
 actual<-vapply(records,function(x)scalar(x$lens_id)%||%"",character(1))
 if(anyDuplicated(actual)||any(!actual%in%todo)||length(actual)!=as.integer(z$total))
  stop("Lens partial/unexpected response batch ",i)
 if(length(setdiff(todo,actual)))stop("Lens missing candidate IDs in batch ",i)
 writejson(file.path(out,"raw","lens",sprintf("batch-%04d.jsonl",i)),z)
 for(w in records){
  id<-scalar(w$lens_id);title<-scalar(w$title)
  auth<-w$authors%||%w$author%||%NULL
  keys<-w$keywords%||%w$keyword%||%NULL
  journal<-if(is.list(w$source))scalar(w$source$title%||%w$source$display_name) else scalar(w$source)
  record<-list(identity=list(lens_id=id),canonical=list(
   lens_id=id,doi=extract_doi(w),title=title,abstract=lens_abstract(w),
   authors=auth,year=scalar(w$year_published),source=journal,
   keywords=keys,publication_type=w$publication_type%||%NULL),
   source=list(provider="lens",source_collection="Lens Scholarly"),
   provenance=list(stage="W08b citation discovery",retrieved_at=stamp))
  writejson(pathlens,record)
  cat(id,"\n",file=lens_done_path,append=TRUE,sep="")
 }
 lens_done<-c(lens_done,actual)
}
oa_done_path<-file.path(out,"openalex_complete_ids.txt")
oa_done<-read_done(oa_done_path)
groups<-split(oa_ids,ceiling(seq_along(oa_ids)/40L))
for(i in seq_along(groups)){
 ids<-groups[[i]];todo<-setdiff(ids,oa_done)
 if(!length(todo))next
 q<-request("https://api.openalex.org/works")|>
  req_url_query(filter=paste0("ids.openalex:",paste(todo,collapse="|")),per_page=200,api_key=oa_key)
 z<-get(q,"openalex")
 records<-z$results%||%list()
 actual<-toupper(sub("^https?://openalex[.]org/","",vapply(records,function(w)scalar(w$id)%||%"",character(1)),ignore.case=TRUE))
 if(anyDuplicated(actual)||any(!actual%in%todo)||length(actual)!=as.integer(z$meta$count))
  stop("OpenAlex partial/unexpected response batch ",i)
 if(length(setdiff(todo,actual)))stop("OpenAlex unresolved IDs in batch ",i)
 writejson(file.path(out,"raw","openalex",sprintf("batch-%04d.jsonl",i)),z)
 for(k in seq_along(records)){
  w<-records[[k]];id<-actual[[k]]
  loc<-w$primary_location%||%list()
  source<-loc$source%||%list()
  keywords<-vapply(w$keywords%||%list(),function(x)scalar(x$display_name)%||%"",character(1))
  auth<-lapply(w$authorships%||%list(),function(x)list(display_name=x$author$display_name%||%NULL,
   openalex_author_id=x$author$id%||%NULL,orcid=x$author$orcid%||%NULL))
  record<-list(sidecar_identity=list(sidecar_record_id=paste0("openalex:",id),
   openalex_id=id,doi=doi(w$doi)),
   source=list(provider="openalex",source_format="openalex_works_api_oql_json",
    search_scope=c("title","abstract","keywords")),
   openalex=list(authoritative_raw_payload_location="W08b restricted bibliographic harvest",
    source_raw_file=sprintf("batch-%04d.jsonl",i),raw_payload_duplicated_in_w01=FALSE),
   mapped_fields=list(title=scalar(w$title),abstract=oa_abstract(w$abstract_inverted_index),
    authors=auth,year=scalar(w$publication_year),publication_date=scalar(w$publication_date),
    source=scalar(source$display_name),doi=doi(w$doi),indexing_terms=keywords,
    publication_type=scalar(w$type),open_access=w$open_access%||%NULL,primary_location=loc),
   provenance=list(source_stage="w08b_citation_chasing",adapted_at=stamp,
    canonical_json_modified=FALSE))
  writejson(pathoa,record)
  cat(id,"\n",file=oa_done_path,append=TRUE,sep="")
 }
 oa_done<-c(oa_done,actual)
}
for(provider in c("lens","openalex")){
 edge_path<-if(provider=="lens")args[[3]] else args[[4]]
 x<-read.csv(edge_path,stringsAsFactors=FALSE,na.strings=NULL)
 expected<-if(provider=="lens")lens_ids else oa_ids
 if(!all(c("seed_record_id","provider","related_provider_id","direction")%in%names(x)))
  stop("Invalid provenance schema")
 x<-x[x$provider==provider,,drop=FALSE]
 if(provider=="openalex")x$related_provider_id<-toupper(sub("^https?://openalex[.]org/","",x$related_provider_id,ignore.case=TRUE))
 if(any(!x$related_provider_id%in%expected))stop("Unmatched provenance keys")
 write.csv(x,file.path(out,paste0(provider,"_citation_edges.csv")),row.names=FALSE)
}
if(length(unique(read_done(lens_done_path)))!=length(lens_ids)||
   length(unique(read_done(oa_done_path)))!=length(oa_ids))stop("Incomplete bibliography")
manifest<-list(schema="w08b-bibliography-w01-staging-v1",status="complete",
 retrieved_at=stamp,lens_records=length(lens_ids),openalex_records=length(oa_ids),
 lens_records_path="lens/records.jsonl",openalex_records_path="openalex/openalex_sidecar_records.jsonl",
 citation_provenance_preserved=TRUE,w01_production_not_started=TRUE)
writeLines(toJSON(manifest,pretty=TRUE,auto_unbox=TRUE),file.path(out,"manifest.json"))
cat("PASS: W08b complete bibliographies: Lens=",length(lens_ids),"; OpenAlex=",length(oa_ids),"\n",sep="")
