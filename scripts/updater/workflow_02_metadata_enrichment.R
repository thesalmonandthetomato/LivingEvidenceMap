#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(stringdist)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

input_path <- arg("--input")
output_path <- arg("--output")
audit_path <- arg("--audit")
report_path <- arg("--report")
limit_arg <- arg("--limit",NULL)
delay <- as.numeric(arg("--delay","0.2"))
recheck_after_days <- as.numeric(arg("--recheck-after-days","90"))
if(is.na(recheck_after_days) || recheck_after_days < 0) stop("--recheck-after-days must be >= 0",call.=FALSE)
if(any(vapply(list(input_path,output_path,audit_path,report_path),is.null,logical(1)))) {
  stop("Required: --input --output --audit --report",call.=FALSE)
}
limit <- if(is.null(limit_arg)) Inf else as.integer(limit_arg)
if(!is.infinite(limit) && (is.na(limit)||limit<1L)) stop("--limit must be positive",call.=FALSE)

scopus_key <- Sys.getenv("SCOPUS_API_TOKEN")
scopus_insttoken <- Sys.getenv("SCOPUS_INSTTOKEN")
if(!nzchar(scopus_key)) stop("SCOPUS_API_TOKEN is required",call.=FALSE)
if(!nzchar(scopus_insttoken)) stop("SCOPUS_INSTTOKEN is required",call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

clean_text <- function(x){
  if(is.null(x)||!length(x)) return(NULL)
  s <- trimws(gsub("[[:space:]]+"," ",as.character(x[[1L]])))
  if(is.na(s)||!nzchar(s)) NULL else s
}
norm_doi <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  s <- tolower(s)
  s <- sub("^https?://(dx\\.)?doi\\.org/","",s,perl=TRUE)
  s <- sub("^doi:\\s*","",s,perl=TRUE)
  s <- sub("[[:space:]]+$","",s)
  s <- sub("[[:space:][:punct:]]+$","",s)
  if(!nzchar(s)) NULL else s
}
norm_title <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  s <- iconv(s,from="",to="ASCII//TRANSLIT",sub="")
  if(is.na(s)) return(NULL)
  s <- tolower(s)
  s <- trimws(gsub("[^a-z0-9]+"," ",s))
  if(!nzchar(s)) NULL else s
}
title_similarity <- function(a,b){
  aa <- norm_title(a); bb <- norm_title(b)
  if(is.null(aa)||is.null(bb)) return(NA_real_)
  1 - stringdist(aa,bb,method="jw",p=0.1)
}
norm_simple <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  s <- iconv(s,from="",to="ASCII//TRANSLIT",sub="")
  if(is.na(s)) return(NULL)
  s <- tolower(s)
  s <- trimws(gsub("[^a-z0-9]+"," ",s))
  if(!nzchar(s)) NULL else s
}
norm_compact <- function(x){
  s <- norm_simple(x)
  if(is.null(s)) NULL else gsub(" ","",s,fixed=TRUE)
}
year_value <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  m <- regexpr("(18|19|20|21)[0-9]{2}",s,perl=TRUE)
  if(m[[1L]]<0L) return(NULL)
  as.integer(regmatches(s,m)[[1L]])
}
author_surnames <- function(x){
  if(is.null(x)||!length(x)) return(character())
  one <- function(z){
    if(is.character(z)) s <- clean_text(z)
    else if(is.list(z)) s <- clean_text(z$surname %||% z$last_name %||% z$family %||% z$fullName %||% z$full_name %||% z$name %||% z$display_name)
    else s <- NULL
    if(is.null(s)) return("")
    s <- iconv(s,from="",to="ASCII//TRANSLIT",sub="")
    if(is.na(s)) return("")
    s <- tolower(trimws(s))
    # For full-name strings, the final token is the most portable surname proxy.
    parts <- unlist(strsplit(gsub("[^a-z0-9 -]+"," ",s),"[[:space:]-]+"))
    parts <- parts[nzchar(parts)]
    if(!length(parts)) "" else tail(parts,1L)
  }
  vals <- if(is.character(x)) vapply(as.list(x),one,character(1)) else vapply(x,one,character(1))
  unique(vals[nzchar(vals)])
}
field_values <- function(r,name){
  vals <- list((r$canonical %||% list())[[name]])
  mans <- r$manifestations %||% list()
  if(length(mans)) vals <- c(vals,lapply(mans,function(m)m[[name]]))
  vals
}
compare_text_any <- function(provider_value,record_values){
  p <- norm_compact(provider_value)
  if(is.null(p)) return("missing")
  vals <- unique(Filter(Negate(is.null),lapply(record_values,norm_compact)))
  if(!length(vals)) return("missing")
  if(any(vals==p)) "support" else "conflict"
}
compare_year_any <- function(provider_value,record_values){
  p <- year_value(provider_value)
  if(is.null(p)) return("missing")
  vals <- unique(na.omit(vapply(record_values,function(z){y<-year_value(z);if(is.null(y))NA_integer_ else y},integer(1))))
  if(!length(vals)) return("missing")
  if(any(abs(vals-p)<=1L)) "support" else "conflict"
}
compare_authors_any <- function(provider_authors,record_values){
  p <- author_surnames(provider_authors)
  if(!length(p)) return("missing")
  vals <- unique(unlist(lapply(record_values,author_surnames),use.names=FALSE))
  vals <- vals[nzchar(vals)]
  if(!length(vals)) return("missing")
  # Require at least one shared surname. First-author agreement is retained separately in audit.
  if(length(intersect(p,vals))>0L) "support" else "conflict"
}
bibliographic_concordance <- function(r,provider){
  statuses <- c(
    authors=compare_authors_any(provider$authors,field_values(r,"authors")),
    year=compare_year_any(provider$year,field_values(r,"year")),
    journal=compare_text_any(provider$journal,field_values(r,"journal")),
    volume=compare_text_any(provider$volume,field_values(r,"volume")),
    issue=compare_text_any(provider$issue,field_values(r,"issue")),
    pages=compare_text_any(provider$pages,field_values(r,"pages"))
  )
  comparable <- statuses!="missing"
  support <- names(statuses)[statuses=="support"]
  conflict <- names(statuses)[statuses=="conflict"]
  high_specificity <- intersect(support,c("authors","journal","volume","pages"))
  accept <- sum(comparable)>=2L && length(support)>=2L && length(conflict)==0L && length(high_specificity)>=1L
  list(
    accept=accept,
    statuses=as.list(statuses),
    comparable_fields=sum(comparable),
    supporting_fields=support,
    conflicting_fields=conflict,
    high_specificity_support=high_specificity
  )
}
metadata_match_decision <- function(r,provider){
  sim <- title_similarity((r$canonical %||% list())$title,provider$title)
  title_pass <- is.null(provider$title) || is_missing((r$canonical %||% list())$title) || is.na(sim) || sim>=0.90
  bib <- bibliographic_concordance(r,provider)
  list(
    accept=title_pass || isTRUE(bib$accept),
    route=if(title_pass)"title_guard_pass" else if(isTRUE(bib$accept))"bibliographic_concordance" else "quarantine",
    title_similarity=sim,
    bibliographic=bib
  )
}
clean_abstract <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  s <- gsub("<!\\[CDATA\\[(.*?)\\]\\]>","\\1",s,perl=TRUE)
  s <- gsub("<[^>]+>"," ",s,perl=TRUE)
  s <- gsub("&amp;","&",s,fixed=TRUE)
  s <- gsub("&lt;","<",s,fixed=TRUE)
  s <- gsub("&gt;",">",s,fixed=TRUE)
  s <- gsub("&quot;","\"",s,fixed=TRUE)
  s <- gsub("&#39;","'",s,fixed=TRUE)
  s <- trimws(gsub("[[:space:]]+"," ",s))
  if(!nzchar(s)) NULL else substr(s,1L,12000L)
}
is_missing <- function(x) is.null(clean_text(x))

