#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

query <- arg("--query")
max_records_arg <- arg("--max-records","100")
page_size <- as.integer(arg("--page-size","1000"))
output_dir <- arg("--output-dir","outputs/updater/europe_pmc_ingestion")
base_url <- arg("--base-url","https://www.ebi.ac.uk/europepmc/webservices/rest/search")

if (is.null(query)||!nzchar(trimws(query))) stop("--query is required",call.=FALSE)
full_harvest <- identical(tolower(max_records_arg),"all")
if (!full_harvest) {
  max_records <- suppressWarnings(as.integer(max_records_arg))
  if (is.na(max_records)||max_records<1L) stop("--max-records must be >=1 or all",call.=FALSE)
} else max_records <- .Machine$integer.max
if (is.na(page_size)||page_size<1L||page_size>1000L) stop("--page-size must be 1..1000",call.=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x,default=NA_character_) {
  if (is.null(x)||length(x)==0L) return(default)
  y <- as.character(x[[1L]])
  if (!nzchar(y)) default else y
}
as_int <- function(x,default=NA_integer_) {
  y <- suppressWarnings(as.integer(scalar(x,NA_character_)))
  if (is.na(y)) default else y
}

root <- normalizePath(output_dir,mustWork=FALSE)
raw_dir <- file.path(root,"raw")
headers_dir <- file.path(root,"headers")
dir.create(raw_dir,recursive=TRUE,showWarnings=FALSE)
dir.create(headers_dir,recursive=TRUE,showWarnings=FALSE)
manifest_path <- file.path(root,"manifest.json")
checkpoint_path <- file.path(root,"checkpoint.json")
validation_path <- file.path(root,"validation.json")

write_json <- function(x,path) {
  tmp <- paste0(path,".tmp")
  writeLines(toJSON(x,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),tmp,useBytes=TRUE)
  if (!file.rename(tmp,path)) stop(sprintf("Could not atomically write %s",path),call.=FALSE)
}

request_page <- function(cursor_mark,count) {
  last_error <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(base_url) |>
      req_headers(Accept="application/json",`User-Agent`="LivingEvidenceMap Europe PMC ingestion") |>
      req_url_query(query=query,format="json",resultType="core",pageSize=count,
                    cursorMark=cursor_mark,synonym="false") |>
      req_error(is_error=function(resp) FALSE)
    resp <- tryCatch(req_perform(req),error=identity)
    if (!inherits(resp,"error")) {
      status <- resp_status(resp)
      if (status<400L) return(resp)
      body <- tryCatch(resp_body_string(resp),error=function(e)"")
      last_error <- sprintf("Europe PMC HTTP %d: %s",status,substr(body,1L,1200L))
      if (!(status==429L||status>=500L)) stop(last_error,call.=FALSE)
    } else last_error <- conditionMessage(resp)
    if (attempt<6L) Sys.sleep(min(60,2^(attempt-1L)))
  }
  stop(sprintf("Europe PMC request failed after 6 attempts: %s",last_error),call.=FALSE)
}

started_at <- now_utc()
cursor <- "*"
page <- 1L
retrieved <- 0L
reported_total <- NA_integer_
page_summaries <- list()

manifest <- list(
  workflow="00f_europe_pmc_ingestion",
  implementation_language="R",
  status="running",
  started_at=started_at,
  endpoint=base_url,
  provider="Europe PMC",
  source_collection="Europe PMC publications",
  query=query,
  synonym_expansion=FALSE,
  result_type="core",
  max_records_requested=if(full_harvest)"all" else max_records,
  requested_page_size=page_size,
  raw_response_preservation=TRUE,
  checkpoint_after_every_page=TRUE,
  canonicalisation_performed=FALSE,
  canonical_json_modified=FALSE,
  downstream_processing_performed=FALSE
)
write_json(manifest,manifest_path)

