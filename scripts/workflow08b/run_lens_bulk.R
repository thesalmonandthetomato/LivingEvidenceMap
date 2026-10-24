#!/usr/bin/env Rscript
# Bulk Lens citation discovery based on citationchaser/R/get_refs.R.
# 500 seed IDs per terms lookup; preserves individual edges/status and checkpoint.
# Usage: Rscript scripts/workflow08b/run_lens_bulk.R crosswalk.csv state_dir [max_batches] [update_id]
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<2L||length(a)>4L)stop("Usage: run_lens_bulk.R crosswalk.csv state_dir [max_batches] [update_id]")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-a[[2]]
max_batches<-if(length(a)>=3L)as.integer(a[[3]]) else 1L
update<-if(length(a)>=4L)as.character(a[[4]]) else ""
if(is.na(max_batches)||max_batches<1L||max_batches>100L)stop("max_batches outside 1..100")
if(nzchar(update)&&!grepl("^[A-Za-z0-9._-]+$",update))stop("Invalid update ID")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!nzchar(token))stop("Missing Lens token")
required<-c("record_id","lens_id","preferred_route","identifier_conflict")
if(!all(required%in%names(d))||anyDuplicated(d$record_id))stop("Invalid seed crosswalk")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(out,"lens_seed_status.jsonl")
edgefile<-file.path(out,"lens_edges_input.jsonl")
previous<-list()
if(file.exists(ledger))for(line in readLines(ledger,warn=FALSE)){
 if(!nzchar(line))next
 x<-fromJSON(line,simplifyVector=FALSE);previous[[as.character(x$record_id)]]<-x
}
d<-d[d$preferred_route=="lens" & !d$identifier_conflict & nzchar(d$lens_id) &
 !grepl("|",d$lens_id,fixed=TRUE),,drop=FALSE]
