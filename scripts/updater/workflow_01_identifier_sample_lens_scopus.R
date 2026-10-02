#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
source <- arg("--source")
query <- arg("--query")
output <- arg("--output")
n <- as.integer(arg("--n","20"))
if (is.null(source)||is.null(query)||is.null(output)) stop("--source --query --output required",call.=FALSE)
if (!(source %in% c("lens","scopus"))) stop("--source must be lens or scopus",call.=FALSE)
if (is.na(n)||n<1L||n>50L) stop("--n must be 1..50",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)

scalar <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  y<-trimws(as.character(x[[1L]]))
  if(!nzchar(y)) NULL else y
}
write_jsonl <- function(rows,path) {
  con<-file(path,"wt",encoding="UTF-8")
  on.exit(close(con),add=TRUE)
  for(r in rows) writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
}

if (source=="lens") {
  token<-Sys.getenv("LENS_API_TOKEN","")
  if(!nzchar(token)) stop("LENS_API_TOKEN required",call.=FALSE)
  cfg<-fromJSON("config/lens_search.json",simplifyVector=FALSE)
  cfg$api_query$query$bool$must[[1L]]$query_string$query<-query
  req<-request("https://api.lens.org/scholarly/search") |>
    req_headers(Authorization=paste("Bearer",token),`Content-Type`="application/json",Accept="application/json") |>
    req_body_json(list(query=cfg$api_query$query,size=n),auto_unbox=TRUE) |>
    req_error(is_error=function(resp) FALSE)
  resp<-req_perform(req)
  if(resp_status(resp)>=400L) stop(sprintf("Lens HTTP %d",resp_status(resp)),call.=FALSE)
  x<-resp_body_json(resp,simplifyVector=FALSE)
  data<-x$data %||% list()
  rows<-lapply(data,function(raw) {
    lid<-scalar(raw$lens_id)
    ids<-raw$external_ids %||% list()
    doi<-NULL
    pmid<-NULL
    pmcid<-NULL
    openalex_id<-NULL
    core_id<-NULL
    mag_id<-NULL
    for(z in ids) if(is.list(z)) {
      typ<-tolower(as.character(z$type %||% ""))
      val<-scalar(z$value)
      if(is.null(val)) next
      if(identical(typ,"doi")) doi<-val
      if(typ %in% c("pmid","pubmed","pubmed_id")) pmid<-val
      if(typ %in% c("pmcid","pmc")) pmcid<-val
      if(typ %in% c("openalex","openalex_id")) openalex_id<-val
      if(typ %in% c("core","coreid","core_id")) core_id<-val
      if(typ %in% c("magid","mag","microsoft academic")) mag_id<-val
    }
    list(
      identity=list(lens_id=lid,record_id=lid,pmid=pmid,pmcid=pmcid,openalex_id=openalex_id,core_id=core_id,mag_id=mag_id),
      identifiers=list(doi=doi,pmid=pmid,pmcid=pmcid,openalex=openalex_id,core=core_id,mag=mag_id),
      source=list(provider="lens"),
      lens=list(raw_payload=raw),
      canonical=list(
        title=scalar(raw$title),year=scalar(raw$year_published %||% raw$date_published),
        doi=doi,pmid=pmid,pmcid=pmcid,openalex_id=openalex_id,core_id=core_id,mag_id=mag_id,abstract=scalar(raw$abstract),authors=raw$authors %||% NULL
      )
    )
  })
  write_jsonl(rows,output)
  cat(sprintf("PASS: Lens sample %d records\n",length(rows)))
}

if (source=="scopus") {
  key<-Sys.getenv("SCOPUS_API_TOKEN","")
  inst<-Sys.getenv("SCOPUS_INSTTOKEN","")
  if(!nzchar(key)||!nzchar(inst)) stop("Scopus credentials required",call.=FALSE)
  req<-request("https://api.elsevier.com/content/search/scopus") |>
    req_headers(Accept="application/json",`X-ELS-APIKey`=key,`X-ELS-Insttoken`=inst) |>
    req_url_query(query=query,start=0L,count=n,view="STANDARD") |>
    req_error(is_error=function(resp) FALSE)
  resp<-req_perform(req)
  if(resp_status(resp)>=400L) stop(sprintf("Scopus HTTP %d",resp_status(resp)),call.=FALSE)
  x<-fromJSON(resp_body_string(resp),simplifyVector=FALSE)
  entries<-x[["search-results"]][["entry"]] %||% list()
  rows<-lapply(entries,function(e) {
    rid<-sub("^SCOPUS_ID:","",scalar(e[["dc:identifier"]]) %||% "")
    eid<-scalar(e$eid)
    doi<-scalar(e[["prism:doi"]])
    pmid<-scalar(e[["pubmed-id"]])
    list(
      sidecar_identity=list(sidecar_record_id=paste0("scopus:",eid %||% rid),scopus_id=rid,eid=eid,doi=doi,pmid=pmid),
      identifiers=list(doi=doi,pmid=pmid),
      source=list(provider="scopus"),
      mapped_fields=list(
        title=scalar(e[["dc:title"]]),
        year=scalar(e[["prism:coverDate"]]),
        doi=doi,
        pmid=pmid,
        source=scalar(e[["prism:publicationName"]])
      )
    )
  })
  write_jsonl(rows,output)
  cat(sprintf("PASS: Scopus sample %d records\n",length(rows)))
}
