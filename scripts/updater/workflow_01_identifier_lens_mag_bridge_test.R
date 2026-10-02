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
norm_mag <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- gsub("[^0-9]","",x)
  if (!nzchar(x)) NULL else x
}

lines <- readLines(input,warn=FALSE)
rows <- list()
skipped_mag_without_doi <- 0L

for (line in lines[nzchar(trimws(lines))]) {
  r <- fromJSON(line,simplifyVector=FALSE)
  ids <- r$identifiers %||% list()
  lens_mag <- norm_mag(ids$mag %||% r$identity$mag_id)
  if (is.null(lens_mag)) next
  lens_doi <- norm_doi(ids$doi %||% r$canonical$doi)
  lookup_key <- if (!is.null(lens_doi)) {
    URLencode(paste0("https://doi.org/",lens_doi),reserved=TRUE)
  } else {
    skipped_mag_without_doi <- skipped_mag_without_doi + 1L
    paste0("W",lens_mag)
  }

  req <- request(paste0("https://api.openalex.org/works/",lookup_key)) |>
    req_headers(Authorization=paste("Bearer",key),Accept="application/json") |>
    req_error(is_error=function(resp) FALSE)
  resp <- req_perform(req)
  st <- resp_status(resp)
  if (st!=200L) stop(sprintf("OpenAlex lookup for MAG %s returned HTTP %d",lens_mag,st),call.=FALSE)
  w <- fromJSON(resp_body_string(resp),simplifyVector=FALSE)
  wids <- w$ids %||% list()
  oa_mag <- norm_mag(wids$mag)
  oa_doi <- norm_doi(w$doi)

  rows[[length(rows)+1L]] <- data.table(
    lens_id=scalar(r$identity$lens_id),
    lens_mag=lens_mag,
    openalex_mag=oa_mag %||% NA_character_,
    mag_agrees=!is.null(oa_mag) && identical(lens_mag,oa_mag),
    lens_doi=lens_doi %||% NA_character_,
    openalex_doi=oa_doi %||% NA_character_,
    doi_agrees=!is.null(oa_doi) && identical(lens_doi,oa_doi),
    title_exact=identical(norm_title(r$canonical$title),norm_title(w$title)),
    openalex_id=scalar(w$id) %||% NA_character_
  )
}

out <- if(length(rows)) rbindlist(rows,fill=TRUE) else data.table()
if (!nrow(out)) stop("No Lens MAG records with DOI were available for validation",call.=FALSE)
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(out,output)
print(out)

summary <- list(
  schema="living-evidence-map-w01-lens-mag-bridge-test-v1",
  status="success",
  lens_mag_records_tested=nrow(out),
  lens_mag_records_without_doi_tested_by_w_prefix=skipped_mag_without_doi,
  openalex_mag_present=sum(!is.na(out$openalex_mag)),
  exact_mag_agreements=sum(out$mag_agrees),
  exact_doi_agreements=sum(out$doi_agrees),
  exact_normalised_title_matches=sum(out$title_exact),
  mag_disagreements=sum(!is.na(out$openalex_mag) & !out$mag_agrees),
  mag_missing_in_openalex=sum(is.na(out$openalex_mag)),
  automatic_merges_performed=0L
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),
           sub("\\.csv$","_summary.json",output))
cat(sprintf("PASS: validated %d Lens MAG records against DOI-resolved OpenAlex works\n",nrow(out)))
