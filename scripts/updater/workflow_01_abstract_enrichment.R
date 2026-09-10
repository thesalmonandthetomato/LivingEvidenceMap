#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s', flag))
  args[[i + 1L]]
}
input_path <- arg('--input', 'data/canonical/current/repair/records.jsonl')
output_path <- arg('--output', 'fresh_rebuild_01/enriched_records.jsonl')
audit_path <- arg('--audit', 'fresh_rebuild_01/abstract_enrichment_audit.jsonl')
report_path <- arg('--report', 'fresh_rebuild_01/abstract_enrichment_report.json')
manifest_path <- arg('--manifest', 'data/canonical/current/repair/manifest.json')
checkpoint_dir <- arg('--checkpoint-dir', 'fresh_rebuild_01/checkpoints')
checkpoint_every <- as.integer(arg('--checkpoint-every', '250'))
delay <- as.numeric(arg('--delay', '0.08'))
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop('--checkpoint-every must be a positive integer')

base <- 'https://www.ebi.ac.uk/europepmc/webservices/rest/search'
max_chars <- 12000L
now_utc <- function() format(Sys.time(), tz = 'UTC', format = '%Y-%m-%dT%H:%M:%SZ')
`%||%` <- function(x, y) if (is.null(x)) y else x
norm_doi <- function(v) {
  if (is.null(v) || !length(v) || !nzchar(trimws(as.character(v)))) return(NULL)
  s <- tolower(trimws(as.character(v)))
  prefixes <- c('https://doi.org/', 'http://doi.org/', 'http://dx.doi.org/', 'doi:')
  for (p in prefixes) if (startsWith(s, p)) s <- trimws(substring(s, nchar(p) + 1L))
  if (nzchar(s)) s else NULL
}
html_decode <- function(s) {
  if (!nzchar(s)) return(s)
  replacements <- c('&amp;'='&','&lt;'='<','&gt;'='>','&quot;'='"','&#39;'="'",'&apos;'="'")
  for (k in names(replacements)) s <- gsub(k, replacements[[k]], s, fixed = TRUE)
  m <- gregexpr('&#(?:x[0-9A-Fa-f]+|[0-9]+);', s, perl = TRUE)[[1]]
  if (m[1] == -1L) return(s)
  hits <- regmatches(s, list(m))[[1]]
  for (h in hits) {
    core <- sub('^&#', '', sub(';$', '', h))
    value <- if (startsWith(tolower(core), 'x')) strtoi(substring(core, 2L), base = 16L) else as.integer(core)
    s <- sub(h, intToUtf8(value), s, fixed = TRUE)
  }
  s
}
clean_abstract <- function(v) {
  if (is.null(v) || !length(v)) return(NULL)
  s <- enc2utf8(as.character(v))
  s <- gsub('<!\\[CDATA\\[(.*?)\\]\\]>', '\\1', s, perl = TRUE)
  s <- gsub('<!--.*?-->', ' ', s, perl = TRUE)
  labels <- '(abstract|aim|aims|background|conclusion|conclusions|discussion|importance|introduction|method|methods|objective|objectives|purpose|result|results|summary)'
  s <- gsub(paste0('<title(?:\\s[^>]*)?>\\s*', labels, '\\s*</title>'), ' ', s, ignore.case = TRUE, perl = TRUE)
  s <- gsub('</?(abstract|abstract-text|body|br|div|p|sec|section|title)(?:\\s[^>]*)?>', ' ', s, ignore.case = TRUE, perl = TRUE)
  s <- gsub('<[^>]+>', ' ', s, perl = TRUE)
  s <- html_decode(html_decode(s))
  s <- trimws(gsub('\\s+', ' ', s, perl = TRUE))
  s <- sub('^abstract\\s*[:.\\-–—]?\\s*', '', s, ignore.case = TRUE, perl = TRUE)
  if (!nzchar(s)) return(NULL)
  substr(s, 1L, max_chars)
}
read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = 'UTF-8')
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE), error = function(e) stop(sprintf('Invalid canonical JSON at line %d: %s', i, conditionMessage(e)))))
}
payload <- function(r) r$lens$raw_payload %||% list()
lens_id <- function(r) as.character(r$identity$lens_id %||% payload(r)$lens_id %||% '')
doi <- function(r) {
  d <- norm_doi(r$canonical$doi)
  if (!is.null(d)) return(d)
  ids <- payload(r)$external_ids
  if (is.list(ids)) for (x in ids) if (is.list(x) && identical(tolower(as.character(x$type %||% '')), 'doi')) {
    d <- norm_doi(x$value); if (!is.null(d)) return(d)
  }
  NULL
}
existing_abstract <- function(r) {
  for (v in list(r$canonical$abstract, payload(r)$abstract)) if (!is.null(v) && length(v) && nzchar(trimws(as.character(v)))) return(as.character(v))
  NULL
}
transient_status <- function(status) status == 429L || status >= 500L