retryable <- function(status) identical(status,429L) || status>=500L
perform_retry <- function(req,max_attempts=4L){
  errors <- character()
  for(attempt in seq_len(max_attempts)){
    resp <- tryCatch(req_perform(req),error=identity)
    if(!inherits(resp,"error")){
      st <- resp_status(resp)
      if(st<400L || !retryable(st)) return(list(resp=resp,attempts=attempt,errors=errors))
      errors <- c(errors,sprintf("HTTP %d",st))
    } else errors <- c(errors,conditionMessage(resp))
    if(attempt<max_attempts) Sys.sleep(c(1,2,4)[min(attempt,3L)])
  }
  stop(sprintf("Provider failed after %d attempts: %s",max_attempts,paste(errors,collapse=" | ")),call.=FALSE)
}

epmc_lookup <- function(d){
  req <- request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    req_url_query(query=sprintf('DOI:"%s"',d),format="json",resultType="core",pageSize=5) |>
    req_headers(Accept="application/json",`User-Agent`="LivingEvidenceMap-Workflow02/1.0")
  z <- perform_retry(req)
  st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,title=NULL,abstract=NULL,returned_doi=NULL,outcome=paste0("http_",st),attempts=z$attempts))
  dat <- resp_body_json(z$resp,simplifyVector=FALSE)
  hits <- dat$resultList$result %||% list()
  exact <- Filter(function(h) identical(norm_doi(h$doi),d),hits)
  if(!length(exact)) return(list(status=st,title=NULL,abstract=NULL,returned_doi=NULL,outcome="no_exact_doi_match",attempts=z$attempts))
  h <- exact[[1L]]
  authors <- (h$authorList %||% list())$author %||% list()
  journal_info <- h$journalInfo %||% list()
  journal_obj <- journal_info$journal %||% list()
  list(
    status=st,
    title=clean_text(h$title),
    abstract=clean_abstract(h$abstractText),
    returned_doi=norm_doi(h$doi),
    authors=authors,
    year=h$pubYear %||% h$firstPublicationDate,
    journal=clean_text(journal_obj$title %||% h$journalTitle),
    volume=clean_text(journal_info$volume %||% h$journalVolume),
    issue=clean_text(journal_info$issue %||% h$issue),
    pages=clean_text(h$pageInfo %||% h$page),
    outcome=if(!is.null(clean_abstract(h$abstractText))||!is.null(clean_text(h$title)))"exact_doi_metadata_returned" else "exact_doi_no_metadata",
    attempts=z$attempts
  )
}

