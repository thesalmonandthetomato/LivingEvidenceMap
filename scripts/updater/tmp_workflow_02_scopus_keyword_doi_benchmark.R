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
input_path <- arg("--input")
audit_path <- arg("--audit")
report_path <- arg("--report")
sample_n <- as.integer(arg("--sample-n","100"))
seed <- as.integer(arg("--seed","29092026"))
delay <- as.numeric(arg("--delay","0.15"))
if(any(vapply(list(input_path,audit_path,report_path),is.null,logical(1)))) stop("Required: --input --audit --report",call.=FALSE)
if(is.na(sample_n)||sample_n<1L) stop("--sample-n must be positive",call.=FALSE)

scopus_key <- Sys.getenv("SCOPUS_API_TOKEN")
scopus_insttoken <- Sys.getenv("SCOPUS_INSTTOKEN")
if(!nzchar(scopus_key)||!nzchar(scopus_insttoken)) stop("SCOPUS_API_TOKEN and SCOPUS_INSTTOKEN are required",call.=FALSE)

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
  if(!nzchar(s)) NULL else s
}
norm_title <- function(x){
  s <- clean(x); if(is.null(s)) return(NULL)
  s <- iconv(s,from="",to="ASCII//TRANSLIT",sub="")
  if(is.na(s)) return(NULL)
  s <- tolower(s)
  s <- trimws(gsub("[^a-z0-9]+"," ",s))
  if(!nzchar(s)) NULL else s
}
title_similarity <- function(a,b){
  aa <- norm_title(a); bb <- norm_title(b)
  if(is.null(aa)||is.null(bb)) return(NA_real_)
  1-stringdist(aa,bb,method="jw",p=0.1)
}
keyword_values <- function(x){
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
      preferred <- intersect(c("$","#text","text","value","keyword"),nms)
      if(length(preferred)){for(k in preferred) walk(z[[k]]); return(invisible(NULL))}
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
keywords_missing <- function(x) length(keyword_values(x))==0L
retained_scopus_eid <- function(r){
  vals <- character()
  for(m in r$manifestations %||% list()){
    if(!identical(tolower(clean(m$source)%||%""),"scopus")) next
    mm <- m$manifestation_metadata %||% list()
    ids <- mm$identifiers %||% list()
    sid <- mm$source_identity %||% list()
    cand <- c(clean(sid$scopus_eid),clean(ids$scopus_eid))
    cand <- cand[!vapply(cand,is.null,logical(1))]
    if(length(cand)) vals <- c(vals,as.character(cand))
  }
  vals <- unique(trimws(vals[nzchar(trimws(vals))]))
  if(!length(vals)) NULL else vals[[1L]]
}
perform <- function(req,max_attempts=4L){
  errs <- character()
  for(attempt in seq_len(max_attempts)){
    resp <- tryCatch(req_perform(req),error=identity)
    if(!inherits(resp,"error")){
      st <- resp_status(resp)
      if(st<500L && st!=429L) return(list(resp=resp,attempts=attempt,errors=errs))
      errs <- c(errs,paste0("HTTP ",st))
    } else errs <- c(errs,conditionMessage(resp))
    if(attempt<max_attempts) Sys.sleep(c(1,2,4)[min(attempt,3L)])
  }
  stop(paste(errs,collapse=" | "),call.=FALSE)
}
epmc <- function(d,title){
  req <- request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    req_url_query(query=sprintf('DOI:"%s"',d),format="json",resultType="core",pageSize=5) |>
    req_headers(Accept="application/json",`User-Agent`="LivingEvidenceMap-ScopusKeywordBenchmark/1.0")
  z <- perform(req); st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),keywords=character(),title=NULL,doi=NULL,similarity=NA_real_))
  dat <- resp_body_json(z$resp,simplifyVector=FALSE)
  hits <- dat$resultList$result %||% list()
  exact <- Filter(function(h) identical(norm_doi(h$doi),d),hits)
  if(!length(exact)) return(list(status=st,outcome="no_exact_doi",keywords=character(),title=NULL,doi=NULL,similarity=NA_real_))
  h <- exact[[1L]]
  pt <- clean(h$title)
  sim <- title_similarity(title,pt)
  kws <- keyword_values((h$keywordList %||% list())$keyword %||% NULL)
  accepted <- !is.null(pt)&&!is.na(sim)&&sim>=0.90&&length(kws)
  list(status=st,outcome=if(accepted)"keywords_accepted" else if(length(kws))"keywords_title_guard_failed" else "no_keywords",
       keywords=if(accepted)kws else character(),raw_keyword_count=length(kws),title=pt,doi=norm_doi(h$doi),similarity=sim)
}
scopus_headers <- function(req){
  req |>
    req_headers(`X-ELS-APIKey`=scopus_key,`X-ELS-Insttoken`=scopus_insttoken,Accept="application/json") |>
    req_user_agent("LivingEvidenceMap-ScopusKeywordBenchmark/1.0") |>
    req_error(is_error=function(resp) FALSE)
}
scopus_direct_doi <- function(d,title){
  endpoint <- paste0("https://api.elsevier.com/content/abstract/doi/",URLencode(d,reserved=TRUE))
  req <- request(endpoint) |> req_url_query(view="META_ABS") |> scopus_headers()
  z <- perform(req); st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,outcome=paste0("http_",st),returned_doi=NULL,provider_title=NULL,similarity=NA_real_,keywords=character(),raw_keyword_count=0L,eid=NULL))
  obj <- tryCatch(resp_body_json(z$resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(obj)) return(list(status=st,outcome="invalid_json",returned_doi=NULL,provider_title=NULL,similarity=NA_real_,keywords=character(),raw_keyword_count=0L,eid=NULL))
  rr <- obj[["abstracts-retrieval-response"]] %||% obj
  core <- rr[["coredata"]] %||% list()
  rd <- norm_doi(core[["prism:doi"]] %||% core[["doi"]])
  pt <- clean(core[["dc:title"]] %||% core[["title"]])
  eid <- clean(core[["eid"]] %||% rr[["eid"]])
  candidates <- list(
    (rr[["authkeywords"]] %||% list())[["author-keyword"]],
    (rr[["author-keywords"]] %||% list())[["author-keyword"]],
    (((rr[["item"]] %||% list())[["bibrecord"]] %||% list())[["head"]] %||% list())[["author-keywords"]]
  )
  kws <- character()
  for(k in candidates) kws <- c(kws,keyword_values(k))
  if(length(kws)) kws <- kws[!duplicated(tolower(kws))]
  sim <- title_similarity(title,pt)
  doi_ok <- identical(rd,d)
  title_ok <- !is.null(pt)&&!is.na(sim)&&sim>=0.90
  accepted <- doi_ok&&title_ok&&length(kws)
  outcome <- if(!doi_ok){
    if(is.null(rd)) "returned_doi_missing" else "returned_doi_mismatch"
  } else if(!title_ok) "title_guard_failed"
  else if(!length(kws)) "exact_match_no_keywords"
  else "keywords_accepted"
  list(status=st,outcome=outcome,returned_doi=rd,provider_title=pt,similarity=sim,
       keywords=if(accepted)kws else character(),raw_keyword_count=length(kws),eid=eid)
}
read_jsonl <- function(p){
  x <- readLines(p,warn=FALSE,encoding="UTF-8"); x <- x[nzchar(trimws(x))]
  lapply(x,fromJSON,simplifyVector=FALSE)
}
write_jsonl <- function(xs,p){
  dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE)
  con <- file(p,"wt",encoding="UTF-8"); on.exit(close(con),add=TRUE)
  if(length(xs)) for(x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}

