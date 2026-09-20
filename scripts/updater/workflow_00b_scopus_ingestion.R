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
max_records_arg <- arg("--max-records", "100")
page_size <- as.integer(arg("--page-size", "200"))
view <- toupper(arg("--view", "STANDARD"))
output_dir <- arg("--output-dir", "outputs/updater/scopus_ingestion_test")
base_url <- arg("--base-url", "https://api.elsevier.com/content/search/scopus")

if (is.null(query) || !nzchar(trimws(query))) stop("--query is required")
full_harvest <- identical(tolower(max_records_arg), "all")
if (!full_harvest) {
  max_records <- suppressWarnings(as.integer(max_records_arg))
  if (is.na(max_records) || max_records < 1L) stop("--max-records must be >= 1 or 'all'")
} else {
  max_records <- .Machine$integer.max
}
if (is.na(page_size) || page_size < 1L) stop("--page-size must be >= 1")
if (view == "STANDARD" && page_size > 200L) stop("--page-size cannot exceed 200 for STANDARD")
if (view != "STANDARD" && page_size > 25L) stop("--page-size cannot exceed 25 for COMPLETE/other restricted views")
if (!(view %in% c("STANDARD", "COMPLETE"))) stop("--view must be STANDARD or COMPLETE")

api_key <- Sys.getenv("SCOPUS_API_TOKEN", unset = "")
if (!nzchar(api_key)) stop("SCOPUS_API_TOKEN is required")

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
`%||%` <- function(x, y) if (is.null(x)) y else x

root <- normalizePath(output_dir, mustWork = FALSE)
raw_dir <- file.path(root, "raw")
headers_dir <- file.path(root, "headers")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(headers_dir, recursive = TRUE, showWarnings = FALSE)

manifest_path <- file.path(root, "manifest.json")
checkpoint_path <- file.path(root, "checkpoint.json")
validation_path <- file.path(root, "validation.json")

write_json <- function(x, path) {
  tmp <- paste0(path, ".tmp")
  writeLines(toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA),
             tmp, useBytes = TRUE)
  if (!file.rename(tmp, path)) stop(sprintf("Could not atomically write %s", path))
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

request_page <- function(cursor, count) {
  last_error <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(base_url) |>
      req_headers(
        Accept = "application/json",
        `X-ELS-APIKey` = api_key,
        `User-Agent` = "LivingEvidenceMap Scopus ingestion"
      ) |>
      req_url_query(
        query = query,
        cursor = cursor,
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
      last_error <- sprintf("Scopus HTTP %d: %s", status, substr(body, 1L, 1200L))
      retryable <- status == 429L || status >= 500L
      if (!retryable) stop(last_error)
    } else {
      last_error <- conditionMessage(resp)
    }

    if (attempt < 6L) {
      wait <- min(60, 2^(attempt - 1L))
      message(sprintf("Scopus request attempt %d failed (%s); retrying in %ss",
                      attempt, last_error, wait))
      Sys.sleep(wait)
    }
  }
  stop(sprintf("Scopus request failed after 6 attempts: %s", last_error))
}

started_at <- now_utc()
page <- 1L
cursor <- "*"
retrieved <- 0L
total_results <- NA_integer_
page_summaries <- list()

manifest <- list(
  workflow = "00b_scopus_ingestion",
  implementation_language = "R",
  status = "running",
  started_at = started_at,
  endpoint = base_url,
  query = query,
  view = view,
  max_records_requested = if (full_harvest) "all" else max_records,
  requested_page_size = page_size,
  source = "Scopus Search API",
  search_scope = c("title", "abstract", "keywords"),
  raw_response_preservation = TRUE,
  checkpoint_after_every_page = TRUE,
  pagination_mode = "cursor",
  canonicalisation_performed = FALSE,
  canonical_json_modified = FALSE,
  downstream_processing_performed = FALSE
)
write_json(manifest, manifest_path)