scopus_extract <- function(obj){
  rr <- obj[["abstracts-retrieval-response"]] %||% obj
  core <- rr[["coredata"]] %||% list()
  title <- clean_text(core[["dc:title"]] %||% core[["title"]])
  doi <- norm_doi(core[["prism:doi"]] %||% core[["doi"]])
  eid <- clean_text(core[["eid"]] %||% rr[["eid"]])
  abstract <- clean_abstract(core[["dc:description"]] %||% core[["description"]])
  if(is.null(abstract)){
    item <- rr[["item"]]
    if(!is.null(item)){
      biblio <- (item[["bibrecord"]] %||% list())[["head"]]
      biblio <- (biblio %||% list())[["abstracts"]]
      if(is.null(biblio)) biblio <- ((item[["bibliography"]] %||% list())[["abstracts"]])
      if(!is.null(biblio)) abstract <- clean_abstract(paste(unlist(biblio,use.names=FALSE),collapse=" "))
    }
  }
  authors_obj <- rr[["authors"]] %||% list()
  authors <- authors_obj[["author"]] %||% list()
  if(!length(authors)){
    creator <- core[["dc:creator"]] %||% core[["creator"]]
    if(!is.null(creator)) authors <- as.list(creator)
  }
  list(
    title=title,abstract=abstract,doi=doi,eid=eid,
    authors=authors,
    year=core[["prism:coverDate"]] %||% core[["prism:coverDisplayDate"]] %||% core[["coverDate"]],
    journal=clean_text(core[["prism:publicationName"]] %||% core[["publicationName"]]),
    volume=clean_text(core[["prism:volume"]] %||% core[["volume"]]),
    issue=clean_text(core[["prism:issueIdentifier"]] %||% core[["issueIdentifier"]]),
    pages=clean_text(core[["prism:pageRange"]] %||% core[["pageRange"]] %||% core[["article-number"]])
  )
}

scopus_headers <- function(req) {
  req |>
    req_headers(
      `X-ELS-APIKey`=scopus_key,
      `X-ELS-Insttoken`=scopus_insttoken,
      Accept="application/json"
    ) |>
    req_user_agent("LivingEvidenceMap-Workflow02/1.0") |>
    req_error(is_error=function(resp) FALSE)
}

