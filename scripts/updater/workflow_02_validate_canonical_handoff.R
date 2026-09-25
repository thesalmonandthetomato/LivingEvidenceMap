#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
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
sample_path <- arg("--sample")
report_path <- arg("--report")
sample_n <- as.integer(arg("--sample-n","10"))
expected_records <- as.integer(arg("--expected-records","32292"))
expected_manifestations <- as.integer(arg("--expected-manifestations","90137"))
if(any(vapply(list(input_path,sample_path,report_path),is.null,logical(1)))) {
  stop("Required: --input --sample --report",call.=FALSE)
}
if(is.na(sample_n) || sample_n < 1L) stop("--sample-n must be positive",call.=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x

clean_text <- function(x){
  if(is.null(x) || !length(x)) return(NULL)
  s <- trimws(gsub("[[:space:]]+"," ",as.character(x[[1L]])))
  if(is.na(s) || !nzchar(s)) NULL else s
}
norm_doi <- function(x){
  s <- clean_text(x)
  if(is.null(s)) return(NULL)
  s <- tolower(s)
  s <- sub("^https?://(dx\\.)?doi\\.org/","",s,perl=TRUE)
  s <- sub("^doi:\\s*","",s,perl=TRUE)
  s <- sub("[[:space:][:punct:]]+$","",s)
  if(!nzchar(s)) NULL else s
}
is_missing <- function(x) is.null(clean_text(x))

con <- file(input_path,"rt",encoding="UTF-8")
on.exit(close(con),add=TRUE)

record_ids <- character()
manifestation_keys <- character()
sample_lines <- character()
n_records <- 0L
n_manifestations <- 0L
n_doi <- 0L
n_missing_title <- 0L
n_missing_abstract <- 0L
n_eligible <- 0L
source_counts <- setNames(integer(5),c("lens","scopus","openalex","agricola","wos"))

repeat {
  line <- readLines(con,n=1L,warn=FALSE)
  if(!length(line)) break
  if(!nzchar(trimws(line))) next
  n_records <- n_records + 1L
  r <- tryCatch(
    fromJSON(line,simplifyVector=FALSE),
    error=function(e) stop(sprintf("Invalid canonical JSON at non-empty line %d: %s",n_records,conditionMessage(e)),call.=FALSE)
  )

  if(!identical(r$schema_version,"living-evidence-map-canonical-v1")) {
    stop(sprintf("Unexpected schema_version at record %d",n_records),call.=FALSE)
  }
  rid <- clean_text((r$identity %||% list())$record_id)
  if(is.null(rid)) stop(sprintf("Missing identity.record_id at record %d",n_records),call.=FALSE)
  record_ids <- c(record_ids,rid)

  if(is.null(r$canonical) || !is.list(r$canonical)) {
    stop(sprintf("Missing canonical object for %s",rid),call.=FALSE)
  }
  mans <- r$manifestations
  if(is.null(mans) || !is.list(mans) || !length(mans)) {
    stop(sprintf("No manifestations for %s",rid),call.=FALSE)
  }
  for(m in mans){
    src <- clean_text(m$source)
    sid <- clean_text(m$source_record_id)
    if(is.null(src) || is.null(sid)) stop(sprintf("Invalid manifestation identity in %s",rid),call.=FALSE)
    if(!(src %in% names(source_counts))) stop(sprintf("Unexpected manifestation source '%s' in %s",src,rid),call.=FALSE)
    manifestation_keys <- c(manifestation_keys,paste(src,sid,sep="::"))
    source_counts[[src]] <- source_counts[[src]] + 1L
    n_manifestations <- n_manifestations + 1L
  }

  d <- norm_doi(r$canonical$doi)
  if(!is.null(d)) n_doi <- n_doi + 1L
  mt <- is_missing(r$canonical$title)
  ma <- is_missing(r$canonical$abstract)
  if(mt) n_missing_title <- n_missing_title + 1L
  if(ma) n_missing_abstract <- n_missing_abstract + 1L
  eligible <- !is.null(d) && (mt || ma)
  if(eligible){
    n_eligible <- n_eligible + 1L
    if(length(sample_lines) < sample_n) sample_lines <- c(sample_lines,line)
  }
}
close(con)
on.exit(NULL,add=FALSE)

if(anyDuplicated(record_ids)) stop("Duplicate identity.record_id values in canonical JSONL",call.=FALSE)
if(anyDuplicated(manifestation_keys)) stop("A source manifestation occurs in more than one canonical work",call.=FALSE)
if(n_records != expected_records) stop(sprintf("Expected %d canonical records; found %d",expected_records,n_records),call.=FALSE)
if(n_manifestations != expected_manifestations) stop(sprintf("Expected %d manifestations; found %d",expected_manifestations,n_manifestations),call.=FALSE)
if(length(sample_lines) < sample_n) stop(sprintf("Only %d eligible DOI-bearing records with missing metadata; need %d",length(sample_lines),sample_n),call.=FALSE)

dir.create(dirname(sample_path),recursive=TRUE,showWarnings=FALSE)
writeLines(sample_lines,sample_path,useBytes=TRUE)

report <- list(
  schema="living-evidence-map-workflow02-handoff-validation-v1",
  status="PASS",
  input_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  canonical_records=n_records,
  source_manifestations=n_manifestations,
  unique_record_ids=length(unique(record_ids)),
  unique_manifestation_ids=length(unique(manifestation_keys)),
  source_counts=as.list(source_counts),
  records_with_doi=n_doi,
  records_missing_title=n_missing_title,
  records_missing_abstract=n_missing_abstract,
  workflow02_eligible_records=n_eligible,
  sample_records=length(sample_lines),
  sample_sha256=digest(file=sample_path,algo="sha256",serialize=FALSE),
  validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
dir.create(dirname(report_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null"),report_path,useBytes=TRUE)
cat(sprintf(
  "PASS: Workflow 01 -> 02 handoff: %d canonical works, %d manifestations, %d DOI-bearing records eligible for metadata enrichment; selected %d real records\n",
  n_records,n_manifestations,n_eligible,length(sample_lines)
))
