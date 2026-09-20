#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s', flag))
  args[[i + 1L]]
}

lens_path <- arg('--lens', 'canonical_store/data/canonical/current/repair/records.jsonl')
scopus_path <- arg('--scopus', 'inputs/scopus_sidecar/scopus_sidecar_records.jsonl')
output_dir <- arg('--output-dir', 'outputs/updater/scopus_lens_reconciliation')
if (!file.exists(lens_path)) stop(sprintf('Lens input not found: %s', lens_path))
if (!file.exists(scopus_path)) stop(sprintf('Scopus sidecar input not found: %s', scopus_path))
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(), tz='UTC', format='%Y-%m-%dT%H:%M:%SZ')
scalar <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NA_character_)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NA_character_ else y
}
norm_doi <- function(x) {
  y <- scalar(x)
  if (is.na(y)) return(NA_character_)
  y <- tolower(y)
  y <- sub('^https?://(dx\\.)?doi\\.org/', '', y)
  y <- sub('^doi:\\s*', '', y)
  y <- trimws(y)
  if (!nzchar(y)) NA_character_ else y
}
norm_title <- function(x) {
  y <- scalar(x)
  if (is.na(y)) return(NA_character_)
  y <- tolower(y)
  y <- gsub('&amp;', ' and ', y, fixed=TRUE)
  y <- gsub('[^[:alnum:]]+', ' ', y)
  y <- gsub('\\s+', ' ', y)
  trimws(y)
}
title_sim <- function(a,b) {
  a <- norm_title(a); b <- norm_title(b)
  if (is.na(a) || is.na(b) || !nzchar(a) || !nzchar(b)) return(NA_real_)
  as.numeric(stringsim(a,b,method='jw'))
}
first_author_text <- function(x) {
  if (is.null(x)) return(NA_character_)
  if (is.character(x)) {
    y <- trimws(x[[1L]])
    return(if (nzchar(y)) y else NA_character_)
  }
  if (is.list(x) && length(x)) {
    a <- x[[1L]]
    if (is.character(a)) {
      y <- trimws(a[[1L]])
      return(if (nzchar(y)) y else NA_character_)
    }
    if (is.list(a)) {
      cand <- a$display_name %||% a$name %||% a$full_name %||% a$surname %||% a$last_name
      y <- scalar(cand)
      return(y)
    }
  }
  NA_character_
}
surname_norm <- function(x) {
  y <- scalar(x)
  if (is.na(y)) return(NA_character_)
  y <- tolower(y)
  y <- gsub('[^[:alnum:] ]+', ' ', y)
  parts <- unlist(strsplit(trimws(y), '\\s+'))
  if (!length(parts)) return(NA_character_)
  parts[[1L]]
}
read_jsonl <- function(path) {
  lines <- readLines(path, warn=FALSE, encoding='UTF-8')
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines, fromJSON, simplifyVector=FALSE)
}

lens <- read_jsonl(lens_path)
scopus <- read_jsonl(scopus_path)
if (!length(lens)) stop('Lens input is empty')
if (!length(scopus)) stop('Scopus sidecar input is empty')

lens_meta <- lapply(seq_along(lens), function(i) {
  r <- lens[[i]]
  c <- r$canonical %||% list()
  list(
    index=i,
    lens_id=scalar(c$lens_id %||% r$identity$lens_id),
    record_id=scalar(c$record_id %||% r$identity$record_id),
    doi=norm_doi(c$doi),
    title=scalar(c$title),
    title_norm=norm_title(c$title),
    year=scalar(c$year),
    source=scalar(c$source),
    first_author=first_author_text(c$authors)
  )
})

doi_index <- new.env(hash=TRUE, parent=emptyenv())
title_index <- new.env(hash=TRUE, parent=emptyenv())
for (m in lens_meta) {
  if (!is.na(m$doi)) {
    old <- if (exists(m$doi, doi_index, inherits=FALSE)) get(m$doi, doi_index) else integer()
    assign(m$doi, c(old, m$index), doi_index)
  }
  if (!is.na(m$title_norm) && nzchar(m$title_norm)) {
    old <- if (exists(m$title_norm, title_index, inherits=FALSE)) get(m$title_norm, title_index) else integer()
    assign(m$title_norm, c(old, m$index), title_index)
  }
}