extract_scopus_eid <- function(entry){
  vals <- c(
    clean_text(entry[["eid"]]),
    clean_text(entry[["dc:identifier"]]),
    clean_text(entry[["scopus-id"]]),
    clean_text(entry[["scopus_id"]])
  )
  vals <- vals[!vapply(vals,is.null,logical(1))]
  vals <- trimws(as.character(vals))
  vals <- vals[nzchar(vals)]
  if(!length(vals)) return(NULL)

  normalise_id <- function(x){
    y <- trimws(x)
    y <- sub("^SCOPUS_ID:\\s*","",y,ignore.case=TRUE,perl=TRUE)
    y <- sub("^EID:\\s*","",y,ignore.case=TRUE,perl=TRUE)
    if(grepl("^2-s2\\.0-",y,ignore.case=TRUE)) return(y)
    if(grepl("^[0-9]+$",y)) return(paste0("2-s2.0-",y))
    y
  }

  vals <- unique(vapply(vals,normalise_id,character(1)))
  vals <- vals[nzchar(vals)]
  if(!length(vals)) NULL else vals
}

scopus_search_doi <- function(d){
  req <- request("https://api.elsevier.com/content/search/scopus") |>
    req_url_query(query=sprintf("DOI(%s)",d),count=5,view="STANDARD") |>
    scopus_headers()
  z <- perform_retry(req)
  st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,entries=list(),outcome=paste0("http_",st),attempts=z$attempts))
  parsed <- tryCatch(resp_body_json(z$resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(parsed)) return(list(status=st,entries=list(),outcome="invalid_json",attempts=z$attempts))
  sr <- parsed[["search-results"]] %||% list()
  total_raw <- sr[["opensearch:totalResults"]] %||% sr[["totalResults"]] %||% "0"
  total <- suppressWarnings(as.integer(as.character(total_raw[[1L]] %||% total_raw)))
  if(is.na(total)) total <- 0L
  entries <- sr[["entry"]] %||% list()

  # Elsevier may return HTTP 200 with an entry-like error/empty object even when
  # totalResults is zero. Treat totalResults as authoritative for presence.
  if(total <= 0L) {
    return(list(status=st,entries=list(),total_results=0L,outcome="no_hits",attempts=z$attempts))
  }

  # Keep only genuine record-like entries. Error-only objects are not Scopus hits.
  if(is.list(entries) && length(entries)) {
    looks_like_record <- function(e) {
      if(!is.list(e)) return(FALSE)
      has_id <- any(c("eid","dc:identifier","scopus-id","scopus_id") %in% names(e))
      has_biblio <- any(c("dc:title","prism:doi","prism:publicationName") %in% names(e))
      !(!is.null(e[["error"]]) && !has_id && !has_biblio) && (has_id || has_biblio)
    }
    entries <- Filter(looks_like_record, entries)
  }

  list(
    status=st,
    entries=entries,
    total_results=total,
    outcome=if(length(entries))"search_hits" else "total_results_without_usable_entry",
    attempts=z$attempts
  )
}

scopus_lookup_eid <- function(eid){
  endpoint <- paste0("https://api.elsevier.com/content/abstract/eid/",URLencode(eid,reserved=TRUE))
  req <- request(endpoint) |>
    req_url_query(view="META_ABS") |>
    scopus_headers()
  z <- perform_retry(req)
  st <- resp_status(z$resp)
  if(st>=400L) return(list(status=st,title=NULL,abstract=NULL,returned_doi=NULL,eid=eid,outcome=paste0("http_",st),attempts=z$attempts))
  parsed <- tryCatch(resp_body_json(z$resp,simplifyVector=FALSE),error=function(e)NULL)
  if(is.null(parsed)) return(list(status=st,title=NULL,abstract=NULL,returned_doi=NULL,eid=eid,outcome="invalid_json",attempts=z$attempts))
  ex <- scopus_extract(parsed)
  list(status=st,title=ex$title,abstract=ex$abstract,returned_doi=ex$doi,eid=ex$eid %||% eid,
       authors=ex$authors,year=ex$year,journal=ex$journal,volume=ex$volume,issue=ex$issue,pages=ex$pages,
       outcome=if(!is.null(ex$title)||!is.null(ex$abstract))"metadata_returned" else "success_no_metadata",
       attempts=z$attempts)
}