repeat {
  requested <- if(full_harvest) page_size else min(page_size,max_records-retrieved)
  if (requested<=0L) break

  message(sprintf("Requesting Europe PMC page %d, count=%d",page,requested))
  resp <- request_page(cursor,requested)
  body <- resp_body_string(resp)
  headers <- resp_headers(resp)
  parsed <- fromJSON(body,simplifyVector=FALSE)

  total <- as_int(parsed$hitCount)
  if (is.na(reported_total)) reported_total <- total
  results <- parsed$resultList$result %||% list()
  n <- length(results)
  next_cursor <- scalar(parsed$nextCursorMark,NA_character_)

  raw_path <- file.path(raw_dir,sprintf("response_%06d.json",page))
  con <- file(raw_path,"wb"); writeBin(charToRaw(body),con); close(con)
  write_json(as.list(unclass(headers)),file.path(headers_dir,sprintf("response_%06d_headers.json",page)))

  page_summaries[[length(page_summaries)+1L]] <- list(
    page=page,requested_count=requested,returned_records=n,
    total_results_reported=total,raw_file=file.path("raw",basename(raw_path))
  )

  retrieved <- retrieved+n
  write_json(list(
    workflow="00f_europe_pmc_ingestion",status="running",updated_at=now_utc(),
    total_results_reported_first_page=reported_total,pages_completed=page,
    records_retrieved=retrieved,
    next_cursor_mark=if(!is.na(next_cursor)&&nzchar(next_cursor)) next_cursor else NULL,
    canonical_json_modified=FALSE
  ),checkpoint_path)

  if (n==0L) break
  if (!full_harvest && retrieved>=max_records) break
  if (full_harvest && !is.na(reported_total) && retrieved>=reported_total) break
  if (is.na(next_cursor)||!nzchar(next_cursor)||identical(next_cursor,cursor)) break
  cursor <- next_cursor
  page <- page+1L
}

raw_files <- sort(list.files(raw_dir,pattern="^response_[0-9]{6}\\.json$",full.names=TRUE))
keys <- character()
recount <- 0L
for (rf in raw_files) {
  x <- fromJSON(rf,simplifyVector=FALSE)
  rs <- x$resultList$result %||% list()
  recount <- recount+length(rs)
  for (r in rs) {
    src <- scalar(r$source,"")
    id <- scalar(r$id,"")
    if (!nzchar(src)||!nzchar(id)) stop(sprintf("Missing Europe PMC source/id in %s",basename(rf)),call.=FALSE)
    keys <- c(keys,paste(src,id,sep=":"))
  }
}

dup_keys <- unique(keys[duplicated(keys)])
expected_complete <- full_harvest && !is.na(reported_total)
validation <- list(
  workflow="00f_europe_pmc_ingestion",
  validated_at=now_utc(),
  records_recounted_from_raw=recount,
  records_tracked_during_harvest=retrieved,
  unique_source_record_keys=length(unique(keys)),
  duplicate_source_record_keys_n=length(dup_keys),
  first_page_total_reported=reported_total,
  full_harvest_requested=full_harvest,
  count_matches_first_page_total=if(expected_complete) identical(recount,reported_total) else NA,
  canonical_json_modified=FALSE
)
write_json(validation,validation_path)

if (!identical(recount,retrieved)) stop("Validation failure: raw recount differs from running count",call.=FALSE)
if (length(dup_keys)>0L) stop(sprintf("Validation failure: %d duplicate Europe PMC source/id keys",length(dup_keys)),call.=FALSE)
if (expected_complete && !identical(recount,reported_total)) stop(sprintf("Validation failure: harvested %d, reported %d",recount,reported_total),call.=FALSE)

manifest$status <- "success"
manifest$completed_at <- now_utc()
manifest$total_results_reported_first_page <- reported_total
manifest$records_retrieved <- recount
manifest$pages_retrieved <- length(raw_files)
manifest$validation <- validation
manifest$pages <- page_summaries
manifest$output <- list(raw_responses="raw/response_*.json",response_headers="headers/response_*_headers.json",
                        checkpoint="checkpoint.json",validation="validation.json",manifest="manifest.json")
write_json(manifest,manifest_path)
write_json(list(workflow="00f_europe_pmc_ingestion",status="success",completed_at=now_utc(),
                records_retrieved=recount,pages_completed=length(raw_files),canonical_json_modified=FALSE),
           checkpoint_path)
message(sprintf("PASS: Europe PMC ingestion complete; %d records preserved.",recount))
