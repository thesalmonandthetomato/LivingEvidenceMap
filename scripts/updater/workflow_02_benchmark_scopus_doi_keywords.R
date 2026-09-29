#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(stringdist)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input <- arg("--input")
outdir <- arg("--output-dir","outputs/scopus_keyword_benchmark")
target_n <- as.integer(arg("--target-n","100"))
seed <- as.integer(arg("--seed","29092026"))
delay <- as.numeric(arg("--delay","0.2"))
if(is.null(input) || !file.exists(input)) stop("--input canonical JSONL is required",call.=FALSE)
if(is.na(target_n) || target_n<1L) stop("--target-n must be positive",call.=FALSE)

scopus_key <- Sys.getenv("SCOPUS_API_TOKEN")
scopus_insttoken <- Sys.getenv("SCOPUS_INSTTOKEN")
if(!nzchar(scopus_key) || !nzchar(scopus_insttoken)) stop("Scopus secrets are required",call.=FALSE)

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
    if(is.atomic(z) && !is.list(z)){
      zz <- as.character(z); zz <- zz[!is.na(zz)]
      if(length(zz)) vals <<- c(vals,zz)
      return(invisible(NULL))
    }
    if(!is.list(z)) return(invisible(NULL))
    nms <- names(z)
    if(!is.null(nms)){
      pref <- intersect(c("$","#text","text","value","keyword"),nms)
      if(length(pref)){ for(k in pref) walk(z[[k]]); return(invisible(NULL)) }
      for(k in seq_along(z)){
        key <- nms[[k]] %||% ""
        if(grepl("^@",key) || key %in% c("code","id")) next
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
keywords_missing <- function(x) length(clean_keywords(x))==0L
retained_scopus_eid <- function(r){
  mans <- r$manifestations %||% list()
  vals <- character()
  for(m in mans){
    if(!identical(tolower(clean(m$source)%||%""),"scopus")) next
    mm <- m$manifestation_metadata %||% list()
    ids <- mm$identifiers %||% list()
    sid <- mm$source_identity %||% list()
    z <- c(clean(sid$scopus_eid),clean(ids$scopus_eid))
    z <- z[!vapply(z,is.null,logical(1))]
    if(length(z)) vals <- c(vals,as.character(z))
  }
  vals <- unique(vals[nzchar(vals)])
  if(length(vals)) vals[[1L]] else NULL
}
retryable <- function(st) identical(st,429L) || st>=500L
perform <- function(req,max_attempts=4L){
  errs <- character()
  for(i in seq_len(max_attempts)){
    x <- tryCatch(req_perform(req),error=identity)
    if(!inherits(x,"error")){
      st <- resp_status(x)
      if(st<400L || !retryable(st)) return(list(resp=x,attempts=i))
      errs <- c(errs,sprintf("HTTP %d",st))
    } else errs <- c(errs,conditionMessage(x))
    if(i<max_attempts) Sys.sleep(c(1,2,4)[min(i,3L)])
  }
  stop(paste(errs,collapse=" | "),call.=FALSE)
}
epmc <- function(d){
  req <- request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    req_url_query(query=sprintf('DOI:"%s"',d),format="json",resultType="core",pageSize=5) |>
    req_headers(Accept="application/json",`User-Agent`="LivingEvidenceMap-W02-KeywordBenchmark/1.0") |>
    req_error(is_error=function(resp) FALSE)
  z <- perform(req); st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),title=NULL,doi=NULL,keywords=character()))
  dat <- resp_body_json(z$resp,simplifyVector=FALSE)
  hits <- dat$resultList$result %||% list()
  exact <- Filter(function(h) identical(norm_doi(h$doi),d),hits)
  if(!length(exact)) return(list(status=st,outcome="no_exact_doi",title=NULL,doi=NULL,keywords=character()))
  h <- exact[[1L]]
  list(status=st,outcome="exact_doi",title=clean(h$title),doi=norm_doi(h$doi),
       keywords=clean_keywords((h$keywordList%||%list())$keyword%||%NULL))
}
scopus_headers <- function(req){
  req |>
    req_headers(`X-ELS-APIKey`=scopus_key,`X-ELS-Insttoken`=scopus_insttoken,Accept="application/json") |>
    req_user_agent("LivingEvidenceMap-W02-KeywordBenchmark/1.0") |>
    req_error(is_error=function(resp) FALSE)
}
scopus_doi <- function(d){
  req <- request(paste0("https://api.elsevier.com/content/abstract/doi/",URLencode(d,reserved=TRUE))) |>
    req_url_query(view="FULL") |>
    scopus_headers()
  z <- perform(req); st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),title=NULL,doi=NULL,eid=NULL,keywords=character()))
  obj <- tryCatch(resp_body_json(z$resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(obj)) return(list(status=st,outcome="invalid_json",title=NULL,doi=NULL,eid=NULL,keywords=character()))
  rr <- obj[["abstracts-retrieval-response"]] %||% obj
  core <- rr[["coredata"]] %||% list()
  head <- (((rr[["item"]] %||% list())[["bibrecord"]] %||% list())[["head"]] %||% list())
  citation_info <- head[["citation-info"]] %||% list()
  kw_candidates <- list(
    (rr[["authkeywords"]] %||% list())[["author-keyword"]],
    (rr[["author-keywords"]] %||% list())[["author-keyword"]],
    (head[["author-keywords"]] %||% list())[["author-keyword"]],
    (citation_info[["author-keywords"]] %||% list())[["author-keyword"]]
  )
  kws <- character()
  for(k in kw_candidates) kws <- c(kws,clean_keywords(k))
  if(length(kws)) kws <- kws[!duplicated(tolower(kws))]
  list(status=st,outcome="metadata_returned",
       title=clean(core[["dc:title"]] %||% core[["title"]]),
       doi=norm_doi(core[["prism:doi"]] %||% core[["doi"]]),
       eid=clean(core[["eid"]] %||% rr[["eid"]]),
       keywords=kws)
}