repeat {
  requested_count <- page_size
  if (!full_harvest) requested_count <- min(page_size, max_records - retrieved)
  if (requested_count <= 0L) break

  message(sprintf("Requesting Scopus page %d: cursor=%s count=%d", page, if (page == 1L) "*" else "<next_cursor>", requested_count))
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
    error = function(e) stop(sprintf("Scopus returned HTTP 200 but invalid JSON on page %d: %s",
                                     page, conditionMessage(e)))
  )

  sr <- parsed[["search-results"]]
  if (is.null(sr) || !is.list(sr)) stop(sprintf("Missing search-results object on page %d", page))

  this_total <- scalar_int(sr[["opensearch:totalResults"]])
  if (is.na(total_results)) {
    total_results <- this_total
  } else if (!is.na(this_total) && !identical(this_total, total_results)) {
    message(sprintf("NOTE: Scopus reported total changed during harvest: first=%d current=%d",
                    total_results, this_total))
  }

  entries <- sr[["entry"]]
  if (is.null(entries)) entries <- list()
  if (!is.list(entries)) stop(sprintf("Unexpected entry structure on page %d", page))
  n_entries <- length(entries)
  cursor_obj <- sr[["cursor"]] %||% list()
  next_cursor <- scalar_text(cursor_obj[["@next"]], NA_character_)

  page_summary <- list(
    page = page,
    pagination_mode = "cursor",
    cursor_present = !is.na(next_cursor) && nzchar(next_cursor),
    requested_count = requested_count,
    returned_entries = n_entries,
    total_results_reported = this_total,
    raw_file = file.path("raw", basename(raw_path)),
    headers_file = file.path("headers", basename(header_path)),
    request_id = scalar_text(headers[["x-els-reqid"]], NULL),
    rate_limit = scalar_text(headers[["x-ratelimit-limit"]], NULL),
    rate_limit_remaining = scalar_text(headers[["x-ratelimit-remaining"]], NULL),
    rate_limit_reset = scalar_text(headers[["x-ratelimit-reset"]], NULL)
  )
  page_summaries[[length(page_summaries) + 1L]] <- page_summary

  retrieved <- retrieved + n_entries


  checkpoint <- list(
    workflow = "00b_scopus_ingestion",
    status = "running",
    updated_at = now_utc(),
    query = query,
    view = view,
    total_results_reported_first_page = total_results,
    pages_completed = page,
    entries_retrieved = retrieved,
    next_cursor = if (!is.na(next_cursor) && nzchar(next_cursor)) next_cursor else NULL,
    max_records_requested = if (full_harvest) "all" else max_records,
    rate_limit_remaining = scalar_text(headers[["x-ratelimit-remaining"]], NULL),
    rate_limit_reset = scalar_text(headers[["x-ratelimit-reset"]], NULL)
  )
  write_json(checkpoint, checkpoint_path)

  message(sprintf("Scopus page %d returned %d entries; cumulative=%d; first-page total=%s; rate-limit remaining=%s",
                  page, n_entries, retrieved,
                  if (is.na(total_results)) "unknown" else as.character(total_results),
                  scalar_text(headers[["x-ratelimit-remaining"]], "unknown")))

  if (n_entries == 0L) break
  if (!full_harvest && retrieved >= max_records) break
  if (full_harvest && !is.na(total_results) && retrieved >= total_results) break
  if (is.na(next_cursor) || !nzchar(next_cursor)) break

  cursor <- next_cursor
  page <- page + 1L
}

raw_files <- sort(list.files(raw_dir, pattern = "^response_[0-9]{6}\\.json$", full.names = TRUE))
eids <- character()
scopus_ids <- character()
recount <- 0L

for (rf in raw_files) {
  x <- fromJSON(rf, simplifyVector = FALSE)
  sr <- x[["search-results"]] %||% list()
  entries <- sr[["entry"]] %||% list()
  recount <- recount + length(entries)

  for (entry in entries) {
    eid <- scalar_text(entry[["eid"]], "")
    sid_raw <- scalar_text(entry[["dc:identifier"]], "")
    sid <- sub("^SCOPUS_ID:", "", sid_raw)
    if (!nzchar(eid)) stop(sprintf("Missing Scopus EID in %s", basename(rf)))
    eids <- c(eids, eid)
    if (nzchar(sid)) scopus_ids <- c(scopus_ids, sid)
  }
}

duplicate_eids <- unique(eids[duplicated(eids)])
duplicate_scopus_ids <- unique(scopus_ids[duplicated(scopus_ids)])
count_matches_pages <- identical(recount, retrieved)
expected_complete <- full_harvest && !is.na(total_results)
count_matches_reported_total <- if (expected_complete) identical(recount, total_results) else NA

validation <- list(
  workflow = "00b_scopus_ingestion",
  validated_at = now_utc(),
  raw_page_files = length(raw_files),
  records_recounted_from_raw = recount,
  records_tracked_during_harvest = retrieved,
  count_matches_page_accumulator = count_matches_pages,
  scopus_eids_present = length(eids),
  unique_scopus_eids = length(unique(eids)),
  duplicate_scopus_eids_n = length(duplicate_eids),
  duplicate_scopus_eids = duplicate_eids,
  scopus_ids_present = length(scopus_ids),
  unique_scopus_ids = length(unique(scopus_ids)),
  duplicate_scopus_ids_n = length(duplicate_scopus_ids),
  duplicate_scopus_ids = duplicate_scopus_ids,
  full_harvest_requested = full_harvest,
  first_page_total_reported_by_scopus = total_results,
  count_matches_first_page_total = count_matches_reported_total,
  canonical_json_modified = FALSE
)
write_json(validation, validation_path)

if (!count_matches_pages) stop("Validation failure: raw-page recount does not match running retrieved count")
if (length(duplicate_eids) > 0L) stop(sprintf("Validation failure: %d duplicate Scopus EIDs", length(duplicate_eids)))
if (length(duplicate_scopus_ids) > 0L) stop(sprintf("Validation failure: %d duplicate Scopus IDs", length(duplicate_scopus_ids)))
if (expected_complete && !isTRUE(count_matches_reported_total)) {
  stop(sprintf("Validation failure: full harvest retrieved %d records but Scopus first page reported %d",
               recount, total_results))
}

manifest$status <- "success"
manifest$completed_at <- now_utc()
manifest$total_results_reported_by_scopus_first_page <- total_results
manifest$entries_retrieved <- retrieved
manifest$pages_retrieved <- length(page_summaries)
manifest$validation <- validation
manifest$pages <- page_summaries
manifest$output <- list(
  raw_responses = "raw/response_*.json",
  response_headers = "headers/response_*_headers.json",
  checkpoint = "checkpoint.json",
  validation = "validation.json",
  manifest = "manifest.json"
)
write_json(manifest, manifest_path)

checkpoint$status <- "success"
checkpoint$completed_at <- now_utc()
checkpoint$next_cursor <- NULL
write_json(checkpoint, checkpoint_path)

message(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
message(sprintf("PASS: Scopus ingestion complete; %d raw search entries preserved across %d page(s).",
                retrieved, length(page_summaries)))
