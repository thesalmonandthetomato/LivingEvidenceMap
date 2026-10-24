#!/usr/bin/env Rscript
# W08b candidate bibliography: one Lens terms lookup per <=500 unique IDs.
# Retains every retrieved candidate, including previously known W01 records.
# No production writes and no automatic screening handoff.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
args<-commandArgs(trailingOnly=TRUE)
if(length(args)<3L||length(args)>4L)stop("Usage: retrieve_lens_candidates_bulk.R provider_candidate_ids.csv state_dir strategy.json [max_batches]")
ids<-read.csv(args[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-args[[2]];strategy<-args[[3]]
limit<-if(length(args)==4L)as.integer(args[[4]])else 1L
if(is.na(limit)||limit<1L||limit>1000L)stop("Invalid batch limit")
if(!all(c("provider","related_provider_id")%in%names(ids)))stop("Invalid provider ID register")
if(anyDuplicated(ids[c("provider","related_provider_id")]))stop("Duplicate provider keys")
ids<-sort(unique(ids$related_provider_id[ids$provider=="lens"]))
if(any(!nzchar(ids)))stop("Empty Lens candidate ID")
cfg<-if(identical(strategy,"-"))NULL else fromJSON(strategy,simplifyVector=FALSE)
if(!is.null(cfg)&&!identical(cfg$search_version,"v2"))stop("Unsupported registered search strategy")
token<-Sys.getenv("LENS_API_TOKEN","");if(!nzchar(token))stop("Lens token absent")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(out,"lens_candidate_status.jsonl")
bibliography<-file.path(out,"lens_candidate_metadata.jsonl")
seen<-list()
if(file.exists(ledger))for(line in readLines(ledger,warn=FALSE)){
 if(!nzchar(line))next
 x<-fromJSON(line,simplifyVector=FALSE);seen[[as.character(x$lens_id)]]<-x
}
ids<-ids[!vapply(ids,function(id){
 x<-seen[[id]];!is.null(x)&&x$status%in%c("complete")
},logical(1))]
chunks<-split(seq_along(ids),ceiling(seq_along(ids)/500L))
chunks<-head(chunks,limit)
append<-function(path,x){f<-file(path,"at");on.exit(close(f));writeLines(toJSON(x,auto_unbox=TRUE,null="null"),f)}
extract_doi<-function(z){\n ids<-z$external_ids %||% list()\n for(id in ids){\n  if(is.list(id)&&identical(tolower(as.character(id$type %||% "")),"doi")){\n   v<-as.character(id$value %||% "");if(length(v)&&nzchar(v[[1L]]))return(v[[1L]])\n  }\n }\n ""\n}\nstring<-function(x){z<-unlist(x,use.names=FALSE);if(!length(z))return("");as.character(z[[1]])}
doi_norm<-function(x){z<-tolower(trimws(string(x)));z<-sub("^https?://(dx[.])?doi[.]org/","",z);sub("^doi:[[:space:]]*","",z)}
extract_keywords<-function(z){
 x<-z$keywords %||% z$keyword %||% list()
 vals<-unlist(x,use.names=FALSE);unique(as.character(vals[nzchar(as.character(vals))]))
}
extract_abstract<-function(z){
 x<-z$abstract %||% NULL
 if(is.null(x))return(NULL)
 if(is.character(x))return(paste(x,collapse=" "))
 # Some Lens responses return language/text objects.
 if(is.list(x)){
  y<-unlist(lapply(x,function(v)if(is.list(v))v$text %||% NULL else v),use.names=FALSE)
  if(length(y))return(paste(y,collapse=" "))
 }
 NULL
}
topic<-function(xs)paste(vapply(c("title","abstract","keyword"),function(field)
 paste0(field,":(",paste(xs,collapse=" OR "),")"),character(1)),collapse=" OR ")
original<-if(is.null(cfg))NULL else paste0("(",topic(unlist(cfg$species_terms)),") AND (",topic(unlist(cfg$farm_terms)),")")
# Provider-side NOT must not hide candidates before complete identity or
# provenance capture: retrieve complete bibliography first, then validate the
# NOT predicate separately via a dedicated provider-control query.
attempted<-0L;completed<-0L;halt<-NULL
for(ix in chunks){
 batch<-ids[ix]
 payload<-list(query=list(terms=list(lens_id=as.list(batch))),
  include=c("lens_id","title","abstract","keyword","doi","external_ids","year_published"),
  size=length(batch))
 result<-tryCatch(request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json") |>
  req_body_json(payload,auto_unbox=TRUE) |> req_timeout(180) |>
  req_error(is_error=function(x)FALSE) |> req_perform(),error=identity)
 attempted<-attempted+1L
 if(inherits(result,"error")){halt<-paste("Lens transport:",conditionMessage(result));break}
 if(resp_status(result)!=200L){halt<-paste("Lens HTTP",resp_status(result));break}
 body<-resp_body_json(result,simplifyVector=FALSE)
 records<-body$data %||% list()
 got<-vapply(records,function(z)string(z$lens_id),character(1))
 if(anyDuplicated(got)||any(!nzchar(got))||as.integer(body$total %||% length(records))>length(records)){
  halt<-"Ambiguous or truncated candidate metadata batch";break
 }
 if(any(!got%in%batch))message("Quarantining ",sum(!got%in%batch)," unrequested Lens candidates")\n records<-records[got%in%batch];got<-got[got%in%batch]\n byid<-setNames(seq_along(got),got)
 for(id in batch){
  if(!id%in%names(byid)){
   append(ledger,list(lens_id=id,status="incomplete",provider="lens",error="Seed absent from bulk response"))
   seen[[id]]<-list(status="incomplete")
   next
  }
  z<-records[[byid[[id]]]]
  record<-list(candidate_key=paste0("lens:",id),provider="lens",lens_id=id,
    doi=doi_norm(extract_doi(z)),title=if(is.null(z$title))NULL else string(z$title),
    abstract=extract_abstract(z),keywords=if(is.null(z$keyword)&&is.null(z$keywords))NULL else extract_keywords(z),
    year=string(z$year_published),source="Lens scholarly/search")
  append(bibliography,record)
  append(ledger,list(lens_id=id,status="complete",provider="lens",
    checked_at=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")))
  seen[[id]]<-list(status="complete");completed<-completed+1L
 }
}
summary<-list(schema="workflow08b-lens-candidate-metadata-v1",requests=attempted,
 completed_this_run=completed,halted=!is.null(halt),halt_reason=halt,
 original_strategy_version=if(is.null(cfg))"deferred" else "v2",original_query_expression=original,
 provider_not_filter_applied=FALSE,
 screening_handoff_authorised=FALSE)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE,null="null"),file.path(out,"candidate_retrieval_summary.json"))
cat("W08b candidate bibliographies: requests=",attempted,"; complete=",completed,
 "; halted=",!is.null(halt),"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
