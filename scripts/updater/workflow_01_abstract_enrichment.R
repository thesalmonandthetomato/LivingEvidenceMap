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
delay <- as.numeric(arg('--delay', '0.08'))

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
    if (attempt < 4L) Sys.sleep(c(1,2,4)[attempt])
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

out <- vector('list', length(rows))
audit <- vector('list', length(rows))
status_counts <- list()
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
  out[[i]] <- enriched
  audit[[i]] <- list(lens_id=lens_id(r), doi=d, status=status, abstract_chars=nchar(cleaned %||% '', type='chars'), abstract_source_chars=nchar(source_abstract %||% '', type='chars'), abstract_text_normalised=!is.null(source_abstract) && !identical(source_abstract, cleaned), attempts=attempts)
  status_counts[[status]] <- (status_counts[[status]] %||% 0L) + 1L
  if (i %% 250L == 0L || i == length(rows)) message(sprintf('Workflow 01 progress: %d/%d records processed', i, length(rows)))
}

dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)
write_jsonl <- function(xs, path) { con <- file(path, 'wt', encoding='UTF-8'); on.exit(close(con)); for (x in xs) writeLines(toJSON(x, auto_unbox=TRUE, null='null', na='null', digits=NA), con) }
write_jsonl(audit, audit_path)
if (any(vapply(audit, function(x) identical(x$status, 'technical_error'), logical(1)))) stop('Workflow 01 blocked: one or more Europe PMC requests ended in technical_error; canonical output was not promoted')

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write_jsonl(out, output_path)
report <- list(
  workflow='workflow_01_abstract_enrichment', implementation_language='R', provider='europe_pmc', created_at=now_utc(),
  total_records=length(rows), expected_records=expected, status_counts=status_counts,
  abstracts_recovered=status_counts[['abstract_recovered']] %||% 0L,
  abstract_texts_normalised=sum(vapply(audit, function(x) isTRUE(x$abstract_text_normalised), logical(1))), output='deduplication_ready'
)
writeLines(toJSON(report, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), report_path)
manifest$abstract_enrichment <- list(workflow='workflow_01_abstract_enrichment', implementation_language='R', completed_at=now_utc(), provider='europe_pmc', report=report)
manifest$pipeline_stage <- 'abstract_enriched_deduplication_ready'
writeLines(toJSON(manifest, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'), manifest_path)
message(toJSON(report, auto_unbox=TRUE, pretty=TRUE, null='null', na='null'))
message('PASS: Workflow 01 complete; cardinality and Lens raw payload preserved.')