epmc_lookup <- function(d) {
  retry_errors <- character()
  for (attempt in seq_len(4L)) {
    req <- request(base) |>
      req_url_query(query = sprintf('DOI:"%s"', d), format = 'json', resultType = 'core', pageSize = 5) |>
      req_headers(`User-Agent` = 'LivingEvidenceMap abstract enrichment R', Accept = 'application/json')
    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, 'error')) {
      status <- resp_status(resp)
      if (status < 400L) {
        dat <- resp_body_json(resp, simplifyVector = FALSE)
        hits <- dat$resultList$result %||% list()
        exact <- Filter(function(h) identical(norm_doi(h$doi), d), hits)
        abstract <- NULL
        if (length(exact)) for (h in exact) {
          candidate <- clean_abstract(h$abstractText)
          if (!is.null(candidate)) { abstract <- h$abstractText; break }
        }
        outcome <- if (!is.null(abstract)) 'abstract_recovered' else if (length(exact)) 'matched_no_abstract' else 'no_exact_match'
        return(list(abstract = abstract, attempt = list(method='europe_pmc_exact_doi', http_status=status, hit_count=dat$hitCount, exact_doi_hits=length(exact), outcome=outcome, request_attempts=attempt, retry_errors=retry_errors)))
      }
      retry_errors <- c(retry_errors, sprintf('HTTP %d', status))
      if (!transient_status(status)) stop(sprintf('Europe PMC HTTP %d', status))
    } else retry_errors <- c(retry_errors, conditionMessage(resp))
    if (attempt < 4L) {
      wait <- c(1,2,4)[attempt]
      message(sprintf('Europe PMC request for DOI %s failed on attempt %d (%s); retrying in %ss', d, attempt, tail(retry_errors, 1), wait))
      Sys.sleep(wait)
    }
  }
  stop(sprintf('Europe PMC failed after 4 attempts: %s', paste(retry_errors, collapse=' | ')))
}

manifest <- fromJSON(manifest_path, simplifyVector = FALSE)
expected <- as.integer(manifest$unique_records_written %||% manifest$lens_reported_total %||% NA_integer_)
if (is.na(expected) || expected <= 0L) stop('Workflow 01 cannot derive expected cardinality from Workflow 00 manifest')
rows <- read_jsonl(input_path)
if (length(rows) != expected) stop(sprintf('Canonical cardinality guard failed: expected %d from Workflow 00 manifest, parsed %d', expected, length(rows)))
ids <- vapply(rows, lens_id, character(1))
if (any(!nzchar(ids)) || anyDuplicated(ids)) stop('Lens-ID invariant failed before abstract enrichment')
if (any(vapply(rows, function(r) !is.null(r$deduplication) || !is.null(r$screening) || !is.null(r$screening_history), logical(1)))) stop('Unexpected downstream state exists before Workflow 01')

# Checkpoint files are deliberately separate from the canonical output. They are
# uploaded by the workflow even when this script fails, but are never promoted
# to the canonical branch unless the whole stage passes its invariants.
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
checkpoint_records_path <- file.path(checkpoint_dir, 'enriched_records.partial.jsonl')
checkpoint_audit_path <- file.path(checkpoint_dir, 'abstract_enrichment_audit.partial.jsonl')
checkpoint_manifest_path <- file.path(checkpoint_dir, 'checkpoint_manifest.json')
records_con <- file(checkpoint_records_path, 'wt', encoding='UTF-8')
audit_con <- file(checkpoint_audit_path, 'wt', encoding='UTF-8')
on.exit({
  try(close(records_con), silent = TRUE)
  try(close(audit_con), silent = TRUE)
}, add = TRUE)

write_checkpoint_manifest <- function(processed, last_id, status_counts, technical_errors, complete = FALSE) {
  cp <- list(
    workflow = 'workflow_01_abstract_enrichment',
    implementation_language = 'R',
    checkpoint_created_at = now_utc(),
    expected_records = expected,
    processed_records = processed,
    last_processed_lens_id = last_id,
    checkpoint_every = checkpoint_every,
    status_counts = status_counts,
    technical_errors = technical_errors,
    complete = complete,
    partial_records_path = checkpoint_records_path,
    partial_audit_path = checkpoint_audit_path
  )
  writeLines(toJSON(cp, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), checkpoint_manifest_path)
  message(sprintf('Workflow 01 checkpoint: %d/%d processed; last Lens ID=%s; technical errors=%d', processed, expected, last_id, technical_errors))
}

