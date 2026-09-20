#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag))
  args[[i + 1L]]
}

query <- arg("--query")
max_records <- as.integer(arg("--max-records", "100"))
page_size <- as.integer(arg("--page-size", "25"))
view <- toupper(arg("--view", "COMPLETE"))
output_dir <- arg("--output-dir", "outputs/updater/scopus_ingestion_test")
base_url <- arg("--base-url", "https://api.elsevier.com/content/search/scopus")

if (is.null(query) || !nzchar(trimws(query))) stop("--query is required")
if (is.na(max_records) || max_records < 1L) stop("--max-records must be >= 1")
if (is.na(page_size) || page_size < 1L) stop("--page-size must be >= 1")
if (!(view %in% c("STANDARD", "COMPLETE"))) stop("--view must be STANDARD or COMPLETE")

api_key <- Sys.getenv("SCOPUS_API_TOKEN", unset = "")
if (!nzchar(api_key)) stop("SCOPUS_API_TOKEN is required")

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

root <- normalizePath(output_dir, mustWork = FALSE)
raw_dir <- file.path(root, "raw")
headers_dir <- file.path(root, "headers")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(headers_dir, recursive = TRUE, showWarnings = FALSE)

manifest_path <- file.path(root, "manifest.json")
checkpoint_path <- file.path(root, "checkpoint.json")

write_json <- function(x, path) {
  writeLines(toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), path, useBytes = TRUE)
}

scalar_text <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0L) return(default)
  y <- as.character(x[[1L]])
  if (!nzchar(y)) default else y
}

scalar_int <- function(x, default = NA_integer_) {
  y <- suppressWarnings(as.integer(scalar_text(x, NA_character_)))
  if (is.na(y)) default else y
}

request_page <- function(start, count) {
  last_error <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(base_url) |>
      req_headers(
        Accept = "application/json",
        `X-ELS-APIKey` = api_key,
        `User-Agent` = "LivingEvidenceMap Scopus ingestion test"
      ) |>
      req_url_query(
        query = query,
        start = start,
        count = count,
        view = view,
        suppressNavLinks = "false"
      ) |>
      req_error(is_error = function(resp) FALSE)

    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, "error")) {
      status <- resp_status(resp)
      if (status < 400L) return(resp)

      body <- tryCatch(resp_body_string(resp), error = function(e) "")
      last_error <- sprintf("Scopus HTTP %d: %s", status, substr(body, 1L, 1000L))
      retryable <- status == 429L || status >= 500L
      if (!retryable) stop(last_error)
    } else {
      last_error <- conditionMessage(resp)
    }

    if (attempt < 6L) {
      wait <- min(60, 2^(attempt - 1L))
      message(sprintf("Scopus request attempt %d failed (%s); retrying in %ss", attempt, last_error, wait))
      Sys.sleep(wait)
    }
  }
  stop(sprintf("Scopus request failed after 6 attempts: %s", last_error))
}

started_at <- now_utc()
page <- 1L
start <- 0L
retrieved <- 0L
total_results <- NA_integer_
page_summaries <- list()

manifest <- list(
  workflow = "00b_scopus_ingestion_test",
  implementation_language = "R",
  status = "running",
  started_at = started_at,
  endpoint = base_url,
  query = query,
  view = view,
  max_records = max_records,
  requested_page_size = page_size,
  source = "Scopus Search API",
  raw_response_preservation = TRUE,
  canonicalisation_performed = FALSE,
  downstream_processing_performed = FALSE
)
write_json(manifest, manifest_path)

repeat {
  requested_count <- min(page_size, max_records - retrieved)
  if (requested_count <= 0L) break

  message(sprintf("Requesting Scopus page %d: start=%d count=%d", page, start, requested_count))
  resp <- request_page(start, requested_count)
  body_text <- resp_body_string(resp)
  headers <- resp_headers(resp)

  raw_path <- file.path(raw_dir, sprintf("response_%06d.json", page))
  con <- file(raw_path, open = "wb")
  writeBin(charToRaw(body_text), con)
  close(con)

  header_path <- file.path(headers_dir, sprintf("response_%06d_headers.json", page))
  write_json(as.list(headers), header_path)

  parsed <- tryCatch(
    fromJSON(body_text, simplifyVector = FALSE),
    error = function(e) stop(sprintf("Scopus returned HTTP 200 but invalid JSON on page %d: %s", page, conditionMessage(e)))
  )

  sr <- parsed[["search-results"]]
  if (is.null(sr) || !is.list(sr)) stop(sprintf("Missing search-results object on page %d", page))

  if (is.na(total_results)) total_results <- scalar_int(sr[["opensearch:totalResults"]])
  entries <- sr[["entry"]]
  if (is.null(entries)) entries <- list()
  if (!is.list(entries)) stop(sprintf("Unexpected entry structure on page %d", page))
  n_entries <- length(entries)

  page_summary <- list(
    page = page,
    start = start,
    requested_count = requested_count,
    returned_entries = n_entries,
    total_results = total_results,
    raw_file = sub(paste0("^", root, "/?"), "", raw_path),
    headers_file = sub(paste0("^", root, "/?"), "", header_path),
    request_id = scalar_text(headers[["x-els-reqid"]], NULL),
    rate_limit = scalar_text(headers[["x-ratelimit-limit"]], NULL),
    rate_limit_remaining = scalar_text(headers[["x-ratelimit-remaining"]], NULL),
    rate_limit_reset = scalar_text(headers[["x-ratelimit-reset"]], NULL)
  )
  page_summaries[[length(page_summaries) + 1L]] <- page_summary

  retrieved <- retrieved + n_entries
  checkpoint <- list(
    workflow = "00b_scopus_ingestion_test",
    updated_at = now_utc(),
    query = query,
    view = view,
    total_results = total_results,
    pages_completed = page,
    entries_retrieved = retrieved,
    next_start = start + n_entries,
    max_records = max_records
  )
  write_json(checkpoint, checkpoint_path)

  message(sprintf("Scopus page %d returned %d entries; cumulative=%d; total=%s",
                  page, n_entries, retrieved,
                  if (is.na(total_results)) "unknown" else as.character(total_results)))

  if (n_entries == 0L) break
  if (retrieved >= max_records) break
  if (!is.na(total_results) && retrieved >= total_results) break

  start <- start + n_entries
  page <- page + 1L
}

manifest$status <- "success"
manifest$completed_at <- now_utc()
manifest$total_results_reported_by_scopus <- total_results
manifest$entries_retrieved <- retrieved
manifest$pages_retrieved <- length(page_summaries)
manifest$pages <- page_summaries
manifest$output <- list(
  raw_responses = "raw/response_*.json",
  response_headers = "headers/response_*_headers.json",
  checkpoint = "checkpoint.json",
  manifest = "manifest.json"
)
write_json(manifest, manifest_path)

message(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
message(sprintf("PASS: Scopus ingestion complete; %d raw search entries preserved across %d page(s).", retrieved, length(page_summaries)))