scopus_lookup <- function(d){
  endpoint <- paste0("https://api.elsevier.com/content/abstract/doi/",URLencode(d,reserved=TRUE))
  req <- request(endpoint) |>
    req_url_query(view="META_ABS") |>
    scopus_headers()
  z <- perform_retry(req)
  st <- resp_status(z$resp)
  if(st>=200L && st<400L){
    parsed <- tryCatch(resp_body_json(z$resp,simplifyVector=FALSE),error=function(e)NULL)
    if(!is.null(parsed)){
      ex <- scopus_extract(parsed)
      if(!is.null(ex$title) || !is.null(ex$abstract) || !is.null(ex$doi)){
        return(list(status=st,title=ex$title,abstract=ex$abstract,returned_doi=ex$doi,eid=ex$eid,
                    authors=ex$authors,year=ex$year,journal=ex$journal,volume=ex$volume,issue=ex$issue,pages=ex$pages,
                    outcome="direct_doi_metadata_returned",attempts=z$attempts,route="direct_doi"))
      }
    }
  }

  # DOI endpoint may miss records that are still indexed in Scopus. Search by DOI,
  # then retrieve the uniquely compatible hit by EID using META_ABS.
  sr <- scopus_search_doi(d)
  if(!length(sr$entries)){
    return(list(status=st,title=NULL,abstract=NULL,returned_doi=NULL,eid=NULL,
                outcome=paste0("direct_",ifelse(st>=400L,paste0("http_",st),"no_metadata"),";search_",sr$outcome),
                attempts=z$attempts+sr$attempts,route="doi_then_search"))
  }

  # DOI search responses do not reliably expose prism:doi in every returned
  # entry/view. If the search result itself exposes DOI, use it to narrow. If it
  # does not, a single search hit may still be followed to EID, but the full
  # META_ABS record must then return the exact requested DOI before it is usable.
  entry_dois <- vapply(sr$entries,function(e){
    norm_doi(e[["prism:doi"]] %||% e[["doi"]]) %||% ""
  },character(1))
  exact_idx <- which(nzchar(entry_dois) & entry_dois==d)
  candidates <- if(length(exact_idx)) sr$entries[exact_idx] else if(length(sr$entries)==1L) sr$entries else list()

  if(!length(candidates)){
    return(list(status=sr$status,title=NULL,abstract=NULL,returned_doi=NULL,eid=NULL,
                outcome=if(any(nzchar(entry_dois)))"search_hits_no_exact_doi" else "search_hits_nonunique_without_doi",
                attempts=z$attempts+sr$attempts,route="doi_then_search"))
  }

  candidate_eids <- unlist(lapply(candidates,extract_scopus_eid),use.names=FALSE)
  candidate_eids <- unique(candidate_eids[nzchar(candidate_eids)])
  if(length(candidate_eids)!=1L){
    return(list(status=sr$status,title=NULL,abstract=NULL,returned_doi=NULL,eid=NULL,
                outcome=if(!length(candidate_eids))"search_candidate_missing_eid" else "search_candidate_nonunique_eid",
                attempts=z$attempts+sr$attempts,route="doi_then_search"))
  }

  er <- scopus_lookup_eid(candidate_eids[[1L]])
  er$route <- "doi_then_search_eid"
  er$attempts <- z$attempts + sr$attempts + (er$attempts %||% 0L)
  if(!identical(er$returned_doi,d)){
    er$title <- NULL
    er$abstract <- NULL
    er$outcome <- if(is.null(er$returned_doi))"eid_retrieval_no_doi" else "eid_retrieval_doi_mismatch"
  }
  er
}

