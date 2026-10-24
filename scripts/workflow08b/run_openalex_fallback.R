#!/usr/bin/env Rscript
# W08b OpenAlex fallback ONLY for seeds Lens could not resolve.
# Uses cursor pagination for citing works, reference IDs on each source work.
# Isolated from W01, follows same edge/status journal contract as Lens.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
`%||%`<-function(x,y)if(is.null(x))y else x
a<-commandArgs(trailingOnly=TRUE)
if(length(a)<2L||length(a)>4L)stop("Usage: run_openalex_fallback.R crosswalk.csv state_dir [max_seeds] [update_id]")
d<-read.csv(a[[1]],stringsAsFactors=FALSE,na.strings=NULL)
out<-a[[2]];limit<-if(length(a)>=3L)as.integer(a[[3]])else 100L
update<-if(length(a)==4L)a[[4]]else ""
if(is.na(limit)||limit<1L||limit>500L)stop("max_seeds outside 1..500")
if(nzchar(update)&&!grepl("^[A-Za-z0-9._-]+$",update))stop("Invalid update ID")
needed<-c("record_id","openalex_id","preferred_route","identifier_conflict")
if(!all(needed%in%names(d))||anyDuplicated(d$record_id))stop("Invalid crosswalk")
d<-d[d$preferred_route=="openalex" & !d$identifier_conflict & nzchar(d$openalex_id),,drop=FALSE]
if(any(grepl("|",d$openalex_id,fixed=TRUE)))stop("Conflicting OpenAlex IDs")
d<-d[order(d$record_id),,drop=FALSE]
dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-file.path(out,"openalex_seed_status.jsonl");edges<-file.path(out,"openalex_edges_input.jsonl")
old<-list()
if(file.exists(ledger))for(line in readLines(ledger,warn=FALSE)){
 if(!nzchar(line))next
 z<-fromJSON(line,simplifyVector=FALSE);old[[as.character(z$record_id)]]<-z
}
keep<-vapply(seq_len(nrow(d)),function(i){
 z<-old[[d$record_id[[i]]]]
 is.null(z)||!identical(z$status,"complete")||
 (nzchar(update)&&!identical(as.character(z$update_id %||% ""),update))
},logical(1))
d<-head(d[keep,,drop=FALSE],limit)
api_key<-Sys.getenv("OPENALEX_API_KEY","")
email<-Sys.getenv("OPENALEX_MAILTO","")
normal<-function(x){x<-toupper(sub("^https?://openalex[.]org/","",as.character(x),ignore.case=TRUE));if(grepl("^W[0-9]+$",x))x else ""}
now<-function()format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")
query<-function(url,params=list()){
 r<-request(url)|>req_user_agent("W08b citation discovery (research)")|>req_timeout(120)
 if(nzchar(email))r<-req_url_query(r,mailto=email)
 if(nzchar(api_key))r<-req_url_query(r,api_key=api_key)
 if(length(params))r<-do.call(req_url_query,c(list(r),params))
 v<-tryCatch(req_perform(req_error(r,is_error=function(x)FALSE)),error=identity)
 if(inherits(v,"error"))stop(conditionMessage(v))
 if(resp_status(v)!=200L)stop("OpenAlex HTTP ",resp_status(v))
 resp_body_json(v,simplifyVector=FALSE)
}
append<-function(path,z){con<-file(path,"at");on.exit(close(con));writeLines(toJSON(z,auto_unbox=TRUE,null="null"),con)}
complete<-0L;halt<-NULL;requests<-0L
for(i in seq_len(nrow(d))){
 id<-d$record_id[[i]];oa<-normal(d$openalex_id[[i]])
 prior<-old[[id]]
 if(!nzchar(oa)){halt<-"Invalid OpenAlex seed identifier";break}
 result<-tryCatch({
  w<-query(paste0("https://api.openalex.org/works/",oa));requests<-requests+1L
  bc<-length(w$referenced_works %||% list())
  back<-unique(vapply(w$referenced_works %||% list(),normal,character(1)))
  back<-back[nzchar(back)]
  # OpenAlex forward citations must be fully paginated. Never accept one page
  # as complete when its reported cited_by_count is larger.
  forward<-character();cursor<-"*";pages<-0L
  repeat{
   z<-query("https://api.openalex.org/works",list(filter=paste0("cites:",oa),
      per_page=200,cursor=cursor,select="id"));requests<-requests+1L
   pages<-pages+1L
   ids<-vapply(z$results %||% list(),function(x)normal(x$id %||% ""),character(1))
   forward<-unique(c(forward,ids[nzchar(ids)]))
   next_cursor<-z$meta$next_cursor %||% NULL
   if(is.null(next_cursor)||!length(z$results))break
   if(pages>=5000L)stop("OpenAlex pagination safety cap reached")
   if(identical(next_cursor,cursor))stop("OpenAlex cursor did not advance")
   cursor<-as.character(next_cursor)
  }
  expected<-as.integer(w$cited_by_count %||% 0L)
  if(length(forward)<expected)stop("OpenAlex citation count exceeds returned IDs")
  list(back=back,forward=forward,bc=bc,fc=expected)
 },error=identity)
 if(inherits(result,"error")){
  halt<-conditionMessage(result)
  append(ledger,list(record_id=id,openalex_id=oa,provider="openalex",status="incomplete",
   update_id=if(nzchar(update))update else NULL,last_checked_utc=now(),error=halt))
  break
 }
 oldbc<-if(is.null(prior))NA_integer_ else suppressWarnings(as.integer(prior$reference_count %||% NA))
 backward_refresh<-is.null(prior)||!identical(prior$status,"complete")||is.na(oldbc)||result$bc>oldbc
 append(edges,list(seed_record_id=id,provider="openalex",
   backward_ids=if(backward_refresh)result$back else character(),forward_ids=result$forward))
 z<-list(record_id=id,openalex_id=oa,provider="openalex",status="complete",
  update_id=if(nzchar(update))update else NULL,reference_count=result$bc,
  scholarly_citations_count=result$fc,backward_ids=if(backward_refresh)length(result$back)else prior$backward_ids,
  forward_ids=length(result$forward),backward_refreshed=backward_refresh,
  last_checked_utc=now(),error=NULL)
 append(ledger,z);old[[id]]<-z;complete<-complete+1L
}
if(file.exists(edges)&&file.info(edges)$size>0){
 exit<-system2("Rscript",c("scripts/workflow08b/merge_edges.R",shQuote(edges),shQuote(file.path(out,"openalex_merged"))))
 if(exit!=0L)stop("OpenAlex edge merge failed")
}
summary<-list(schema="workflow08b-openalex-fallback-v1",completed_this_run=complete,
  requests_this_run=requests,halted=!is.null(halt),halt_reason=halt,
  lens_fallback_only=TRUE,w01_handoff_authorised=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out,"openalex_summary.json"))
cat("W08b OpenAlex fallback: completed=",complete," requests=",requests," halted=",!is.null(halt),"\n",sep="")
if(!is.null(halt))quit(save="no",status=2L)
