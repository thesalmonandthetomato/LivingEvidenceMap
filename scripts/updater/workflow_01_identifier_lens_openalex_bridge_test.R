#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(data.table)
  library(stringi)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input <- arg("--lens-records")
output <- arg("--output")
if (is.null(input)||is.null(output)) stop("--lens-records and --output are required",call.=FALSE)
if (!file.exists(input)) stop("Lens sample not found",call.=FALSE)

key <- Sys.getenv("OPENALEX_API_KEY","")
if (!nzchar(key)) key <- Sys.getenv("OPENALEX_API_TOKEN","")
if (!nzchar(key)) stop("OpenAlex API credential unavailable",call.=FALSE)

scalar <- function(x) {
  if (is.null(x)||!length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
norm_title <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- stri_trans_tolower(stri_trans_nfkc(x))
  stri_replace_all_regex(x,"[\\p{P}\\p{S}\\p{Z}\\s]+","")
}
norm_doi <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/","",x)
  x
}
short_openalex <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  toupper(sub("^https://openalex.org/","",x,ignore.case=TRUE))
}
norm_mag <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NULL else x
}
norm_pmid <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- sub("/$","",x)
  x <- sub("^https://pubmed.ncbi.nlm.nih.gov/","",x,ignore.case=TRUE)
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NULL else x
}

lines <- readLines(input,warn=FALSE)
rows <- list()
for (line in lines[nzchar(trimws(lines))]) {
  r <- fromJSON(line,simplifyVector=FALSE)
  ids <- r$identifiers %||% list()
  oid <- short_openalex(ids$openalex %||% r$identity$openalex_id)
  if (is.null(oid)) next

  req <- request(paste0("https://api.openalex.org/works/",oid)) |>
    req_headers(Authorization=paste("Bearer",key),Accept="application/json") |>
    req_error(is_error=function(resp) FALSE)
  resp <- req_perform(req)
  st <- resp_status(resp)
  if (st!=200L) stop(sprintf("OpenAlex exact lookup %s returned HTTP %d",oid,st),call.=FALSE)
  w <- fromJSON(resp_body_string(resp),simplifyVector=FALSE)
  wids <- w$ids %||% list()

  lens_title <- scalar(r$canonical$title %||% r$mapped_fields$title)
  oa_title <- scalar(w$title)
  lens_doi <- norm_doi(ids$doi %||% r$canonical$doi)
  oa_doi <- norm_doi(w$doi)
  lens_pmid <- norm_pmid(ids$pmid %||% r$canonical$pmid)
  oa_pmid <- norm_pmid(wids$pmid)
  lens_mag <- norm_mag(ids$mag %||% r$identity$mag_id)
  oa_mag <- norm_mag(wids$mag)

  rows[[length(rows)+1L]] <- data.table(
    lens_id=scalar(r$identity$lens_id),
    openalex_id=oid,
    openalex_lookup_id=short_openalex(w$id),
    title_exact=identical(norm_title(lens_title),norm_title(oa_title)),
    doi_agrees=!is.null(lens_doi)&&!is.null(oa_doi)&&identical(lens_doi,oa_doi),
    pmid_agrees=!is.null(lens_pmid)&&!is.null(oa_pmid)&&identical(lens_pmid,oa_pmid),
    mag_agrees=!is.null(lens_mag)&&!is.null(oa_mag)&&identical(lens_mag,oa_mag),
    lens_doi=lens_doi %||% NA_character_,
    oa_doi=oa_doi %||% NA_character_,
    lens_pmid=lens_pmid %||% NA_character_,
    oa_pmid=oa_pmid %||% NA_character_,
    lens_mag=lens_mag %||% NA_character_,
    oa_mag=oa_mag %||% NA_character_
  )
}

out <- if(length(rows)) rbindlist(rows,fill=TRUE) else data.table()
if (!nrow(out)) stop("Lens sample contained no OpenAlex external IDs",call.=FALSE)
if (!all(out$openalex_id==out$openalex_lookup_id)) stop("OpenAlex exact ID lookup mismatch",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(out,output)
print(out)

summary <- list(
  schema="living-evidence-map-w01-lens-openalex-bridge-test-v1",
  status="success",
  records_tested=nrow(out),
  exact_openalex_id_matches=sum(out$openalex_id==out$openalex_lookup_id),
  exact_normalised_title_matches=sum(out$title_exact),
  doi_agreements=sum(out$doi_agrees),
  pmid_agreements=sum(out$pmid_agrees),
  mag_agreements=sum(out$mag_agrees),
  automatic_merges_performed=0L
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
           sub("\\.csv$","_summary.json",output))
cat(sprintf("PASS: validated %d Lens→OpenAlex exact-ID bridges\n",nrow(out)))
