#!/usr/bin/env Rscript
# Monthly all-manifestation Lens discovery; query each distinct Lens ID once and
# associate its references and citations with every canonical seed owning it.
# Based on citationchaser/R/get_refs.R.
# 500 seed IDs per terms lookup; preserves individual edges/status and checkpoint.
# Usage: Rscript scripts/workflow08b/run_lens_bulk.R expanded_identifiers.csv state_dir [max_batches] [update_id]
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
fixture<-Sys.getenv("W08B_LENS_TEST_FIXTURE","")
test_mode<-nzchar(fixture) && identical(Sys.getenv("W08B_TEST_MODE",""),"1")
if(nzchar(fixture)&&!test_mode)stop("A test fixture requires W08B_TEST_MODE=1")
if(test_mode && !file.exists(fixture))stop("Lens fixture not found")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!test_mode&&!nzchar(token))stop("Missing Lens token")
required<-c("seed_record_id","provider","identifier_type","query_identifier")
if(!all(required%in%names(d))||anyDuplicated(d[,required]))stop("Invalid identifier manifest")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(out,"lens_seed_status.jsonl")
edgefile<-file.path(out,"lens_edges_input.jsonl")
previous<-new.env(hash=TRUE,parent=emptyenv())
if(file.exists(ledger))for(line in readLines(ledger,warn=FALSE)){
 if(!nzchar(line))next
 x<-fromJSON(line,simplifyVector=FALSE);if(identical(as.character(x$provider %||% "lens"),"lens") && nzchar(as.character(x$lens_id %||% ""))) previous[[as.character(x$lens_id)]]<-x
}
d<-d[d$provider=="lens" & d$identifier_type=="lens" & nzchar(d$query_identifier),,drop=FALSE]
associations<-unique(d[,c("seed_record_id","query_identifier"),drop=FALSE])
seed_index<-split(associations$seed_record_id,associations$query_identifier)
d<-unique(d[,c("query_identifier"),drop=FALSE]);names(d)<-"lens_id"
d<-d[order(d$lens_id),,drop=FALSE]
todo<-vapply(seq_len(nrow(d)),function(i){
 old<-previous[[d$lens_id[[i]]]]
 is.null(old)||!isTRUE(old$status%in%c("complete","not_found"))||
 (nzchar(update)&&!identical(as.character(old$update_id %||% ""),update))
},logical(1))
d<-d[todo,,drop=FALSE]
if(anyDuplicated(d$lens_id))stop("Duplicate query Lens identifiers")
chunks<-split(seq_len(nrow(d)),ceiling(seq_len(nrow(d))/500L))
if(length(chunks)>max_batches)chunks<-chunks[seq_len(max_batches)]
get_ids<-function(x){
 if(is.null(x))return(character())
 if(!is.list(x)&&!is.character(x))stop("Malformed Lens citation relationship list")
 u<-vapply(x,function(y)if(is.list(y))as.character(y[["lens_id"]] %||% "") else as.character(y),character(1))
 unique(u[nzchar(u)&!is.na(u)])
}
stamp<-function()format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
record_status<-function(x){
 f<-file(ledger,"at");on.exit(close(f))
 writeLines(toJSON(x,auto_unbox=TRUE,null="null"),f)
 previous[[as.character(x$lens_id)]]<<-x
}
save_edges<-function(x){
 f<-file(edgefile,"at");on.exit(close(f))
 writeLines(toJSON(x,auto_unbox=TRUE),f)
}
requests<-0L;completed<-0L;halt<-NULL;failures<-integer()
coverage_gaps<-0L;unavailable<-0L
fetch_records<-function(ids){
 payload<-list(query=list(terms=list(lens_id=as.list(ids))),size=500L,
  include=c("lens_id","references","references_count","references_resolved_count",
            "scholarly_citations","scholarly_citations_count"))
 requests<<-requests+1L
 if(test_mode){
  body<-fromJSON(fixture,simplifyVector=FALSE)
  # Fixture is a complete response for the requested identifiers.
  return(body)
 }
 r<-request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json") |>
  req_body_json(payload,auto_unbox=TRUE) |> req_timeout(180) |>
  req_retry(max_tries=4,retry_on_failure=TRUE,
    is_transient=function(resp)resp_status(resp)%in%c(408L,429L,500L,502L,503L,504L))
 resp<-req_perform(r)
 resp_body_json(resp,simplifyVector=FALSE)
}
validated_records<-function(body,ids){
 if(!is.list(body)||is.null(body$total))stop("Lens response lacks search total")
 records<-body$data %||% list()
 total<-suppressWarnings(as.integer(body$total))
 if(length(total)!=1L||is.na(total)||total<0L||total!=length(records))
   stop("Lens returned partial or inconsistent search page")
 actual<-vapply(records,function(x)as.character(x$lens_id %||% ""),character(1))
 if(anyDuplicated(actual)||any(!nzchar(actual)))stop("Invalid Lens bulk response: missing or duplicate IDs")
 if(any(!actual%in%ids))message("Lens bulk: quarantined ",sum(!actual%in%ids)," unexpected returned records")
 setNames(records[actual%in%ids],actual[actual%in%ids])
}
count_value<-function(x){
 if(is.null(x))return(NA_integer_)
 v<-suppressWarnings(as.integer(x))
 if(length(v)!=1L||is.na(v)||v<0L)stop("Invalid Lens citation count metadata")
 v
}
for(indices in chunks){
 batch<-d[indices,,drop=FALSE];ids<-as.character(batch$lens_id)
 records<-tryCatch(validated_records(fetch_records(ids),ids),error=identity)
 if(inherits(records,"error")){halt<-conditionMessage(records);break}
 for(i in seq_len(nrow(batch))){
  lid<-batch$lens_id[[i]];old<-previous[[lid]]
  back<-forward<-character();bc<-fc<-rc<-NA_integer_;status<-"incomplete";err<-NULL
  z<-records[[lid]]
  # Absence is only accepted after two successful targeted searches.
  if(is.null(z)){
   for(attempt in seq_len(2L)){
    single<-tryCatch(validated_records(fetch_records(lid),lid),error=identity)
    if(inherits(single,"error")){halt<-conditionMessage(single);break}
    z<-single[[lid]]
    if(!is.null(z))break
   }
   if(!is.null(halt))break
  }
  if(is.null(z)){
   status<-"not_found";err<-"Absent from bulk and two successful targeted searches"
   unavailable<-unavailable+1L
  }else{
   result<-tryCatch({
    # Lens total references include references without resolved Lens IDs.
    # A structurally valid full response is accepted with the available IDs.
    # Exact indexing is essential: R's $ partially matches count fields
    # when the corresponding relationship list is absent.
    list(back=get_ids(z[["references"]]),forward=get_ids(z[["scholarly_citations"]]),
      bc=count_value(z[["references_count"]]),rc=count_value(z[["references_resolved_count"]]),
      fc=count_value(z[["scholarly_citations_count"]]))
   },error=identity)
   if(inherits(result,"error")){halt<-conditionMessage(result);break}
   back<-result$back;forward<-result$forward;bc<-result$bc;rc<-result$rc;fc<-result$fc
   status<-"complete"
   if(any(c(!is.na(bc)&&length(back)!=bc,!is.na(rc)&&length(back)!=rc,
            !is.na(fc)&&length(forward)!=fc))){
    coverage_gaps<-coverage_gaps+1L
    message("Lens coverage discrepancy ",lid,": references=",length(back),"/",bc,
      "; resolved=",rc,"; citing=",length(forward),"/",fc)
   }
  }
  seed_ids<-seed_index[[lid]]
  if(!length(seed_ids))stop("Discovered Lens ID without canonical seed association")
  if(identical(status,"complete")){
   for(id in seed_ids)save_edges(list(seed_record_id=id,provider="lens",
      queried_seed_identifier=lid,
      backward_ids=back,forward_ids=forward))
   completed<-completed+1L
  }
  record_status(list(record_id=seed_ids[[1]],seed_record_ids=as.list(seed_ids),lens_id=lid,provider="lens",status=status,
   update_id=if(nzchar(update))update else NULL,
   reference_count=if(length(bc)==1L)bc else NULL,
   references_resolved_count=rc,
   reference_count_discrepancy=bc-length(back),resolved_count_discrepancy=rc-length(back),
   scholarly_citations_count=fc,citing_count_discrepancy=fc-length(forward),
   backward_ids=length(back),
   forward_ids=length(forward),backward_refreshed=identical(status,"complete"),
   last_checked_utc=stamp(),error=err))
 }
 if(!is.null(halt))break
}
if(is.null(halt)&&!identical(Sys.getenv("W08B_DEFER_EDGE_MERGE"),"1")&&file.exists(edgefile)&&file.info(edgefile)$size>0){
 res<-system2("Rscript",c("scripts/workflow08b/merge_edges.R",shQuote(edgefile),
                         shQuote(file.path(out,"merged"))))
 if(res!=0L)stop("Edge merge failed")
}
summary<-list(schema="workflow08b-lens-discovery-dev-v1",
  discovery_mode="citationchaser_500_id_terms",batch_size=500L,
  requests_this_execution=requests,completed_this_execution=completed,
  coverage_discrepancies=coverage_gaps,not_found_this_execution=unavailable,
  complete_seeds=sum(vapply(as.list(previous),function(z)identical(z$status,"complete"),logical(1))),
  incomplete_seeds=sum(vapply(as.list(previous),function(z)!isTRUE(z$status%in%c("complete","not_found")),logical(1))),
  halted_early=!is.null(halt),halt_reason=halt,http_status_counts=as.list(table(failures)),
  openalex_not_queried=TRUE,candidate_bibliography_not_downloaded=TRUE,w01_handoff_not_enabled=TRUE,
  test_fixture_mode=test_mode)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out,"discovery_summary.json"))
cat("W08b bulk Lens: requests=",requests,"; completed_this_execution=",completed,
 "; halted=",if(is.null(halt))"no" else halt,"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