rows <- read_jsonl(input_path)
candidate_idx <- which(vapply(rows,function(r){
  can <- r$canonical %||% list()
  !is.null(norm_doi(can$doi)) && !is.null(clean(can$title)) &&
    keywords_missing(can$author_keywords) && is.null(retained_scopus_eid(r))
},logical(1)))
if(length(candidate_idx)<sample_n) stop(sprintf("Only %d eligible candidates",length(candidate_idx)),call.=FALSE)

set.seed(seed)
candidate_idx <- sample(candidate_idx,length(candidate_idx),replace=FALSE)
audit <- list()
scopus_candidates <- list()
epmc_checked <- 0L
epmc_keyword_fills <- 0L

for(ix in candidate_idx){
  r <- rows[[ix]]
  rid <- clean((r$identity %||% list())$record_id)
  d <- norm_doi((r$canonical %||% list())$doi)
  title <- clean((r$canonical %||% list())$title)
  epmc_checked <- epmc_checked+1L
  ep <- tryCatch(epmc(d,title),error=function(e) list(status=NULL,outcome="technical_error",keywords=character(),raw_keyword_count=0L,title=NULL,doi=NULL,similarity=NA_real_,error=conditionMessage(e)))
  if(length(ep$keywords)){
    epmc_keyword_fills <- epmc_keyword_fills+1L
    audit[[length(audit)+1L]] <- list(record_id=rid,doi=d,stage="europe_pmc",selected_for_scopus=FALSE,europe_pmc=ep)
  } else {
    scopus_candidates[[length(scopus_candidates)+1L]] <- list(record_id=rid,doi=d,title=title,europe_pmc=ep)
    if(length(scopus_candidates)>=sample_n) break
  }
  Sys.sleep(delay)
}
if(length(scopus_candidates)<sample_n) stop(sprintf("Could construct only %d post-Europe-PMC Scopus candidates",length(scopus_candidates)),call.=FALSE)