read_jsonl <- function(path){
  lines <- readLines(path,warn=FALSE,encoding="UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines),function(i)tryCatch(fromJSON(lines[[i]],simplifyVector=FALSE),
    error=function(e)stop(sprintf("Invalid JSON line %d: %s",i,conditionMessage(e)),call.=FALSE)))
}
write_jsonl <- function(xs,path){
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for(x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}

rows <- read_jsonl(input_path)
input_sha <- digest(file=input_path,algo="sha256",serialize=FALSE)
audit <- list()
counts <- list(
  total_records=length(rows),
  eligible_doi_missing_metadata=0L,
  europepmc_title_filled=0L,
  europepmc_abstract_filled=0L,
  scopus_attempted=0L,
  scopus_title_filled=0L,
  scopus_abstract_filled=0L,
  scopus_http_404=0L,
  conflicts_quarantined=0L,
  still_missing_after=0L,
  deferred_recent_attempts=0L,
  technical_error_records=0L
)
processed_eligible <- 0L

previous_attempt_due <- function(meta){
  if(is.null(meta) || !is.list(meta)) return(TRUE)
  if(isTRUE(meta$technical_error)) return(TRUE)
  completed <- clean_text(meta$completed_at)
  if(is.null(completed)) return(TRUE)
  t <- suppressWarnings(as.POSIXct(completed,tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
  if(is.na(t)) return(TRUE)
  age_days <- as.numeric(difftime(Sys.time(),t,units="days"))
  is.na(age_days) || age_days >= recheck_after_days
}

for(i in seq_along(rows)){
  r <- rows[[i]]
  if(is.null(r$canonical)) r$canonical <- list()
  d <- norm_doi(r$canonical$doi)
  missing_title_before <- is_missing(r$canonical$title)
  missing_abstract_before <- is_missing(r$canonical$abstract)
  eligible <- !is.null(d) && (missing_title_before || missing_abstract_before)
  if(!eligible) next
  counts$eligible_doi_missing_metadata <- counts$eligible_doi_missing_metadata + 1L
  if(!previous_attempt_due(r$metadata_enrichment)){
    counts$deferred_recent_attempts <- counts$deferred_recent_attempts + 1L
    next
  }
  if(processed_eligible>=limit) next
  processed_eligible <- processed_eligible + 1L

  rec_audit <- list(
    record_id=clean_text((r$identity %||% list())$record_id %||% (r$identity %||% list())$lens_id),
    doi=d,
    missing_title_before=missing_title_before,
    missing_abstract_before=missing_abstract_before,
    europe_pmc=NULL,
    scopus=NULL,
    applied=list(),
    quarantined=list()
  )

  ep <- tryCatch(epmc_lookup(d),error=function(e)list(outcome="technical_error",error=conditionMessage(e),title=NULL,abstract=NULL,returned_doi=NULL,status=NULL,attempts=NULL))
  rec_audit$europe_pmc <- ep

  if(identical(ep$returned_doi,d)){
    if(is_missing(r$canonical$title) && !is.null(ep$title)){
      r$canonical$title <- ep$title
      counts$europepmc_title_filled <- counts$europepmc_title_filled + 1L
      rec_audit$applied <- c(rec_audit$applied,list(list(provider="europe_pmc",field="title")))
    }
    if(is_missing(r$canonical$abstract) && !is.null(ep$abstract)){
      md <- metadata_match_decision(r,ep)
      if(isTRUE(md$accept)){
        r$canonical$abstract <- ep$abstract
        counts$europepmc_abstract_filled <- counts$europepmc_abstract_filled + 1L
        rec_audit$applied <- c(rec_audit$applied,list(list(
          provider="europe_pmc",field="abstract",match_route=md$route,
          title_similarity=md$title_similarity,bibliographic=md$bibliographic
        )))
      } else {
        counts$conflicts_quarantined <- counts$conflicts_quarantined + 1L
        rec_audit$quarantined <- c(rec_audit$quarantined,list(list(
          provider="europe_pmc",field="abstract",reason="insufficient_bibliographic_concordance",
          title_similarity=md$title_similarity,bibliographic=md$bibliographic
        )))
      }
    }
  }

  still_missing_title <- is_missing(r$canonical$title)
  still_missing_abstract <- is_missing(r$canonical$abstract)

  if(still_missing_title || still_missing_abstract){
    counts$scopus_attempted <- counts$scopus_attempted + 1L
    sc <- tryCatch(scopus_lookup(d),error=function(e)list(outcome="technical_error",error=conditionMessage(e),title=NULL,abstract=NULL,returned_doi=NULL,eid=NULL,status=NULL,attempts=NULL))
    rec_audit$scopus <- sc
    if(identical(sc$status,404L)) counts$scopus_http_404 <- counts$scopus_http_404 + 1L

    if(identical(sc$returned_doi,d)){
      if(still_missing_title && !is.null(sc$title)){
        r$canonical$title <- sc$title
        counts$scopus_title_filled <- counts$scopus_title_filled + 1L
        rec_audit$applied <- c(rec_audit$applied,list(list(provider="scopus",field="title",eid=sc$eid)))
      }
      if(still_missing_abstract && !is.null(sc$abstract)){
        md <- metadata_match_decision(r,sc)
        if(isTRUE(md$accept)){
          r$canonical$abstract <- sc$abstract
          counts$scopus_abstract_filled <- counts$scopus_abstract_filled + 1L
          rec_audit$applied <- c(rec_audit$applied,list(list(
            provider="scopus",field="abstract",eid=sc$eid,match_route=md$route,
            title_similarity=md$title_similarity,bibliographic=md$bibliographic
          )))
        } else {
          counts$conflicts_quarantined <- counts$conflicts_quarantined + 1L
          rec_audit$quarantined <- c(rec_audit$quarantined,list(list(
            provider="scopus",field="abstract",reason="insufficient_bibliographic_concordance",
            title_similarity=md$title_similarity,eid=sc$eid,bibliographic=md$bibliographic
          )))
        }
      }
    } else if(!is.null(sc$returned_doi)){
      counts$conflicts_quarantined <- counts$conflicts_quarantined + 1L
      rec_audit$quarantined <- c(rec_audit$quarantined,list(list(provider="scopus",reason="returned_doi_mismatch",returned_doi=sc$returned_doi)))
    }
    Sys.sleep(delay)
  }

  still_missing_title <- is_missing(r$canonical$title)
  still_missing_abstract <- is_missing(r$canonical$abstract)
  if(still_missing_title || still_missing_abstract) counts$still_missing_after <- counts$still_missing_after + 1L

  technical_error <- identical(clean_text(ep$outcome),"technical_error") ||
    (!is.null(rec_audit$scopus) && identical(clean_text(rec_audit$scopus$outcome),"technical_error"))
  if(technical_error) counts$technical_error_records <- counts$technical_error_records + 1L
  filled_fields <- vapply(rec_audit$applied,function(z) clean_text(z$field) %||% "",character(1))
  filled_fields <- unique(filled_fields[nzchar(filled_fields)])
  r$metadata_enrichment <- list(
    workflow="workflow_02_metadata_enrichment",
    implementation_language="R",
    providers=c("europe_pmc","scopus"),
    completed_at=now_utc(),
    doi=d,
    title_missing_after=still_missing_title,
    abstract_missing_after=still_missing_abstract,
    europe_pmc_outcome=clean_text(ep$outcome),
    scopus_outcome=if(is.null(rec_audit$scopus)) NULL else clean_text(rec_audit$scopus$outcome),
    technical_error=technical_error,
    filled_fields=filled_fields,
    recheck_after_days=recheck_after_days
  )
  rows[[i]] <- r
  audit[[length(audit)+1L]] <- rec_audit
}

write_jsonl(rows,output_path)
write_jsonl(audit,audit_path)

report <- list(
  schema="living-evidence-map-workflow02-metadata-enrichment-v1",
  workflow="02_metadata_enrichment",
  implementation_language="R",
  provider_order=c("europe_pmc","scopus"),
  policy=list(
    eligibility="DOI present and title or abstract missing",
    overwrite_existing_fields=FALSE,
    europe_pmc_match="exact normalised DOI",
    scopus_match="direct DOI Abstract Retrieval with view=META_ABS; on miss, Scopus Search by DOI then unique exact-DOI EID retrieval with view=META_ABS",
    metadata_match_guard="exact DOI required; accept when title Jaro-Winkler similarity is >= 0.90, or when at least two non-title bibliographic fields agree with no comparable-field conflicts and at least one supporting field is authors, journal, volume or pages",
    provider_fallback="Scopus queried only if metadata remain missing after Europe PMC",
    repeat_policy=sprintf("successful/no-result attempts are deferred for %.0f days; technical failures are eligible for retry on the next run",recheck_after_days)
  ),
  trial_limit=if(is.infinite(limit)) NULL else limit,
  counts=counts,
  input_sha256=input_sha,
  output_sha256=digest(file=output_path,algo="sha256",serialize=FALSE),
  audit_sha256=digest(file=audit_path,algo="sha256",serialize=FALSE),
  completed_at=now_utc()
)
dir.create(dirname(report_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),report_path,useBytes=TRUE)
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
