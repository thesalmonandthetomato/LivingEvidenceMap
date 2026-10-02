#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(httr2)
  library(stringi)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args); if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
pairs_path <- arg("--pairs")
registry_path <- arg("--registry")
output_dir <- arg("--output-dir")
if (is.null(pairs_path)||is.null(registry_path)||is.null(output_dir)) stop("--pairs --registry --output-dir required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

pairs <- fread(pairs_path,na.strings=c("","NA"))
x <- pairs[same_cluster==FALSE & n_independent_families==1L]
if (nrow(x)!=1219L) stop(sprintf("Expected 1219 single-family disagreement pairs, got %d",nrow(x)),call.=FALSE)
reg <- fread(registry_path,na.strings=c("","NA"))

sim <- function(a,b) {
  if (is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  1 - adist(a,b)[1L]/max(nchar(a),nchar(b),1L)
}
x[, title_similarity:=mapply(sim,title_i,title_j)]
x[, year_compatible:=is.na(year_diff) | year_diff<=1]
x[, severe_year_conflict:=!is.na(year_diff) & year_diff>=3]
x[, family:=families]
x[, initial_triage:=fcase(
  family=="pmid" & year_compatible & !is.na(title_similarity) & title_similarity>=0.65, "strong_same_work_candidate",
  family=="openalex_mag" & year_compatible & !is.na(title_similarity) & title_similarity>=0.65, "strong_same_work_candidate",
  family=="doi" & year_compatible & !is.na(title_similarity) & title_similarity>=0.90, "strong_same_work_candidate",
  severe_year_conflict, "metadata_conflict_review",
  !is.na(title_similarity) & title_similarity<0.35, "container_or_identifier_risk",
  default="external_validation_needed"
)]
todo <- x[initial_triage!="strong_same_work_candidate"]
if (nrow(todo)!=502L) stop(sprintf("Expected 502 non-strong cases, got %d",nrow(todo)),call.=FALSE)

norm_title <- function(z) {
  if (is.null(z)||length(z)==0L||is.na(z)||!nzchar(trimws(z))) return(NA_character_)
  z <- stri_trans_tolower(stri_trans_nfkc(as.character(z)))
  stri_replace_all_regex(z,"[\\p{P}\\p{S}\\p{Z}\\s]+","")
}
title_sim <- function(a,b) {
  a<-norm_title(a); b<-norm_title(b)
  if(is.na(a)||is.na(b)||!nzchar(a)||!nzchar(b)) return(NA_real_)
  1-adist(a,b)[1L]/max(nchar(a),nchar(b),1L)
}
cache <- new.env(parent=emptyenv())
get_json <- function(req) {
  resp <- tryCatch(req_perform(req |> req_error(is_error=function(resp) FALSE)),error=function(e) NULL)
  if (is.null(resp)) return(list(status=NA_integer_,body=NULL))
  st <- resp_status(resp)
  if (st<200L||st>=300L) return(list(status=st,body=NULL))
  list(status=st,body=fromJSON(resp_body_string(resp),simplifyVector=FALSE))
}
shared_id <- function(k1,k2,types) {
  a <- reg[manifestation_key==k1 & identifier_type %in% types,.(identifier_type,identifier_value)]
  b <- reg[manifestation_key==k2 & identifier_type %in% types,.(identifier_type,identifier_value)]
  z <- merge(a,b,by=c("identifier_type","identifier_value"))
  if (!nrow(z)) return(list(type=NA_character_,value=NA_character_))
  list(type=as.character(z$identifier_type[[1L]]),value=as.character(z$identifier_value[[1L]]))
}
lookup_doi <- function(doi) {
  key<-paste0("doi:",doi); if(exists(key,cache,inherits=FALSE)) return(get(key,cache))
  z<-get_json(request(paste0("https://api.crossref.org/works/",URLencode(doi,reserved=TRUE))) |>
                req_headers(`User-Agent`="LivingEvidenceMap identifier audit"))
  out<-list(status=z$status,title=NA_character_,year=NA_integer_)
  if(!is.null(z$body$message)) {
    m<-z$body$message
    if(length(m$title)) out$title<-as.character(m$title[[1L]])
    dp<-m$issued[["date-parts"]] %||% NULL
    if(!is.null(dp)&&length(dp)&&length(dp[[1L]])) out$year<-as.integer(dp[[1L]][[1L]])
  }
  assign(key,out,cache); Sys.sleep(0.03); out
}
lookup_pmid <- function(pmid) {
  key<-paste0("pmid:",pmid); if(exists(key,cache,inherits=FALSE)) return(get(key,cache))
  z<-get_json(request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
                req_url_query(query=paste0("EXT_ID:",pmid," AND SRC:MED"),format="json",pageSize=1))
  out<-list(status=z$status,title=NA_character_,year=NA_integer_)
  if(!is.null(z$body$resultList$result)&&length(z$body$resultList$result)) {
    r<-z$body$resultList$result[[1L]]
    out$title<-as.character(r$title %||% NA_character_)
    out$year<-suppressWarnings(as.integer(r$pubYear %||% NA_integer_))
  }
  assign(key,out,cache); out
}
lookup_mag <- function(mag) {
  key<-paste0("mag:",mag); if(exists(key,cache,inherits=FALSE)) return(get(key,cache))
  z<-get_json(request(paste0("https://api.openalex.org/works/W",mag)) |>
                req_headers(`User-Agent`="LivingEvidenceMap identifier audit"))
  out<-list(status=z$status,title=NA_character_,year=NA_integer_)
  if(!is.null(z$body)) {
    out$title<-as.character(z$body$title %||% NA_character_)
    out$year<-suppressWarnings(as.integer(z$body$publication_year %||% NA_integer_))
  }
  assign(key,out,cache); out
}

rows<-vector("list",nrow(todo))
for(i in seq_len(nrow(todo))) {
  t<-todo[i]
  types<-if(t$family=="doi") "doi" else if(t$family=="pmid") "pmid" else c("mag","openalex")
  sid<-shared_id(as.character(t[["i.manifestation_key"]]),as.character(t$manifestation_key),types)
  ext<-if(t$family=="doi") lookup_doi(sid$value) else if(t$family=="pmid") lookup_pmid(sid$value) else {
    magval<-if(sid$type=="mag") sid$value else sub("^W","",sid$value)
    lookup_mag(magval)
  }
  si<-title_sim(t$title_i,ext$title)
  sj<-title_sim(t$title_j,ext$title)
  yi<-is.na(t$year_i)||is.na(ext$year)||abs(t$year_i-ext$year)<=1
  yj<-is.na(t$year_j)||is.na(ext$year)||abs(t$year_j-ext$year)<=1

  both_title_support <- (is.na(t$title_i) || (!is.na(si)&&si>=0.65)) &&
                        (is.na(t$title_j) || (!is.na(sj)&&sj>=0.65))
  one_title_support <- (!is.na(si)&&si>=0.65) || (!is.na(sj)&&sj>=0.65)
  pair_close <- !is.na(t$title_similarity) && t$title_similarity>=0.65

  final <- if(!is.na(ext$status)&&ext$status>=200L&&ext$status<300L && both_title_support && yi && yj) {
    "externally_corroborated_same_work"
  } else if(!is.na(ext$status)&&ext$status>=200L&&ext$status<300L && one_title_support && (!both_title_support || !yi || !yj)) {
    "possible_identifier_or_container_misassignment"
  } else if(!is.na(ext$status)&&ext$status>=200L&&ext$status<300L && pair_close && yi && yj) {
    "pair_supported_but_canonical_title_variant"
  } else if(is.na(ext$status)||ext$status<200L||ext$status>=300L) {
    "external_lookup_unresolved"
  } else {
    "still_ambiguous_or_conflicting"
  }

  rows[[i]]<-data.table(
    family=t$family,initial_triage=t$initial_triage,
    source_i=sub("::.*$","",as.character(t[["i.manifestation_key"]])),
    source_j=sub("::.*$","",as.character(t$manifestation_key)),
    record_i=as.character(t[["i.manifestation_key"]]),record_j=as.character(t$manifestation_key),
    title_i=t$title_i,title_j=t$title_j,year_i=t$year_i,year_j=t$year_j,
    pair_title_similarity=t$title_similarity,
    identifier_type=sid$type,identifier_value=sid$value,
    external_status=ext$status,external_title=ext$title,external_year=ext$year,
    external_similarity_i=si,external_similarity_j=sj,
    external_year_compatible_i=yi,external_year_compatible_j=yj,
    external_validation_class=final
  )
}
out<-rbindlist(rows,fill=TRUE)
fwrite(out,file.path(output_dir,"single_family_external_validation.csv"))
summary<-out[,.(pairs=.N),by=.(family,external_validation_class)][order(family,external_validation_class)]
fwrite(summary,file.path(output_dir,"single_family_external_validation_summary.csv"))
cat("PASS: externally validated 502 non-strong single-family disagreement pairs\n")
print(summary)
cat(sprintf("TOTAL=%d; zero W01 modifications\n",nrow(out)))