out <- vector('list', length(rows))
audit <- vector('list', length(rows))
status_counts <- list()
technical_errors <- 0L
for (i in seq_along(rows)) {
  r <- rows[[i]]
  d <- doi(r)
  old <- existing_abstract(r)
  recovered <- NULL
  attempts <- list()
  if (!is.null(old)) {
    status <- 'existing_abstract'
  } else if (is.null(d)) {
    status <- 'missing_no_doi'
  } else {
    result <- tryCatch(epmc_lookup(d), error = identity)
    if (inherits(result, 'error')) {
      attempts <- list(list(method='europe_pmc_exact_doi', outcome='technical_error', error=conditionMessage(result)))
      status <- 'technical_error'
      technical_errors <- technical_errors + 1L
      message(sprintf('Workflow 01 technical error at %d/%d, Lens ID %s, DOI %s: %s', i, expected, lens_id(r), d, conditionMessage(result)))
    } else {
      recovered <- result$abstract
      attempts <- list(result$attempt)
      status <- if (!is.null(recovered)) 'abstract_recovered' else 'no_abstract_recovered'
    }
    Sys.sleep(delay)
  }
  source_abstract <- if (!is.null(old)) old else recovered
  cleaned <- clean_abstract(source_abstract)
  enriched <- r
  if (is.null(enriched$canonical)) enriched$canonical <- list()
  enriched$canonical$abstract <- cleaned
  enriched$abstract_enrichment <- list(
    workflow = 'workflow_01_abstract_enrichment', implementation_language = 'R', provider = 'europe_pmc', status = status, doi = d,
    retrieved_at = if (!is.null(recovered)) now_utc() else NULL, attempts = attempts,
    cleaning = list(method='html_jats_plaintext_v1_R', source_chars=nchar(source_abstract %||% '', type='chars'), cleaned_chars=nchar(cleaned %||% '', type='chars'), changed=!is.null(source_abstract) && !identical(source_abstract, cleaned))
  )
  if (!identical(payload(r), payload(enriched))) stop(sprintf('Lens raw payload changed at record %s', lens_id(r)))
  audit_row <- list(lens_id=lens_id(r), doi=d, status=status, abstract_chars=nchar(cleaned %||% '', type='chars'), abstract_source_chars=nchar(source_abstract %||% '', type='chars'), abstract_text_normalised=!is.null(source_abstract) && !identical(source_abstract, cleaned), attempts=attempts)
  out[[i]] <- enriched
  audit[[i]] <- audit_row
  status_counts[[status]] <- (status_counts[[status]] %||% 0L) + 1L

  # Append each completed record immediately so work survives a later script error.
  writeLines(toJSON(enriched, auto_unbox=TRUE, null='null', na='null', digits=NA), records_con)
  writeLines(toJSON(audit_row, auto_unbox=TRUE, null='null', na='null', digits=NA), audit_con)
  flush(records_con)
  flush(audit_con)

  if (i %% checkpoint_every == 0L || i == length(rows)) {
    write_checkpoint_manifest(i, lens_id(r), status_counts, technical_errors, complete = i == length(rows))
  }
}

close(records_con)
close(audit_con)

# The partial audit is now complete. Copy it to the stage-level audit path so
# downstream inspection uses the same evidence that was checkpointed.
dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)
if (!file.copy(checkpoint_audit_path, audit_path, overwrite = TRUE)) stop('Failed to promote completed audit from checkpoint file')
if (technical_errors > 0L) stop(sprintf('Workflow 01 blocked: %d Europe PMC request(s) ended in technical_error; canonical output was not promoted. Recoverable partial outputs are in %s', technical_errors, checkpoint_dir))

# Only after all records are processed without technical errors do we promote
# the complete checkpointed records to the stage output.
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
if (!file.copy(checkpoint_records_path, output_path, overwrite = TRUE)) stop('Failed to promote completed records from checkpoint file')
report <- list(
  workflow='workflow_01_abstract_enrichment', implementation_language='R', provider='europe_pmc', created_at=now_utc(),
  total_records=length(rows), expected_records=expected, status_counts=status_counts,
  abstracts_recovered=status_counts[['abstract_recovered']] %||% 0L,
  abstract_texts_normalised=sum(vapply(audit, function(x) isTRUE(x$abstract_text_normalised), logical(1))),
  checkpoint_every=checkpoint_every,
  checkpoint_dir=checkpoint_dir,
  output='deduplication_ready'
)
writeLines(toJSON(report, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), report_path)
manifest$abstract_enrichment <- list(workflow='workflow_01_abstract_enrichment', implementation_language='R', completed_at=now_utc(), provider='europe_pmc', report=report)
manifest$pipeline_stage <- 'abstract_enriched_deduplication_ready'
writeLines(toJSON(manifest, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), manifest_path)
message(toJSON(report, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'))
message('PASS: Workflow 01 complete; cardinality and Lens raw payload preserved; checkpointed outputs promoted.')
