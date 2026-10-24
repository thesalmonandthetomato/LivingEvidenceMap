#!/usr/bin/env Rscript
# W08b: resolve DOI-only W08 seeds to Lens IDs in 500 DOI terms per request.
# Checkpoints are append-only. Never confound an absent Lens match with an error.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<2L||length(a)>3L)stop("Usage: resolve_lens_doi_bulk.R crosswalk.csv state_dir [max_batches]")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-a[[2]];limit<-if(length(a)==3L)as.integer(a[[3]])else 100L
if(is.na(limit)||limit<1L||limit>100L)stop("Invalid batch cap")
required<-c("record_id","doi","lens_id","preferred_route","identifier_conflict")
if(!all(required%in%names(d))||anyDuplicated(d$record_id))stop("Invalid crosswalk")
token<-Sys.getenv("LENS_API_TOKEN","");if(!nzchar(token))stop("Missing Lens API token")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
journal<-file.path(out,"lens_doi_resolution.jsonl")
previous<-list()
if(file.exists(journal))for(line in readLines(journal,warn=FALSE)){
 if(!nzchar(line))next
 z<-fromJSON(line,simplifyVector=FALSE);previous[[as.character(z$record_id)]]<-z
}
normal<-function(x){x<-tolower(trimws(as.character(x)));x<-sub("^https?://(dx[.])?doi[.]org/","",x);sub("^doi:[[:space:]]*","",x)}
d<-d[d$preferred_route=="lens_doi_lookup" & !d$identifier_conflict & nzchar(d$doi),,drop=FALSE]
d$doi<-normal(d$doi)
d<-d[nzchar(d$doi)&!grepl("|",d$doi,fixed=TRUE),,drop=FALSE]
d<-d[order(d$record_id),,drop=FALSE]
d<-d[!vapply(d$record_id,function(id){
 z<-previous[[id]];!is.null(z)&&z$status%in%c("resolved","ambiguous")
},logical(1)),,drop=FALSE]
# Distinct W08 identities sharing a DOI must not block unrelated lookups.
# Quarantine each collision for identity adjudication, without querying Lens.
dupe<-duplicated(d$doi)|duplicated(d$doi,fromLast=TRUE)
if(any(dupe)){
 for(i in which(dupe)){
  append_collision<-list(record_id=d$record_id[[i]],doi=d$doi[[i]],
   lens_id=NULL,status="ambiguous",provider="lens",
   error="duplicate_doi_across_w08_seed_ids",
   checked_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
  con<-file(journal,"at");writeLines(toJSON(append_collision,auto_unbox=TRUE,null="null"),con);close(con)
  previous[[d$record_id[[i]]]]<-append_collision
 }
}
d<-d[!dupe,,drop=FALSE]
chunks<-split(seq_len(nrow(d)),ceiling(seq_len(nrow(d))/500L))
if(length(chunks)>limit)chunks<-chunks[seq_len(limit)]
append<-function(z){
 f<-file(journal,"at");on.exit(close(f))
 writeLines(toJSON(z,auto_unbox=TRUE,null="null"),f)
 previous[[as.character(z$record_id)]]<<-z
}
requests<-0L;halt<-NULL
for(ix in chunks){
 b<-d[ix,,drop=FALSE]
 payload<-list(query=list(terms=list(doi=as.list(b$doi))),size=500L)
 r<-tryCatch(request("https://api.lens.org/scholarly/search") |>
  req_headers(Authorization=paste("Bearer",token),Accept="application/json") |>
  req_body_json(payload,auto_unbox=TRUE) |> req_timeout(180) |>
  req_error(is_error=function(x)FALSE) |> req_perform(),error=identity)
 requests<-requests+1L
 if(inherits(r,"error")){halt<-conditionMessage(r);break}
 if(resp_status(r)!=200L){halt<-paste("Lens HTTP",resp_status(r),substr(resp_body_string(r),1L,500L));break}
 z<-resp_body_json(r,simplifyVector=FALSE)
 rows<-z$data %||% list()
 if(length(rows)&&requests==1L)message("Lens DOI response fields: ",paste(names(rows[[1L]]),collapse=","),"; returned_records=",length(rows),"; total=",z$total %||% "unknown")
 if(as.integer(z$total %||% length(rows))>length(rows)){halt<-"Incomplete DOI lookup pagination";break}
 bydoi<-list()
 for(item in rows){
   doi<-normal(item$doi %||% "")
   if(!nzchar(doi))next
   if(!doi%in%b$doi){halt<-"Lens DOI response outside submitted set";break}
   bydoi[[doi]]<-c(bydoi[[doi]] %||% character(),as.character(item$lens_id %||% ""))
 }
 if(!is.null(halt))break
 if(length(rows)>0L && length(bydoi)==0L){halt<-"Lens returned matches but parser found zero DOI fields; fail closed";break}
 for(i in seq_len(nrow(b))){
  ids<-unique(bydoi[[b$doi[[i]]]] %||% character())
  ids<-ids[nzchar(ids)]
  status<-if(length(ids)==1L)"resolved" else if(length(ids))"ambiguous" else "not_found"
  append(list(record_id=b$record_id[[i]],doi=b$doi[[i]],lens_id=if(length(ids)==1L)ids[[1]] else NULL,
    status=status,provider="lens",checked_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")))
 }
}
# Keep the authoritative W08 record count unchanged; overlay only stable Lens IDs.
for(i in seq_len(nrow(d))){
 z<-previous[[d$record_id[[i]]]]
 if(!is.null(z)&&identical(z$status,"resolved")){
  k<-match(d$record_id[[i]],d$record_id)
  d$lens_id[[k]]<-z$lens_id
  d$preferred_route[[k]]<-"lens"
 }
}
write.csv(d,file.path(out,"doi_seed_resolution_subset.csv"),row.names=FALSE)
summary<-list(schema="workflow08b-lens-doi-bulk-v1",requests=requests,
 total_in_journal=length(previous),
 ambiguous=sum(vapply(previous,function(z)identical(z$status,"ambiguous"),logical(1))),
 resolved=sum(vapply(previous,function(z)identical(z$status,"resolved"),logical(1))),
 not_found=sum(vapply(previous,function(z)identical(z$status,"not_found"),logical(1))),
 halted=!is.null(halt),halt_reason=halt)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE,null="null"),file.path(out,"doi_resolution_summary.json"))
cat("W08b DOI bulk: requests=",requests," resolved=",summary$resolved,
 " halted=",if(is.null(halt))"no" else halt,"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
