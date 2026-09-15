#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(readr)
  library(tibble)
})

`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s',flag))
  args[[i+1L]]
}

input_path <- arg('--input','canonical_store/data/canonical/current/repair/records.jsonl')
output_dir <- arg('--output-dir','outputs/retraction_sweep')
api_key <- Sys.getenv('OPENALEX_API_KEY')
if (!nzchar(api_key)) stop('OPENALEX_API_KEY was not found.')
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

now_utc <- function() format(Sys.time(),tz='UTC',format='%Y-%m-%dT%H:%M:%SZ')
norm_doi <- function(x) {
  x <- as.character(x %||% '')
  x <- tolower(trimws(x))
  x <- sub('^https?://(dx\\.)?doi\\.org/','',x,perl=TRUE)
  x <- sub('^doi:\\s*','',x,perl=TRUE)
  trimws(x)
}
read_jsonl <- function(path) {
  x <- readLines(path,warn=FALSE,encoding='UTF-8')
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf('Invalid JSONL line %d: %s',i,conditionMessage(e)))))
}
write_jsonl <- function(rows,path) {
  con <- file(path,'wt',encoding='UTF-8'); on.exit(close(con))
  for(x in rows) writeLines(toJSON(x,auto_unbox=TRUE,null='null',na='null',digits=NA),con)
}
lens_id <- function(r) as.character(r$identity$lens_id %||% r$canonical$lens_id %||% r$lens$raw_payload$lens_id %||% '')
payload <- function(r) {
  p <- r$lens$raw_payload %||% list()
  if(is.list(p)) p else list()
}
title_of <- function(r) as.character(r$canonical$title %||% payload(r)$title %||% '')
extract_dois <- function(r) {
  vals <- character()
  cdoi <- r$canonical$doi %||% NULL
  if(!is.null(cdoi)) vals <- c(vals,as.character(unlist(cdoi,use.names=FALSE)))
  ids <- payload(r)$external_ids %||% list()
  if(is.list(ids)) {
    for(it in ids) {
      if(is.list(it) && tolower(as.character(it$type %||% ''))=='doi') vals <- c(vals,as.character(it$value %||% ''))
    }
  }
  vals <- unique(vapply(vals,norm_doi,character(1)))
  vals[nzchar(vals)]
}
notice_type <- function(title) {
  t <- as.character(title %||% '')
  if(grepl('^\\s*(retraction(?:\\s+notice)?|retracted)\\s*[:\\-—.]',t,ignore.case=TRUE,perl=TRUE)) return('retraction_notice')
  if(grepl('^\\s*(withdrawn|withdrawal)\\s*[:\\-—.]',t,ignore.case=TRUE,perl=TRUE)) return('withdrawal_notice')
  if(grepl('^\\s*(correction|corrigendum|erratum)\\s*[:\\-—.]',t,ignore.case=TRUE,perl=TRUE)) return('correction_notice')
  NA_character_
}
empty_lookup <- function(doi,status='not_found',err=NA_character_) tibble(
  doi_for_lookup=doi,openalex_id=NA_character_,openalex_title=NA_character_,
  openalex_is_retracted=FALSE,openalex_lookup_status=status,openalex_error=err
)
lookup_batch <- function(batch) {
  tryCatch({
    filter_value <- paste0('doi:',paste(batch,collapse='|'))
    body <- request('https://api.openalex.org/works') |>
      req_url_query(filter=filter_value,api_key=api_key,select='id,doi,display_name,is_retracted',per_page=length(batch)) |>
      req_timeout(30) |>
      req_retry(max_tries=4,backoff=~min(20,2^.x)) |>
      req_perform() |>
      resp_body_json(simplifyVector=FALSE)
    works <- body$results %||% list()
    found <- if(length(works)) map_dfr(works,function(w) tibble(
      doi_for_lookup=norm_doi(w$doi %||% ''),
      openalex_id=as.character(w$id %||% NA_character_),
      openalex_title=as.character(w$display_name %||% NA_character_),
      openalex_is_retracted=isTRUE(w$is_retracted),
      openalex_lookup_status='matched',
      openalex_error=NA_character_
    )) else tibble()
    missing <- setdiff(batch,found$doi_for_lookup %||% character())
    if(length(missing)) found <- bind_rows(found,map_dfr(missing,~empty_lookup(.x,'not_found')))
    found
  },error=function(e) {
    warning(conditionMessage(e))
    map_dfr(batch,~empty_lookup(.x,'failed',conditionMessage(e)))
  })
}

records <- read_jsonl(input_path)
n <- length(records)
ids <- vapply(records,lens_id,character(1))
if(any(!nzchar(ids)) || anyDuplicated(ids)) stop('Lens-ID invariant failed')

record_rows <- map_dfr(seq_along(records),function(i){
  r <- records[[i]]
  ds <- extract_dois(r)
  tibble(
    record_index=i-1L,
    lens_id=lens_id(r),
    dedup_status=as.character(r$deduplication$status %||% ''),
    duplicate_of=as.character(r$deduplication$duplicate_of %||% ''),
    title=title_of(r),
    notice_type=notice_type(title_of(r)),
    doi_count=length(ds),
    dois=list(ds)
  )
})

doi_rows <- record_rows |> select(record_index,lens_id,dois) |> tidyr::unnest_longer(dois,values_to='doi_for_lookup') |> filter(nzchar(doi_for_lookup))
unique_dois <- sort(unique(doi_rows$doi_for_lookup))
message(sprintf('Retraction audit: %d records; %d record-DOI assignments; %d unique DOI values.',n,nrow(doi_rows),length(unique_dois)))

batch_size <- 25L
batches <- split(unique_dois,ceiling(seq_along(unique_dois)/batch_size))
lookup <- vector('list',length(batches))
for(i in seq_along(batches)) {
  message(sprintf('OpenAlex retraction lookup: batch %d/%d (%d DOIs)',i,length(batches),length(batches[[i]])))
  lookup[[i]] <- lookup_batch(batches[[i]])
}
lookup <- bind_rows(lookup)
if(anyDuplicated(lookup$doi_for_lookup)) stop('OpenAlex lookup returned duplicate DOI rows')

record_doi_status <- doi_rows |> left_join(lookup,by='doi_for_lookup')
direct_by_record <- record_doi_status |>
  group_by(record_index,lens_id) |>
  summarise(
    any_doi_retracted=any(openalex_is_retracted %in% TRUE),
    retracted_dois=list(doi_for_lookup[openalex_is_retracted %in% TRUE]),
    lookup_failed=any(openalex_lookup_status=='failed'),
    .groups='drop'
  )

audit <- record_rows |>
  left_join(direct_by_record,by=c('record_index','lens_id')) |>
  mutate(
    any_doi_retracted=coalesce(any_doi_retracted,FALSE),
    lookup_failed=coalesce(lookup_failed,FALSE),
    direct_retraction = any_doi_retracted | notice_type %in% c('retraction_notice','withdrawal_notice')
  )

# Cluster identity uses representative Lens ID for duplicate records and own Lens ID
# for canonical/unique records. This keeps every manifestation in the accounting.
audit <- audit |>
  mutate(cluster_id=if_else(dedup_status=='duplicate' & nzchar(duplicate_of),duplicate_of,lens_id))

cluster_status <- audit |>
  group_by(cluster_id) |>
  summarise(
    cluster_records=n(),
    cluster_direct_retractions=sum(direct_retraction),
    cluster_contains_retracted_manifestation=any(direct_retraction),
    retracted_manifestation_ids=list(lens_id[direct_retraction]),
    .groups='drop'
  )

audit <- audit |> left_join(cluster_status,by='cluster_id')

# Annotate every canonical record without removing anything.
out_records <- records
idx_by_id <- setNames(seq_along(records),ids)
for(i in seq_along(out_records)) {
  row <- audit[audit$record_index==(i-1L),,drop=FALSE]
  r <- out_records[[i]]
  r$publication_status <- list(
    workflow='retraction_sweep',
    checked_at=now_utc(),
    direct_retraction=isTRUE(row$direct_retraction[[1]]),
    retraction_notice=identical(row$notice_type[[1]],'retraction_notice'),
    withdrawal_notice=identical(row$notice_type[[1]],'withdrawal_notice'),
    correction_notice=identical(row$notice_type[[1]],'correction_notice'),
    doi_retracted=isTRUE(row$any_doi_retracted[[1]]),
    retracted_dois=unlist(row$retracted_dois[[1]] %||% character(),use.names=FALSE),
    openalex_lookup_failed=isTRUE(row$lookup_failed[[1]]),
    cluster_id=as.character(row$cluster_id[[1]]),
    cluster_contains_retracted_manifestation=isTRUE(row$cluster_contains_retracted_manifestation[[1]]),
    cluster_direct_retractions=as.integer(row$cluster_direct_retractions[[1]]),
    removal_applied=FALSE
  )
  out_records[[i]] <- r
}

write_jsonl(out_records,file.path(output_dir,'records_with_retraction_status.jsonl'))
write_csv(lookup,file.path(output_dir,'openalex_retraction_status.csv'),na='')
write_csv(
  audit |> select(-dois,-retracted_dois,-retracted_manifestation_ids),
  file.path(output_dir,'retraction_record_audit.csv'),na=''
)
write_csv(
  cluster_status |> mutate(retracted_manifestation_ids=vapply(retracted_manifestation_ids,paste,collapse=';',FUN.VALUE=character(1))),
  file.path(output_dir,'retraction_cluster_audit.csv'),na=''
)

summary <- list(
  input_records=n,
  records_with_doi=sum(audit$doi_count>0),
  record_doi_assignments=nrow(doi_rows),
  unique_dois=length(unique_dois),
  openalex_matched=sum(lookup$openalex_lookup_status=='matched'),
  openalex_not_found=sum(lookup$openalex_lookup_status=='not_found'),
  openalex_failed=sum(lookup$openalex_lookup_status=='failed'),
  directly_retracted_records=sum(audit$direct_retraction),
  directly_retracted_duplicate_records=sum(audit$direct_retraction & audit$dedup_status=='duplicate'),
  directly_retracted_canonical_records=sum(audit$direct_retraction & audit$dedup_status=='canonical'),
  directly_retracted_unique_records=sum(audit$direct_retraction & audit$dedup_status=='unique'),
  clusters_with_retracted_manifestation=sum(cluster_status$cluster_contains_retracted_manifestation),
  records_in_clusters_with_retracted_manifestation=sum(audit$cluster_contains_retracted_manifestation),
  duplicate_records_in_clusters_with_retracted_manifestation=sum(audit$cluster_contains_retracted_manifestation & audit$dedup_status=='duplicate'),
  removal_applied=FALSE,
  completed_at=now_utc()
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null='null',na='null'),file.path(output_dir,'retraction_summary.json'))
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null='null',na='null'))
message('PASS: retraction audit complete; all manifestations retained and annotated.')
