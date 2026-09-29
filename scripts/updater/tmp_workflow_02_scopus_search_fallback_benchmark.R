#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(stringdist)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input <- arg("--input")
outdir <- arg("--output-dir","outputs/scopus_search_fallback")
target_n <- as.integer(arg("--target-n","50"))
delay <- as.numeric(arg("--delay","0.2"))
if(is.null(input)||!file.exists(input)) stop("--input results JSONL is required",call.=FALSE)

api_key <- Sys.getenv("SCOPUS_API_TOKEN")
insttoken <- Sys.getenv("SCOPUS_INSTTOKEN")
if(!nzchar(api_key)||!nzchar(insttoken)) stop("Scopus secrets are required",call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
clean <- function(x){
  if(is.null(x)||!length(x)) return(NULL)
  s <- trimws(gsub("[[:space:]]+"," ",as.character(x[[1L]])))
  if(is.na(s)||!nzchar(s)) NULL else s
}
norm_doi <- function(x){
  s <- clean(x); if(is.null(s)) return(NULL)
  s <- tolower(s)
  s <- sub("^https?://(dx\\.)?doi\\.org/","",s,perl=TRUE)
  s <- sub("^doi:\\s*","",s,perl=TRUE)
  s <- sub("[[:space:][:punct:]]+$","",s)
  if(nzchar(s)) s else NULL
}
norm_title <- function(x){
  s <- clean(x); if(is.null(s)) return(NULL)
  s <- iconv(s,from="",to="ASCII//TRANSLIT",sub="")
  if(is.na(s)) return(NULL)
  s <- tolower(trimws(gsub("[^a-z0-9]+"," ",s)))
  if(nzchar(s)) s else NULL
}
title_sim <- function(a,b){
  aa <- norm_title(a); bb <- norm_title(b)
  if(is.null(aa)||is.null(bb)) return(NA_real_)
  1-stringdist(aa,bb,method="jw",p=0.1)
}
clean_keywords <- function(x){
  vals <- character()
  walk <- function(z){
    if(is.null(z)) return(invisible(NULL))
    if(is.atomic(z)&&!is.list(z)){
      zz <- as.character(z); zz <- zz[!is.na(zz)]
      vals <<- c(vals,zz); return(invisible(NULL))
    }
    if(!is.list(z)) return(invisible(NULL))
    nms <- names(z)
    if(!is.null(nms)){
      pref <- intersect(c("$","#text","text","value","keyword"),nms)
      if(length(pref)){for(k in pref) walk(z[[k]]); return(invisible(NULL))}
      for(k in seq_along(z)){
        key <- nms[[k]] %||% ""
        if(grepl("^@",key)||key %in% c("code","id")) next
        walk(z[[k]])
      }
    } else for(v in z) walk(v)
    invisible(NULL)
  }
  walk(x)
  vals <- trimws(gsub("[[:space:]]+"," ",vals))
  vals <- vals[nzchar(vals)]
  if(!length(vals)) character() else vals[!duplicated(tolower(vals))]
}
headers <- function(req){
  req |>
    req_headers(`X-ELS-APIKey`=api_key,`X-ELS-Insttoken`=insttoken,Accept="application/json") |>
    req_user_agent("LivingEvidenceMap-W02-SearchFallbackBenchmark/1.0") |>
    req_error(is_error=function(resp) FALSE)
}
perform <- function(req,max_attempts=4L){
  for(i in seq_len(max_attempts)){
    x <- tryCatch(req_perform(req),error=identity)
    if(!inherits(x,"error")){
      st <- resp_status(x)
      if(st<500L && st!=429L) return(x)
    }
    if(i<max_attempts) Sys.sleep(c(1,2,4)[min(i,3L)])
  }
  stop("Provider failed after retries",call.=FALSE)
}
extract_eid <- function(e){
  vals <- c(clean(e[["eid"]]),clean(e[["dc:identifier"]]),clean(e[["scopus-id"]]),clean(e[["scopus_id"]]))
  vals <- vals[!vapply(vals,is.null,logical(1))]
  if(!length(vals)) return(character())
  norm <- function(x){
    y <- trimws(as.character(x))
    y <- sub("^SCOPUS_ID:\\s*","",y,ignore.case=TRUE,perl=TRUE)
    y <- sub("^EID:\\s*","",y,ignore.case=TRUE,perl=TRUE)
    if(grepl("^2-s2\\.0-",y,ignore.case=TRUE)) return(y)
    if(grepl("^[0-9]+$",y)) return(paste0("2-s2.0-",y))
    y
  }
  unique(vapply(vals,norm,character(1)))
}
search_doi <- function(d){
  req <- request("https://api.elsevier.com/content/search/scopus") |>
    req_url_query(query=sprintf("DOI(%s)",d),count=5,view="STANDARD") |>
    headers()
  resp <- perform(req); st <- resp_status(resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),entries=list()))
  obj <- tryCatch(resp_body_json(resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(obj)) return(list(status=st,outcome="invalid_json",entries=list()))
  sr <- obj[["search-results"]] %||% list()
  entries <- sr[["entry"]] %||% list()
  total_raw <- sr[["opensearch:totalResults"]] %||% "0"
  total <- suppressWarnings(as.integer(as.character(total_raw[[1L]] %||% total_raw)))
  if(is.na(total)||total<=0L) return(list(status=st,outcome="no_hits",entries=list()))
  entries <- Filter(function(e){
    is.list(e) && any(c("eid","dc:identifier","scopus-id","scopus_id","dc:title","prism:doi") %in% names(e))
  },entries)
  list(status=st,outcome=if(length(entries))"search_hits" else "no_usable_entries",entries=entries)
}
eid_full <- function(eid){
  req <- request(paste0("https://api.elsevier.com/content/abstract/eid/",URLencode(eid,reserved=TRUE))) |>
    req_url_query(view="FULL") |>
    headers()
  resp <- perform(req); st <- resp_status(resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),title=NULL,doi=NULL,eid=eid,keywords=character()))
  obj <- tryCatch(resp_body_json(resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(obj)) return(list(status=st,outcome="invalid_json",title=NULL,doi=NULL,eid=eid,keywords=character()))
  rr <- obj[["abstracts-retrieval-response"]] %||% obj
  core <- rr[["coredata"]] %||% list()
  head <- (((rr[["item"]] %||% list())[["bibrecord"]] %||% list())[["head"]] %||% list())
  citation_info <- head[["citation-info"]] %||% list()
  nodes <- list(
    (rr[["authkeywords"]] %||% list())[["author-keyword"]],
    (rr[["author-keywords"]] %||% list())[["author-keyword"]],
    (head[["author-keywords"]] %||% list())[["author-keyword"]],
    (citation_info[["author-keywords"]] %||% list())[["author-keyword"]]
  )
  kws <- character()
  for(k in nodes) kws <- c(kws,clean_keywords(k))
  if(length(kws)) kws <- kws[!duplicated(tolower(kws))]
  list(status=st,outcome="metadata_returned",
       title=clean(core[["dc:title"]] %||% core[["title"]]),
       doi=norm_doi(core[["prism:doi"]] %||% core[["doi"]]),
       eid=clean(core[["eid"]] %||% rr[["eid"]]) %||% eid,
       keywords=kws)
}

