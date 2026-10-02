#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(httr2)
  library(stringi)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

triage_path <- arg("--triage")
registry_path <- arg("--registry")
output_dir <- arg("--output-dir")
if (is.null(triage_path)||is.null(registry_path)||is.null(output_dir)) {
  stop("--triage --registry --output-dir required",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

tri <- fread(triage_path,na.strings=c("","NA"))
tri <- tri[triage_class %in% c("ambiguous_manual","metadata_or_identifier_conflict")]
if (nrow(tri)!=54L) stop(sprintf("Expected 54 non-clear high-evidence pairs, got %d",nrow(tri)),call.=FALSE)

reg <- fread(registry_path,na.strings=c("","NA"))
setkey(reg,manifestation_key,identifier_type,identifier_value)

norm_title <- function(x) {
  if (is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  x <- stri_trans_tolower(stri_trans_nfkc(as.character(x)))
  stri_replace_all_regex(x,"[\\p{P}\\p{S}\\p{Z}\\s]+","")
}
title_sim <- function(a,b) {
  a <- norm_title(a); b <- norm_title(b)
  if (is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  1 - adist(a,b)[1L]/max(nchar(a),nchar(b),1L)
}
norm_doi <- function(x) {
  if (is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  x <- tolower(trimws(as.character(x)))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x,perl=TRUE)
  x <- sub("^doi:\\s*","",x,perl=TRUE)
  sub("[.,;:]+$","",x,perl=TRUE)
}
norm_pmid <- function(x) {
  if (is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  x <- sub("^https?://pubmed\\.ncbi\\.nlm\\.nih\\.gov/","",as.character(x),ignore.case=TRUE)
  x <- sub("/$","",x)
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NA_character_ else x
}
norm_openalex <- function(x) {
  if (is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  x <- toupper(as.character(x))
  sub("^HTTPS?://OPENALEX\\.ORG/","",x,ignore.case=TRUE)
}
norm_mag <- function(x) {
  if (is.null(x)||length(x)==0L||is.na(x)||!nzchar(trimws(x))) return(NA_character_)
  x <- gsub("[^0-9]","",as.character(x))
  if (!nzchar(x)) NA_character_ else x
}

get_json <- function(req) {
  resp <- tryCatch(req_perform(req |> req_error(is_error=function(resp) FALSE)),error=function(e) NULL)
  if (is.null(resp)) return(list(status=NA_integer_,body=NULL))
  st <- resp_status(resp)
  if (st<200L||st>=300L) return(list(status=st,body=NULL))
  list(status=st,body=fromJSON(resp_body_string(resp),simplifyVector=FALSE))
}

cache <- new.env(parent=emptyenv())

crossref_lookup <- function(doi) {
  if (is.na(doi)) return(list(status=NA_integer_))
  key <- paste0("cr:",doi)
  if (exists(key,cache,inherits=FALSE)) return(get(key,cache))
  u <- paste0("https://api.crossref.org/works/",URLencode(doi,reserved=TRUE))
  z <- get_json(request(u) |> req_headers(`User-Agent`="LivingEvidenceMap identifier audit"))
  out <- list(status=z$status,title=NA_character_,year=NA_integer_,doi=doi)
  if (!is.null(z$body$message)) {
    m <- z$body$message
    if (length(m$title)) out$title <- as.character(m$title[[1L]])
    parts <- m$issued[["date-parts"]] %||% NULL
    if (!is.null(parts)&&length(parts)&&length(parts[[1L]])) out$year <- as.integer(parts[[1L]][[1L]])
    out$doi <- norm_doi(m$DOI %||% doi)
  }
  assign(key,out,cache); out
}

epmc_lookup <- function(pmid) {
  if (is.na(pmid)) return(list(status=NA_integer_))
  key <- paste0("ep:",pmid)
  if (exists(key,cache,inherits=FALSE)) return(get(key,cache))
  req <- request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    req_url_query(query=paste0("EXT_ID:",pmid," AND SRC:MED"),format="json",pageSize=1)
  z <- get_json(req)
  out <- list(status=z$status,title=NA_character_,year=NA_integer_,doi=NA_character_,pmid=pmid,pmcid=NA_character_)
  if (!is.null(z$body$resultList$result) && length(z$body$resultList$result)) {
    r <- z$body$resultList$result[[1L]]
    out$title <- as.character(r$title %||% NA_character_)
    out$year <- suppressWarnings(as.integer(r$pubYear %||% NA_integer_))
    out$doi <- norm_doi(r$doi %||% NA_character_)
    out$pmid <- norm_pmid(r$pmid %||% r$id %||% pmid)
    out$pmcid <- as.character(r$pmcid %||% NA_character_)
  }
  assign(key,out,cache); out
}

openalex_by_doi <- function(doi) {
  if (is.na(doi)) return(list(status=NA_integer_))
  key <- paste0("oa_doi:",doi)
  if (exists(key,cache,inherits=FALSE)) return(get(key,cache))
  u <- paste0("https://api.openalex.org/works/",URLencode(paste0("https://doi.org/",doi),reserved=TRUE))
  z <- get_json(request(u) |> req_headers(`User-Agent`="LivingEvidenceMap identifier audit"))
  out <- list(status=z$status,title=NA_character_,year=NA_integer_,doi=NA_character_,pmid=NA_character_,openalex=NA_character_,mag=NA_character_)
  if (!is.null(z$body)) {
    w <- z$body; ids <- w$ids %||% list()
    out$title <- as.character(w$title %||% NA_character_)
    out$year <- suppressWarnings(as.integer(w$publication_year %||% NA_integer_))
    out$doi <- norm_doi(w$doi %||% NA_character_)
    out$pmid <- norm_pmid(ids$pmid %||% NA_character_)
    out$openalex <- norm_openalex(w$id %||% ids$openalex %||% NA_character_)
    out$mag <- norm_mag(ids$mag %||% NA_character_)
  }
  assign(key,out,cache); out
}

openalex_by_mag <- function(mag) {
  if (is.na(mag)) return(list(status=NA_integer_))
  key <- paste0("oa_mag:",mag)
  if (exists(key,cache,inherits=FALSE)) return(get(key,cache))
  u <- paste0("https://api.openalex.org/works/W",mag)
  z <- get_json(request(u) |> req_headers(`User-Agent`="LivingEvidenceMap identifier audit"))
  out <- list(status=z$status,title=NA_character_,year=NA_integer_,doi=NA_character_,pmid=NA_character_,openalex=NA_character_,mag=NA_character_)
  if (!is.null(z$body)) {
    w <- z$body; ids <- w$ids %||% list()
    out$title <- as.character(w$title %||% NA_character_)
    out$year <- suppressWarnings(as.integer(w$publication_year %||% NA_integer_))
    out$doi <- norm_doi(w$doi %||% NA_character_)
    out$pmid <- norm_pmid(ids$pmid %||% NA_character_)
    out$openalex <- norm_openalex(w$id %||% NA_character_)
    out$mag <- norm_mag(ids$mag %||% NA_character_)
  }
  assign(key,out,cache); out
}

shared_ids <- function(k1,k2) {
  a <- reg[manifestation_key==k1,.(identifier_type,identifier_value)]
  b <- reg[manifestation_key==k2,.(identifier_type,identifier_value)]
  merge(a,b,by=c("identifier_type","identifier_value"))
}

rows <- vector("list",nrow(tri))
for (i in seq_len(nrow(tri))) {
  t <- tri[i]
  k1 <- as.character(t[["i.manifestation_key"]])
  k2 <- as.character(t[["manifestation_key"]])
  ids <- shared_ids(k1,k2)
  getone <- function(ns) {
    z <- ids[identifier_type==ns,identifier_value]
    if (!length(z)) NA_character_ else as.character(z[[1L]])
  }
  doi <- norm_doi(getone("doi"))
  pmid <- norm_pmid(getone("pmid"))
  pmcid <- getone("pmcid")
  oa <- norm_openalex(getone("openalex"))
  mag <- norm_mag(getone("mag"))
  core <- getone("core")

  cr <- crossref_lookup(doi)
  ep <- epmc_lookup(pmid)
  od <- openalex_by_doi(doi)
  om <- if (!is.na(mag)) openalex_by_mag(mag) else list(status=NA_integer_,title=NA_character_,year=NA_integer_,doi=NA_character_,pmid=NA_character_,openalex=NA_character_,mag=NA_character_)

  epmc_doi_matches <- !is.na(doi) && !is.na(ep$doi) && identical(doi,ep$doi)
  oa_pmid_matches <- !is.na(pmid) && !is.na(od$pmid) && identical(pmid,od$pmid)
  oa_mag_matches <- !is.na(mag) && ((!is.na(od$mag) && identical(mag,od$mag)) || (!is.na(om$mag) && identical(mag,om$mag)))
  oa_openalex_matches <- !is.na(oa) && ((!is.na(od$openalex) && identical(oa,od$openalex)) || (!is.na(om$openalex) && identical(oa,om$openalex)))
  oa_mag_pmid_matches <- !is.na(mag) && !is.na(pmid) && !is.na(om$pmid) && identical(pmid,om$pmid)

  direct_crosswalk_support <- sum(c(epmc_doi_matches,oa_pmid_matches,oa_mag_matches,oa_openalex_matches,oa_mag_pmid_matches),na.rm=TRUE)

  contradiction <- FALSE
  contradiction_reason <- character()
  if (!is.na(doi) && !is.na(pmid) && !is.na(ep$doi) && !identical(doi,ep$doi)) {
    contradiction <- TRUE; contradiction_reason <- c(contradiction_reason,"EuropePMC PMID maps to different DOI")
  }
  if (!is.na(doi) && !is.na(pmid) && !is.na(od$pmid) && !identical(pmid,od$pmid)) {
    contradiction <- TRUE; contradiction_reason <- c(contradiction_reason,"OpenAlex DOI maps to different PMID")
  }
  if (!is.na(mag) && !is.na(om$mag) && !identical(mag,om$mag)) {
    contradiction <- TRUE; contradiction_reason <- c(contradiction_reason,"OpenAlex W<MAG> has different MAG")
  }

  canonical_titles <- c(cr$title %||% NA_character_,ep$title %||% NA_character_,od$title %||% NA_character_,om$title %||% NA_character_)
  canonical_titles <- canonical_titles[!is.na(canonical_titles) & nzchar(canonical_titles)]
  sim_i <- if(length(canonical_titles)) max(vapply(canonical_titles,title_sim,numeric(1),b=t$title_i),na.rm=TRUE) else NA_real_
  sim_j <- if(length(canonical_titles)) max(vapply(canonical_titles,title_sim,numeric(1),b=t$title_j),na.rm=TRUE) else NA_real_

  final_class <- if (contradiction) {
    "externally_confirmed_identifier_conflict"
  } else if (direct_crosswalk_support>=1L) {
    "externally_corroborated_same_work"
  } else if (length(canonical_titles) && ((is.finite(sim_i)&&sim_i>=0.65)||(is.finite(sim_j)&&sim_j>=0.65))) {
    "external_metadata_support_no_direct_crosswalk"
  } else {
    "still_ambiguous"
  }

  rows[[i]] <- data.table(
    pair_id=t$pair_id,
    original_triage=t$triage_class,
    families=t$families,
    source_i=t$source_i,
    source_j=t$source_j,
    title_i=t$title_i,
    title_j=t$title_j,
    year_i=t$year_i,
    year_j=t$year_j,
    shared_doi=doi,
    shared_pmid=pmid,
    shared_pmcid=pmcid,
    shared_openalex=oa,
    shared_mag=mag,
    shared_core=core,
    crossref_status=cr$status %||% NA_integer_,
    crossref_title=cr$title %||% NA_character_,
    crossref_year=cr$year %||% NA_integer_,
    epmc_status=ep$status %||% NA_integer_,
    epmc_title=ep$title %||% NA_character_,
    epmc_year=ep$year %||% NA_integer_,
    epmc_doi=ep$doi %||% NA_character_,
    openalex_doi_status=od$status %||% NA_integer_,
    openalex_doi_title=od$title %||% NA_character_,
    openalex_doi_pmid=od$pmid %||% NA_character_,
    openalex_doi_mag=od$mag %||% NA_character_,
    openalex_doi_id=od$openalex %||% NA_character_,
    openalex_mag_status=om$status %||% NA_integer_,
    openalex_mag_title=om$title %||% NA_character_,
    openalex_mag_pmid=om$pmid %||% NA_character_,
    openalex_mag_doi=om$doi %||% NA_character_,
    epmc_doi_matches_shared=epmc_doi_matches,
    openalex_pmid_matches_shared=oa_pmid_matches,
    openalex_mag_matches_shared=oa_mag_matches,
    openalex_id_matches_shared=oa_openalex_matches,
    openalex_mag_pmid_matches_shared=oa_mag_pmid_matches,
    direct_crosswalk_support=direct_crosswalk_support,
    contradiction=contradiction,
    contradiction_reason=paste(contradiction_reason,collapse="; "),
    max_canonical_similarity_title_i=ifelse(is.finite(sim_i),sim_i,NA_real_),
    max_canonical_similarity_title_j=ifelse(is.finite(sim_j),sim_j,NA_real_),
    external_validation_class=final_class
  )
}

out <- rbindlist(rows,fill=TRUE)
fwrite(out,file.path(output_dir,"nonclear_external_validation.csv"))
summary <- out[,.(pairs=.N),by=external_validation_class][order(external_validation_class)]
fwrite(summary,file.path(output_dir,"external_validation_summary.csv"))

cat("PASS: external validation of 54 non-clear high-evidence pairs\n")
print(summary)
cat(sprintf("TOTAL=%d; zero W01 modifications\n",nrow(out)))
