#!/usr/bin/env Rscript
# Resolve every distinct DOI to all matching Lens IDs, not one Lens ID per work.
# Input: expanded seed_identifier_queries.csv. Output: expanded Lens-ID query
# associations, DOI status journal, preserving every canonical seed link.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<2L||length(a)>4L)
  stop("Usage: resolve_lens_doi_manifest.R expanded_ids.csv state_dir [max_batches] [update_id]")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-a[[2]]
max_batches<-if(length(a)>=3L)as.integer(a[[3]])else 1L
update<-if(length(a)>=4L)a[[4]]else ""
stopifnot(!is.na(max_batches),max_batches>=1L,max_batches<=100L)
if(nzchar(update)&&!grepl("^[A-Za-z0-9._-]+$",update))stop("Invalid update ID")
needed<-c("seed_record_id","provider","identifier_type","query_identifier")
if(!all(needed%in%names(d))||anyDuplicated(d[,needed]))stop("Invalid expanded identifier input")
fixture<-Sys.getenv("W08B_DOI_TEST_FIXTURE","")
test_mode<-nzchar(fixture) && identical(Sys.getenv("W08B_TEST_MODE",""),"1")
if(nzchar(fixture)&&!test_mode)stop("DOI test fixture requires W08B_TEST_MODE=1")
if(test_mode&&!file.exists(fixture))stop("DOI test fixture missing")
token<-Sys.getenv("LENS_API_TOKEN","")
if(!test_mode&&!nzchar(token))stop("Missing Lens token")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
journal<-file.path(out,"lens_doi_resolution.jsonl")
normal<-function(x){
 x<-tolower(trimws(as.character(x)))
 sub("^doi:[[:space:]]*","",sub("^https?://(dx[.])?doi[.]org/","",x))
}
d<-d[d$provider=="lens" & d$identifier_type=="doi" & nzchar(d$query_identifier),,drop=FALSE]
d$query_identifier<-normal(d$query_identifier)
assoc<-unique(d[,c("seed_record_id","query_identifier"),drop=FALSE])
dois<-sort(unique(assoc$query_identifier))
if(any(!nzchar(dois)))stop("Invalid DOI")
old<-list()
if(file.exists(journal))for(line in readLines(journal,warn=FALSE)){
 if(!nzchar(trimws(line)))next
 z<-fromJSON(line,simplifyVector=FALSE)
 doi<-normal(z$doi %||% "")
 if(nzchar(doi))old[[doi]]<-z
}
todo<-dois[!vapply(dois,function(doi){
 z<-old[[doi]]
 !is.null(z)&&nzchar(update)&&identical(as.character(z$update_id %||% ""),update)&&
   identical(as.character(z$status %||% ""),"complete")
},logical(1))]
batches<-split(todo,ceiling(seq_along(todo)/500L))
if(length(batches)>max_batches)batches<-batches[seq_len(max_batches)]
append<-function(z){
 f<-file(journal,"at");on.exit(close(f))
 writeLines(toJSON(z,auto_unbox=TRUE,null="null"),f)
 old[[z$doi]]<<-z
}
extract_dois<-function(z){
 ids<-character()
 for(e in z$external_ids %||% list()){
  if(!is.list(e))next
  if(tolower(as.character(e$type %||% ""))=="doi")
    ids<-c(ids,normal(e$value %||% ""))
 }
 unique(ids[nzchar(ids)])
}
halt<-NULL;requests<-0L
for(batch in batches){
 payload<-list(query=list(terms=list(doi=as.list(batch))),size=500L,
   include=c("lens_id","external_ids"))
 resp<-if(test_mode)NULL else tryCatch(request("https://api.lens.org/scholarly/search") |>
   req_headers(Authorization=paste("Bearer",token),Accept="application/json") |>
   req_body_json(payload,auto_unbox=TRUE) |> req_timeout(180) |>
   req_error(is_error=function(x)FALSE) |> req_perform(),error=identity)
 requests<-requests+1L
 if(inherits(resp,"error")){halt<-conditionMessage(resp);break}
 if((if(test_mode)200L else resp_status(resp))!=200L){
   halt<-paste("Lens DOI HTTP",resp_status(resp),substr(resp_body_string(resp),1,300));break
 }
 body<-if(test_mode)fromJSON(fixture,simplifyVector=FALSE) else resp_body_json(resp,simplifyVector=FALSE)
 works<-body$data %||% list()
 if(as.integer(body$total %||% length(works))>length(works)){
   halt<-"DOI search returned an incomplete page; reduce batch size before retry";break
 }
 matched<-list()
 for(w in works){
   lid<-as.character(w$lens_id %||% "")
   if(length(lid)!=1L||!nzchar(lid)){halt<-"DOI search result lacks Lens ID";break}
   for(doi in intersect(extract_dois(w),batch))
     matched[[doi]]<-unique(c(matched[[doi]] %||% character(),lid))
 }
 if(!is.null(halt))break
 for(doi in batch){
   seeds<-assoc$seed_record_id[assoc$query_identifier==doi]
   lids<-sort(unique(matched[[doi]] %||% character()))
   append(list(record_id=seeds[[1]],seed_record_ids=as.list(seeds),
     doi=doi,lens_ids=as.list(lids),provider="lens",
     status="complete",update_id=update,
     lens_matches=length(lids),
     last_checked_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")))
 }
}
# Build the manifest for all completed DOI lookups AND direct Lens identities.
# Do not silently regard an unqueried DOI as resolved.
existing<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
direct<-existing[existing$provider=="lens" & existing$identifier_type=="lens",needed,drop=FALSE]
resolved<-list();k<-0L
for(doi in names(old)){
 z<-old[[doi]]
 if(!identical(as.character(z$status %||% ""),"complete"))next
 lids<-as.character(unlist(z$lens_ids %||% list(),use.names=FALSE))
 seeds<-assoc$seed_record_id[assoc$query_identifier==doi]
 for(seed in seeds)for(lid in lids){
   k<-k+1L
   resolved[[k]]<-data.frame(seed_record_id=seed,provider="lens",
      identifier_type="lens",query_identifier=lid,stringsAsFactors=FALSE)
 }
}
extra<-if(length(resolved))do.call(rbind,resolved)else direct[FALSE,,drop=FALSE]
all<-unique(rbind(direct,extra))
all<-all[order(all$query_identifier,all$seed_record_id),,drop=FALSE]
write.csv(all,file.path(out,"expanded_lens_identifier_queries.csv"),row.names=FALSE)
summary<-list(schema="workflow08b-lens-doi-manifest-v1",
 requested_unique_dois=length(dois),completed_dois=sum(vapply(dois,function(doi)
   !is.null(old[[doi]])&&identical(as.character(old[[doi]]$status),"complete"),logical(1))),
 requests_this_execution=requests,halted=!is.null(halt),halt_reason=halt,
 total_lens_seed_associations=nrow(all),test_fixture_mode=test_mode,multi_lens_dois=sum(vapply(old,function(z)
   length(unlist(z$lens_ids %||% list()))>1L,logical(1))),
 all_matching_ids_retained=TRUE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out,"doi_resolution_summary.json"))
cat("DOI manifest: complete=",summary$completed_dois,
    "/",length(dois),"; lens associations=",nrow(all),"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