lines <- readLines(input,warn=FALSE,encoding="UTF-8")
rows <- lapply(lines[nzchar(trimws(lines))],fromJSON,simplifyVector=FALSE)
rows404 <- Filter(function(x) identical(as.integer(x$scopus_status %||% NA_integer_),404L),rows)
if(length(rows404)<target_n) stop(sprintf("Only %d direct-DOI 404 records available",length(rows404)),call.=FALSE)
sample <- rows404[seq_len(target_n)]

out <- list()
for(x in sample){
  sr <- tryCatch(search_doi(x$doi),error=function(e)list(status=NA_integer_,outcome="technical_error",entries=list(),error=conditionMessage(e)))
  entries <- sr$entries %||% list()
  entry_dois <- if(length(entries)) vapply(entries,function(e) norm_doi(e[["prism:doi"]] %||% e[["doi"]]) %||% "",character(1)) else character()
  exact_idx <- which(nzchar(entry_dois)&entry_dois==x$doi)
  candidates <- if(length(exact_idx)) entries[exact_idx] else if(length(entries)==1L) entries else list()
  eids <- unique(unlist(lapply(candidates,extract_eid),use.names=FALSE))
  eids <- eids[nzchar(eids)]
  er <- NULL
  if(length(eids)==1L){
    er <- tryCatch(eid_full(eids[[1L]]),error=function(e)list(status=NA_integer_,outcome="technical_error",title=NULL,doi=NULL,eid=eids[[1L]],keywords=character(),error=conditionMessage(e)))
  }
  sim <- if(!is.null(er)&&!is.null(er$title)) title_sim(x$canonical_title,er$title) else NA_real_
  doi_ok <- !is.null(er)&&identical(er$doi,x$doi)
  title_ok <- !is.na(sim)&&sim>=0.90
  has_kw <- !is.null(er)&&length(er$keywords)>0L
  accepted <- doi_ok&&title_ok&&has_kw
  out[[length(out)+1L]] <- list(
    record_id=x$record_id,doi=x$doi,canonical_title=x$canonical_title,
    search_status=sr$status%||%NA_integer_,search_outcome=sr$outcome%||%NULL,
    search_entries=length(entries),candidate_eids=eids,
    eid_retrieval=er,title_similarity=sim,exact_doi=doi_ok,title_guard=title_ok,
    keyword_count=if(is.null(er))0L else length(er$keywords),accepted=accepted
  )
  Sys.sleep(delay)
}

count <- function(fun) sum(vapply(out,fun,logical(1)))
report <- list(
  schema="living-evidence-map-w02-scopus-search-fallback-benchmark-v1",
  status="PASS",
  sample_n=target_n,
  source="direct DOI FULL benchmark 36608275103; first 50 HTTP 404 records",
  search_hits=count(function(x) identical(x$search_outcome,"search_hits")),
  unique_eid_candidates=count(function(x) length(x$candidate_eids)==1L),
  eid_retrieval_http_200=count(function(x) !is.null(x$eid_retrieval)&&identical(x$eid_retrieval$status,200L)),
  exact_doi_matches=count(function(x)isTRUE(x$exact_doi)),
  title_guard_passes=count(function(x)isTRUE(x$title_guard)),
  records_with_author_keywords=count(function(x)(x$keyword_count%||%0L)>0L),
  accepted_keyword_records=count(function(x)isTRUE(x$accepted)),
  accepted_yield=count(function(x)isTRUE(x$accepted))/target_n,
  technical_errors=count(function(x) identical(x$search_outcome,"technical_error") || (!is.null(x$eid_retrieval)&&identical(x$eid_retrieval$outcome,"technical_error"))),
  completed_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
dir.create(outdir,recursive=TRUE,showWarnings=FALSE)
con <- file(file.path(outdir,"results.jsonl"),"wt",encoding="UTF-8")
for(x in out) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
close(con)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(outdir,"report.json"))
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