d<-d[order(d$record_id),,drop=FALSE]
todo<-vapply(seq_len(nrow(d)),function(i){
 old<-previous[[d$record_id[[i]]]]
 is.null(old)||!identical(old$status,"complete")||
 (nzchar(update)&&!identical(as.character(old$update_id %||% ""),update))
},logical(1))
d<-d[todo,,drop=FALSE]
if(anyDuplicated(d$lens_id))stop("Multiple seed identities share Lens ID; resolve before bulk discovery")
chunks<-split(seq_len(nrow(d)),ceiling(seq_len(nrow(d))/500L))
if(length(chunks)>max_batches)chunks<-chunks[seq_len(max_batches)]
get_ids<-function(x){
 if(is.null(x))return(character())
 u<-vapply(x,function(y)if(is.list(y))as.character(y$lens_id %||% "") else as.character(y),character(1))
 unique(u[nzchar(u)&!is.na(u)])
}
stamp<-function()format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
record_status<-function(x){
 f<-file(ledger,"at");on.exit(close(f))
 writeLines(toJSON(x,auto_unbox=TRUE,null="null"),f)
 previous[[as.character(x$record_id)]]<<-x
}
save_edges<-function(x){
 f<-file(edgefile,"at");on.exit(close(f))
 writeLines(toJSON(x,auto_unbox=TRUE),f)
}
requests<-0L;completed<-0L;halt<-NULL;failures<-integer()
for(indices in chunks){
 batch<-d[indices,,drop=FALSE]
 ids<-as.character(batch$lens_id)
 # citationchaser models this as query.terms.lens_id = array of IDs;
 # including six relationship fields, not full candidate bibliographies.
 payload<-list(query=list(terms=list(lens_id=as.list(ids))),size=as.integer(length(ids)),
  include=c("lens_id","references","references_count","references_resolved_count",
            "scholarly_citations","scholarly_citations_count"))
 resp<-tryCatch(request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json") |>
  req_body_json(payload,auto_unbox=TRUE) |> req_timeout(180) |>
  req_error(is_error=function(x)FALSE) |> req_perform(),error=identity)
 requests<-requests+1L
 if(inherits(resp,"error")){halt<-paste0("transport_error: ",conditionMessage(resp));break}
 code<-resp_status(resp)
 if(code!=200L){
  failures<-c(failures,code);halt<-paste0("Lens HTTP ",code)
  # A batch HTTP failure must not be misattributed to 500 individual seeds.
  break
 }
 body<-resp_body_json(resp,simplifyVector=FALSE)
 records<-body$data %||% list()
 actual<-vapply(records,function(x)as.character(x$lens_id %||% ""),character(1))
 if(anyDuplicated(actual)||any(!actual%in%ids)){halt<-"Ambiguous bulk result identities";break}
 if(as.integer(body$total %||% length(records))>length(records)){
  halt<-"Bulk result pagination required; refusing partial completion";break
 }
 lookup<-setNames(seq_along(actual),actual)
 for(i in seq_len(nrow(batch))){
  seed<-batch[i,,drop=FALSE];lid<-seed$lens_id[[1]];id<-seed$record_id[[1]]
  old<-previous[[id]]
  back<-forward<-character();bc<-fc<-NA_integer_;status<-"incomplete";err<-NULL
  if(!lid%in%names(lookup)){err<-"Seed absent from successful bulk response"}
  else{
   z<-records[[lookup[[lid]]]]
   back<-get_ids(z$references);forward<-get_ids(z$scholarly_citations)
   bc<-if(is.null(z$references_count)&&is.null(z$references))0L else as.integer(z$references_count)
   fc<-if(is.null(z$scholarly_citations_count)&&is.null(z$scholarly_citations))0L else as.integer(z$scholarly_citations_count)
   if(length(bc)==1L&&length(fc)==1L&&!is.na(bc)&&!is.na(fc)&&
       length(back)>=bc&&length(forward)>=fc)status<-"complete"
   else err<-"Citation ID counts incomplete"
  }
  oldcount<-if(is.null(old))NA_integer_ else suppressWarnings(as.integer(old$reference_count %||% NA_integer_))
  refresh_back<-is.null(old)||!identical(old$status,"complete")||is.na(oldcount)||(!is.na(bc)&&bc>oldcount)
  if(identical(status,"complete")){
   save_edges(list(seed_record_id=id,provider="lens",
      backward_ids=if(refresh_back)back else character(),forward_ids=forward))
   completed<-completed+1L
  }
  # Never replace an accepted complete status with an incomplete retry.
  if(!identical(status,"complete")&&!is.null(old)&&identical(old$status,"complete"))next
  record_status(list(record_id=id,lens_id=lid,provider="lens",status=status,
   update_id=if(nzchar(update))update else NULL,
   reference_count=if(length(bc)==1L)bc else NULL,
   scholarly_citations_count=if(length(fc)==1L)fc else NULL,
   backward_ids=if(!refresh_back&&!is.null(old))old$backward_ids else length(back),
   forward_ids=length(forward),backward_refreshed=refresh_back,
   last_checked_utc=stamp(),error=err))
 }
}
if(file.exists(edgefile)&&file.info(edgefile)$size>0){
 res<-system2("Rscript",c("scripts/workflow08b/merge_edges.R",shQuote(edgefile),
                         shQuote(file.path(out,"merged"))))
 if(res!=0L)stop("Edge merge failed")
}
summary<-list(schema="workflow08b-lens-discovery-dev-v1",
  discovery_mode="citationchaser_500_id_terms",batch_size=500L,
  requests_this_execution=requests,completed_this_execution=completed,
  complete_seeds=sum(vapply(previous,function(z)identical(z$status,"complete"),logical(1))),
  incomplete_seeds=sum(vapply(previous,function(z)!identical(z$status,"complete"),logical(1))),
  halted_early=!is.null(halt),halt_reason=halt,http_status_counts=as.list(table(failures)),
  openalex_not_queried=TRUE,candidate_bibliography_not_downloaded=TRUE,w01_handoff_not_enabled=TRUE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out,"discovery_summary.json"))
cat("W08b bulk Lens: requests=",requests,"; completed_this_execution=",completed,
 "; halted=",if(is.null(halt))"no" else halt,"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