scopus_status <- integer()
accepted <- 0L
exact_doi <- 0L
title_pass <- 0L
raw_keywords <- 0L
doi_mismatch <- 0L
title_mismatch <- 0L
technical <- 0L
for(x in scopus_candidates){
  sc <- tryCatch(scopus_direct_doi(x$doi,x$title),error=function(e) list(status=NULL,outcome="technical_error",returned_doi=NULL,provider_title=NULL,similarity=NA_real_,keywords=character(),raw_keyword_count=0L,eid=NULL,error=conditionMessage(e)))
  if(identical(sc$outcome,"technical_error")) technical<-technical+1L
  if(!is.null(sc$status)) scopus_status <- c(scopus_status,as.integer(sc$status))
  if(identical(sc$returned_doi,x$doi)) exact_doi<-exact_doi+1L
  if(!is.na(sc$similarity) && sc$similarity>=0.90) title_pass<-title_pass+1L
  if((sc$raw_keyword_count %||% 0L)>0L) raw_keywords<-raw_keywords+1L
  if(identical(sc$outcome,"returned_doi_mismatch")) doi_mismatch<-doi_mismatch+1L
  if(identical(sc$outcome,"title_guard_failed")) title_mismatch<-title_mismatch+1L
  if(length(sc$keywords)) accepted<-accepted+1L
  audit[[length(audit)+1L]] <- list(record_id=x$record_id,doi=x$doi,stage="scopus_direct_doi",selected_for_scopus=TRUE,europe_pmc=x$europe_pmc,scopus=sc)
  Sys.sleep(delay)
}

http_counts <- as.list(table(scopus_status))
report <- list(
  schema="living-evidence-map-scopus-keyword-doi-benchmark-v1",
  status="PASS",
  input_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  seed=seed,
  candidate_pool=length(candidate_idx),
  eligibility="DOI + canonical title + missing canonical author_keywords + no retained Scopus EID",
  scopus_sample_n=sample_n,
  europe_pmc_records_checked=epmc_checked,
  europe_pmc_keyword_fills_before_scopus=epmc_keyword_fills,
  scopus_direct_doi_records=sample_n,
  scopus_http_status_counts=http_counts,
  scopus_exact_doi_returns=exact_doi,
  scopus_title_guard_passes=title_pass,
  scopus_records_returning_author_keywords=raw_keywords,
  scopus_author_keyword_fills_accepted=accepted,
  scopus_author_keyword_yield=accepted/sample_n,
  scopus_doi_mismatches=doi_mismatch,
  scopus_title_mismatches=title_mismatch,
  scopus_technical_errors=technical,
  policy="direct Scopus Abstract Retrieval by DOI only; accept author keywords only with exact returned DOI and title similarity >=0.90",
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_jsonl(audit,audit_path)
dir.create(dirname(report_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),report_path,useBytes=TRUE)
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