rows <- list()
for (s in scopus) {
  si <- s$sidecar_identity %||% list()
  mf <- s$mapped_fields %||% list()
  sid <- scalar(si$sidecar_record_id)
  seid <- scalar(si$scopus_eid)
  ssid <- scalar(si$scopus_id)
  sdoi <- norm_doi(si$doi %||% mf$doi)
  stitle <- scalar(mf$title)
  stitle_norm <- norm_title(stitle)
  syear <- scalar(mf$year)
  sauthor <- scalar(mf$first_author)

  candidate_indices <- integer()
  candidate_basis <- 'none'
  if (!is.na(sdoi) && exists(sdoi, doi_index, inherits=FALSE)) {
    candidate_indices <- get(sdoi, doi_index)
    candidate_basis <- 'doi'
  } else if (!is.na(stitle_norm) && exists(stitle_norm, title_index, inherits=FALSE)) {
    candidate_indices <- get(stitle_norm, title_index)
    candidate_basis <- 'exact_normalised_title'
  }

  if (!length(candidate_indices)) {
    rows[[length(rows)+1L]] <- data.frame(
      sidecar_record_id=sid, scopus_eid=seid, scopus_id=ssid, scopus_doi=sdoi,
      scopus_title=stitle, scopus_year=syear, candidate_basis='none',
      lens_id=NA_character_, lens_doi=NA_character_, lens_title=NA_character_,
      lens_year=NA_character_, title_similarity=NA_real_, first_author_compatible=NA,
      classification='scopus_only_no_candidate',
      stringsAsFactors=FALSE
    )
    next
  }

  for (idx in candidate_indices) {
    lm <- lens_meta[[idx]]
    tsim <- title_sim(stitle, lm$title)
    author_ok <- if (is.na(sauthor) || is.na(lm$first_author)) NA else {
      sa <- surname_norm(sauthor); la <- surname_norm(lm$first_author)
      if (is.na(sa) || is.na(la)) NA else identical(sa, la)
    }

    classification <- if (candidate_basis == 'doi') {
      if (is.na(tsim)) 'doi_match_title_unavailable'
      else if (tsim >= 0.90) 'doi_match_title_compatible'
      else 'doi_match_title_conflict'
    } else {
      year_ok <- !is.na(syear) && !is.na(lm$year) && substr(syear,1,4) == substr(lm$year,1,4)
      if (isTRUE(year_ok) && (is.na(author_ok) || isTRUE(author_ok))) 'metadata_candidate_no_doi'
      else 'metadata_candidate_weak'
    }

    rows[[length(rows)+1L]] <- data.frame(
      sidecar_record_id=sid, scopus_eid=seid, scopus_id=ssid, scopus_doi=sdoi,
      scopus_title=stitle, scopus_year=syear, candidate_basis=candidate_basis,
      lens_id=lm$lens_id, lens_doi=lm$doi, lens_title=lm$title,
      lens_year=lm$year, title_similarity=round(tsim,4), first_author_compatible=author_ok,
      classification=classification,
      stringsAsFactors=FALSE
    )
  }
}

out <- do.call(rbind, rows)
csv_path <- file.path(output_dir, 'reconciliation_candidates.csv')
write.csv(out, csv_path, row.names=FALSE, na='')

jsonl_path <- file.path(output_dir, 'reconciliation_candidates.jsonl')
con <- file(jsonl_path, open='wt', encoding='UTF-8')
for (i in seq_len(nrow(out))) writeLines(toJSON(as.list(out[i,]), auto_unbox=TRUE, null='null', na='null'), con)
close(con)

counts <- as.list(table(out$classification, useNA='ifany'))
scopus_ids <- unique(out$sidecar_record_id)
by_record <- lapply(scopus_ids, function(id) {
  z <- out[out$sidecar_record_id == id,,drop=FALSE]
  cls <- z$classification
  data.frame(
    sidecar_record_id=id,
    candidate_rows=nrow(z),
    has_compatible_doi_match=any(cls=='doi_match_title_compatible'),
    has_doi_conflict=any(cls=='doi_match_title_conflict'),
    has_metadata_candidate=any(cls=='metadata_candidate_no_doi'),
    scopus_only=all(cls=='scopus_only_no_candidate'),
    stringsAsFactors=FALSE
  )
})
record_summary <- do.call(rbind, by_record)
write.csv(record_summary, file.path(output_dir,'reconciliation_record_summary.csv'), row.names=FALSE)

summary <- list(
  workflow='workflow_01t_scopus_lens_reconciliation_audit',
  status='success',
  created_at=now_utc(),
  inputs=list(
    lens_path=lens_path,
    lens_records=length(lens),
    scopus_sidecar_path=scopus_path,
    scopus_records=length(scopus)
  ),
  safeguards=list(
    lens_input_read_only=TRUE,
    scopus_sidecar_read_only=TRUE,
    canonical_json_modified=FALSE,
    canonical_branch_written=FALSE,
    downstream_workflows_modified=FALSE,
    automatic_merges_performed=FALSE
  ),
  rules=list(
    doi='Exact normalised DOI generates candidates only; title similarity >= 0.90 is required for compatible DOI match.',
    doi_conflict='Same DOI with title similarity < 0.90 is flagged as DOI conflict and is never auto-accepted.',
    missing_doi='Only exact normalised-title candidates are surfaced; matching year and non-conflicting first-author surname are required for metadata_candidate_no_doi.',
    no_candidate='No candidate is labelled scopus_only_no_candidate for this audit only; it is not yet asserted absent from Lens beyond these conservative rules.'
  ),
  classification_rows=counts,
  scopus_record_level=list(
    records=length(scopus_ids),
    with_compatible_doi_match=sum(record_summary$has_compatible_doi_match),
    with_doi_conflict=sum(record_summary$has_doi_conflict),
    with_metadata_candidate=sum(record_summary$has_metadata_candidate),
    scopus_only_no_candidate=sum(record_summary$scopus_only)
  ),
  outputs=list(
    reconciliation_candidates_csv='reconciliation_candidates.csv',
    reconciliation_candidates_jsonl='reconciliation_candidates.jsonl',
    reconciliation_record_summary_csv='reconciliation_record_summary.csv'
  )
)
writeLines(toJSON(summary, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), file.path(output_dir,'reconciliation_audit.json'))
message(toJSON(summary, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'))
message('PASS: read-only Lens-vs-Scopus reconciliation audit complete; no source records modified.')
