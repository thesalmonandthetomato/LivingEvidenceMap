#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(xml2)
  library(data.table)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
plan_path <- arg("--plan")
ebsco_config <- arg("--ebsco-config","config/workflow00_ebsco_sources.json")
output <- arg("--output")
if (is.null(plan_path)||is.null(output)) stop("--plan and --output required",call.=FALSE)
plan <- fromJSON(plan_path,simplifyVector=FALSE)
cfg <- fromJSON(ebsco_config,simplifyVector=FALSE)

scalar <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}

rows <- list()

# OpenAlex: inspect raw work ids object from a capped request.
oa_query <- as.character(plan$source_queries$openalex)
oa_key <- Sys.getenv("OPENALEX_API_KEY","")
req <- request("https://api.openalex.org/") |>
  req_headers(Authorization=paste("Bearer",oa_key)) |>
  req_url_query(
    oql=oa_query,
    `per-page`=20,
    cursor="*"
  ) |>
  req_error(is_error=function(resp) FALSE)
resp <- req_perform(req)
if (resp_status(resp)>=400L) stop(sprintf("OpenAlex HTTP %d",resp_status(resp)),call.=FALSE)
oa <- fromJSON(resp_body_string(resp),simplifyVector=FALSE)
works <- oa$results %||% list()
for (w in works) {
  ids <- w$ids %||% list()
  for (nm in names(ids)) {
    v <- scalar(ids[[nm]])
    if (!is.null(v)) rows[[length(rows)+1L]] <- data.table(source="openalex",identifier_field=nm,identifier_value=v)
  }
}

# Scopus: inspect all ID-like fields in a STANDARD 20-record result.
skey <- Sys.getenv("SCOPUS_API_TOKEN","")
stoken <- Sys.getenv("SCOPUS_INSTTOKEN","")
if (!nzchar(skey)||!nzchar(stoken)) stop("Scopus credentials required",call.=FALSE)
sq <- as.character(plan$source_queries$scopus)
req <- request("https://api.elsevier.com/content/search/scopus") |>
  req_headers(Accept="application/json",`X-ELS-APIKey`=skey,`X-ELS-Insttoken`=stoken) |>
  req_url_query(query=sq,start=0L,count=20L,view="STANDARD") |>
  req_error(is_error=function(resp) FALSE)
resp <- req_perform(req)
if (resp_status(resp)>=400L) stop(sprintf("Scopus HTTP %d",resp_status(resp)),call.=FALSE)
sx <- fromJSON(resp_body_string(resp),simplifyVector=FALSE)
entries <- sx[["search-results"]][["entry"]] %||% list()
for (e in entries) {
  for (nm in names(e)) {
    if (grepl("id|doi|pmid|pubmed|eid|identifier",nm,ignore.case=TRUE)) {
      v <- scalar(e[[nm]])
      if (!is.null(v)) rows[[length(rows)+1L]] <- data.table(source="scopus",identifier_field=nm,identifier_value=v)
    }
  }
}

# EBSCO: inspect every UI identifier type in one 20-record response per configured DB.
uid <- Sys.getenv("EBSCO_EHOST_UID","")
pwd <- Sys.getenv("EBSCO_EHOST_PWD","")
if (!nzchar(uid)||!nzchar(pwd)) stop("EBSCO credentials required",call.=FALSE)
for (src in names(cfg$sources)) {
  db <- as.character(cfg$sources[[src]]$db_code)
  q <- as.character(plan$source_queries[[src]])
  req <- request("https://eit.ebscohost.com/Services/SearchService.asmx/Search") |>
    req_url_query(prof=uid,pwd=pwd,authType="profile",db=db,query=q,format="detailed",startrec="1",numrec="20") |>
    req_error(is_error=function(resp) FALSE)
  resp <- req_perform(req)
  if (resp_status(resp)>=400L) stop(sprintf("EBSCO %s HTTP %d",src,resp_status(resp)),call.=FALSE)
  doc <- read_xml(resp_body_raw(resp))
  uis <- xml_find_all(doc,"//*[local-name()='ui']")
  if (length(uis)) {
    for (node in uis) {
      typ <- xml_attr(node,"type")
      if (is.na(typ)||!nzchar(typ)) typ <- "(no_type)"
      val <- trimws(xml_text(node))
      if (nzchar(val)) rows[[length(rows)+1L]] <- data.table(source=src,identifier_field=typ,identifier_value=val)
    }
  }
}

out <- if(length(rows)) rbindlist(rows,fill=TRUE) else data.table(source=character(),identifier_field=character(),identifier_value=character())
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(out,output)
summary <- out[,.(n_values=.N,n_unique=uniqueN(identifier_value)),by=.(source,identifier_field)][order(source,identifier_field)]
fwrite(summary,sub("\\.csv$","_summary.csv",output))
print(summary)