# Scan only minimal candidate fields.
con <- file(input,"rt",encoding="UTF-8"); on.exit(close(con),add=TRUE)
cand <- list()
repeat{
  lines <- readLines(con,n=500L,warn=FALSE)
  if(!length(lines)) break
  for(line in lines){
    if(!nzchar(trimws(line))) next
    r <- fromJSON(line,simplifyVector=FALSE)
    d <- norm_doi((r$canonical%||%list())$doi)
    t <- clean((r$canonical%||%list())$title)
    if(is.null(d)||is.null(t)||!keywords_missing((r$canonical%||%list())$author_keywords)) next
    if(!is.null(retained_scopus_eid(r))) next
    cand[[length(cand)+1L]] <- list(
      record_id=clean((r$identity%||%list())$record_id),
      doi=d,title=t
    )
  }
}
close(con); on.exit(NULL,add=FALSE)
if(length(cand)<target_n) stop(sprintf("Only %d eligible W01 candidates",length(cand)),call.=FALSE)
set.seed(seed)
ord <- sample(seq_along(cand),length(cand),replace=FALSE)

selected <- list(); epmc_checked <- 0L; epmc_solved <- 0L; epmc_guard_fail <- 0L
for(j in ord){
  z <- cand[[j]]
  ep <- tryCatch(epmc(z$doi),error=function(e)list(status=NA_integer_,outcome="technical_error",title=NULL,doi=NULL,keywords=character(),error=conditionMessage(e)))
  epmc_checked <- epmc_checked+1L
  sim <- if(!is.null(ep$title)) title_sim(z$title,ep$title) else NA_real_
  solved <- identical(ep$doi,z$doi) && !is.na(sim) && sim>=0.90 && length(ep$keywords)>0L
  if(solved){
    epmc_solved <- epmc_solved+1L
  } else {
    if(length(ep$keywords)>0L && !(identical(ep$doi,z$doi) && !is.na(sim) && sim>=0.90)) epmc_guard_fail <- epmc_guard_fail+1L
    z$epmc_status <- ep$status
    z$epmc_outcome <- ep$outcome
    z$epmc_title_similarity <- sim
    selected[[length(selected)+1L]] <- z
    if(length(selected)>=target_n) break
  }
  Sys.sleep(delay)
}
if(length(selected)<target_n) stop(sprintf("Could select only %d post-Europe-PMC residual records",length(selected)),call.=FALSE)

