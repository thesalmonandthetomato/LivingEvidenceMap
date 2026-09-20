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
page_size <- as.integer(arg("--page-size", "100"))
output_dir <- arg("--output-dir", "outputs/updater/openalex_ingestion_test")
base_url <- arg("--base-url", "https://api.openalex.org/")

if (is.null(query) || !nzchar(trimws(query))) stop("--query is required")
if (is.na(max_records) || max_records < 1L) stop("--max-records must be >= 1")
if (is.na(page_size) || page_size < 1L || page_size > 100L) stop("--page-size must be between 1 and 100")

api_key <- Sys.getenv("OPENALEX_API_KEY", unset = "")
if (!nzchar(api_key)) api_key <- Sys.getenv("OPENALEX_API_TOKEN", unset = "")
if (!nzchar(api_key)) stop("Neither OPENALEX_API_KEY nor OPENALEX_API_TOKEN is available")

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

root <- normalizePath(output_dir, mustWork = FALSE)
raw_dir <- file.path(root, "raw")
headers_dir <- file.path(root, "headers")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(headers_dir, recursive = TRUE, showWarnings = FALSE)

manifest_path <- file.path(root, "manifest.json")
checkpoint_path <- file.path(root, "checkpoint.json")

write_json <- function(x, path) {
  writeLines(toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
             path, useBytes = TRUE)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

scalar_text <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0L) return(default)
  y <- as.character(x[[1L]])
  if (!nzchar(y)) default else y
}

request_page <- function(cursor, count) {
  last_error <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(base_url) |>
      req_headers(
        Accept = "application/json",
        Authorization = paste("Bearer", api_key),
        `User-Agent` = "LivingEvidenceMap OpenAlex ingestion test"
      ) |>
      req_url_query(
        oql = query,
        `per-page` = count,
        cursor = cursor
      ) |>
      req_error(is_error = function(resp) FALSE)

    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, "error")) {
      status <- resp_status(resp)
      if (status < 400L) return(resp)

      body <- tryCatch(resp_body_string(resp), error = function(e) "")
      last_error <- sprintf("OpenAlex HTTP %d: %s", status, substr(body, 1L, 1200L))
      retryable <- status == 429L || status >= 500L
      if (!retryable) stop(last_error)
    } else {
      last_error <- conditionMessage(resp)
    }

    if (attempt < 6L) {
      wait <- min(60, 2^(attempt - 1L))
      message(sprintf("OpenAlex request attempt %d failed (%s); retrying in %ss",
                      attempt, last_error, wait))
      Sys.sleep(wait)
    }
  }
  stop(sprintf("OpenAlex request failed after 6 attempts: %s", last_error))
}

started_at <- now_utc()
page <- 1L
cursor <- "*"
retrieved <- 0L
reported_total <- NA_integer_
page_summaries <- list()

manifest <- list(
  workflow = "00c_openalex_ingestion_test",
  implementation_language = "R",
  status = "running",
  started_at = started_at,
  endpoint = base_url,
  query_parameter = "oql",
  query = query,
  max_records = max_records,
  requested_page_size = page_size,
  source = "OpenAlex Works API",
  search_scope = c("title", "abstract"),
  lens_search_scope_reference = c("title", "abstract", "keywords"),
  methodological_difference = "OpenAlex OQL title/abstract search excludes full text. Lens additionally searched keywords, so field scope is still not identical.",
  raw_response_preservation = TRUE,
  canonicalisation_performed = FALSE,
  downstream_processing_performed = FALSE
)
write_json(manifest, manifest_path)

repeat {
  requested_count <- min(page_size, max_records - retrieved)
  if (requested_count <= 0L) break

  message(sprintf("Requesting OpenAlex page %d: cursor=%s count=%d",
                  page, if (page == 1L) "*" else "<next_cursor>", requested_count))
  resp <- request_page(cursor, requested_count)
  body_text <- resp_body_string(resp)
  headers <- resp_headers(resp)
  headers_json <- as.list(unclass(headers))

  raw_path <- file.path(raw_dir, sprintf("response_%06d.json", page))
  con <- file(raw_path, open = "wb")
  writeBin(charToRaw(body_text), con)
  close(con)

  header_path <- file.path(headers_dir, sprintf("response_%06d_headers.json", page))
  write_json(headers_json, header_path)

  parsed <- tryCatch(
    fromJSON(body_text, simplifyVector = FALSE),
    error = function(e) stop(sprintf("OpenAlex returned invalid JSON on page %d: %s",
                                     page, conditionMessage(e)))
  )

  meta <- parsed[["meta"]]
  results <- parsed[["results"]]
  if (is.null(meta) || !is.list(meta)) stop(sprintf("Missing meta object on page %d", page))
  if (is.null(results)) results <- list()
  if (!is.list(results)) stop(sprintf("Unexpected results structure on page %d", page))

  if (is.na(reported_total)) {
    reported_total <- suppressWarnings(as.integer(meta[["count"]]))
  }

  n_results <- length(results)
  next_cursor <- scalar_text(meta[["next_cursor"]], NA_character_)

  page_summary <- list(
    page = page,
    requested_count = requested_count,
    returned_results = n_results,
    total_results = reported_total,
    cost_usd = meta[["cost_usd"]] %||% NULL,
    raw_file = sub(paste0("^", root, "/?"), "", raw_path),
    headers_file = sub(paste0("^", root, "/?"), "", header_path),
    rate_limit = scalar_text(headers[["x-ratelimit-limit"]], NULL),
    rate_limit_remaining = scalar_text(headers[["x-ratelimit-remaining"]], NULL),
    rate_limit_credits_used = scalar_text(headers[["x-ratelimit-credits-used"]], NULL),
    rate_limit_reset = scalar_text(headers[["x-ratelimit-reset"]], NULL)
  )
  page_summaries[[length(page_summaries) + 1L]] <- page_summary

  retrieved <- retrieved + n_results
  checkpoint <- list(
    workflow = "00c_openalex_ingestion_test",
    updated_at = now_utc(),
    query = query,
    total_results = reported_total,
    pages_completed = page,
    entries_retrieved = retrieved,
    next_cursor_present = !is.na(next_cursor) && nzchar(next_cursor),
    max_records = max_records
  )
  write_json(checkpoint, checkpoint_path)

  message(sprintf("OpenAlex page %d returned %d works; cumulative=%d; total=%s",
                  page, n_results, retrieved,
                  if (is.na(reported_total)) "unknown" else as.character(reported_total)))

  if (n_results == 0L) break
  if (retrieved >= max_records) break
  if (!is.na(reported_total) && retrieved >= reported_total) break
  if (is.na(next_cursor) || !nzchar(next_cursor)) break

  cursor <- next_cursor
  page <- page + 1L
}

manifest$status <- "success"
manifest$completed_at <- now_utc()
manifest$total_results_reported_by_openalex <- reported_total
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
message(sprintf("PASS: OpenAlex ingestion complete; %d raw works preserved across %d page(s).",
                retrieved, length(page_summaries)))