results <- vector("list",length(selected))
for(i in seq_along(selected)){
  z <- selected[[i]]
  sc <- tryCatch(scopus_doi(z$doi),error=function(e)list(status=NA_integer_,outcome="technical_error",title=NULL,doi=NULL,eid=NULL,keywords=character(),error=conditionMessage(e)))
  sim <- if(!is.null(sc$title)) title_sim(z$title,sc$title) else NA_real_
  doi_ok <- identical(sc$doi,z$doi)
  title_ok <- !is.na(sim) && sim>=0.90
  has_keywords <- length(sc$keywords)>0L
  accepted <- doi_ok && title_ok && has_keywords
  results[[i]] <- c(z,list(
    scopus_status=sc$status,
    scopus_outcome=sc$outcome,
    scopus_returned_doi=sc$doi,
    scopus_eid=sc$eid,
    scopus_title=sc$title,
    scopus_title_similarity=sim,
    scopus_keyword_count=length(sc$keywords),
    scopus_author_keywords=sc$keywords,
    exact_doi=doi_ok,
    title_guard=title_ok,
    accepted=accepted
  ))
  Sys.sleep(delay)
}

n_http200 <- sum(vapply(results,function(x) identical(x$scopus_status,200L),logical(1)))
n_404 <- sum(vapply(results,function(x) identical(x$scopus_status,404L),logical(1)))
n_doi <- sum(vapply(results,function(x)isTRUE(x$exact_doi),logical(1)))
n_title <- sum(vapply(results,function(x)isTRUE(x$title_guard),logical(1)))
n_kw <- sum(vapply(results,function(x)(x$scopus_keyword_count%||%0L)>0L,logical(1)))
n_accept <- sum(vapply(results,function(x)isTRUE(x$accepted),logical(1)))
n_mismatch <- sum(vapply(results,function(x)(x$scopus_keyword_count%||%0L)>0L && !isTRUE(x$accepted),logical(1)))
kw_total <- sum(vapply(results,function(x)as.integer(x$scopus_keyword_count%||%0L),integer(1)))

dir.create(outdir,recursive=TRUE,showWarnings=FALSE)
jl <- file(file.path(outdir,"results.jsonl"),"wt",encoding="UTF-8")
for(x in results) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),jl,useBytes=TRUE)
close(jl)
tab <- do.call(rbind,lapply(results,function(x)data.frame(
  record_id=x$record_id,doi=x$doi,canonical_title=x$title,
  scopus_status=x$scopus_status%||%NA_integer_,
  returned_doi=x$scopus_returned_doi%||%"",
  title_similarity=x$scopus_title_similarity%||%NA_real_,
  keyword_count=x$scopus_keyword_count%||%0L,
  accepted=isTRUE(x$accepted),stringsAsFactors=FALSE
)))
write.csv(tab,file.path(outdir,"results.csv"),row.names=FALSE,na="")
report <- list(
  schema="living-evidence-map-w02-scopus-doi-keyword-benchmark-v1",
  status="PASS",
  seed=seed,
  target_records=target_n,
  initial_eligible_records=length(cand),
  europe_pmc_records_checked=epmc_checked,
  europe_pmc_keyword_solved_before_scopus=epmc_solved,
  europe_pmc_keyword_guard_failures=epmc_guard_fail,
  scopus_direct_doi_calls=length(results),
  scopus_http_200=n_http200,
  scopus_http_404=n_404,
  scopus_exact_doi_matches=n_doi,
  scopus_title_guard_passes=n_title,
  scopus_records_with_author_keywords=n_kw,
  scopus_accepted_keyword_records=n_accept,
  scopus_keyword_records_rejected_by_identity_guard=n_mismatch,
  accepted_keyword_yield=n_accept/target_n,
  total_author_keywords_returned=kw_total,
  input_sha256=digest(file=input,algo="sha256",serialize=FALSE),
  results_sha256=digest(file=file.path(outdir,"results.jsonl"),algo="sha256",serialize=FALSE),
  completed_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(outdir,"report.json"))
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
