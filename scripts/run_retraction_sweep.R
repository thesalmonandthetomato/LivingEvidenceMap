# =============================================================================
# File: scripts/run_retraction_sweep.R
# Purpose: Rolling, cached surveillance for retractions across the full corpus.
# =============================================================================

source("R/publication_status.R")

library(dplyr)
library(readr)
library(purrr)
library(tibble)
library(lubridate)

corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")
cache_file <- here::here("data", "reference", "openalex_retraction_status.csv")
audit_file <- here::here("data", "reference", "retraction_sweep_audit.csv")
detected_file <- here::here("data", "reference", "new_retractions_detected.csv")

api_key <- Sys.getenv("OPENALEX_API_KEY")
if (!nzchar(api_key)) stop("OPENALEX_API_KEY was not found.")

if (!file.exists(corpus_file)) stop("Corpus file was not found: ", corpus_file)

corpus <- readr::read_csv(
  corpus_file,
  show_col_types = FALSE,
  progress = FALSE
)

if (!"record_id" %in% names(corpus)) stop("Corpus lacks record_id")

doi_col <- if ("doi_key" %in% names(corpus)) "doi_key" else if ("doi" %in% names(corpus)) "doi" else NULL

if (is.null(doi_col)) {
  corpus$doi_for_lookup <- ""
} else {
  corpus$doi_for_lookup <- normalise_doi_for_openalex(corpus[[doi_col]])
}

corpus_dois <- corpus |>
  transmute(
    record_id = as.character(record_id),
    doi_for_lookup,
    title = if ("title" %in% names(corpus)) as.character(title) else ""
  ) |>
  filter(nzchar(doi_for_lookup)) |>
  distinct(doi_for_lookup, .keep_all = TRUE)

if (file.exists(cache_file)) {
  cache <- readr::read_csv(cache_file, show_col_types = FALSE, progress = FALSE) |>
    mutate(
      doi_for_lookup = normalise_doi_for_openalex(doi_for_lookup),
      last_checked_at = as.POSIXct(last_checked_at, tz = "UTC"),
      next_check_at = as.POSIXct(next_check_at, tz = "UTC")
    )
} else {
  cache <- tibble(
    doi_for_lookup = character(),
    openalex_id = character(),
    openalex_title = character(),
    openalex_is_retracted = logical(),
    openalex_lookup_status = character(),
    openalex_error = character(),
    first_checked_at = as.POSIXct(character(), tz = "UTC"),
    last_checked_at = as.POSIXct(character(), tz = "UTC"),
    next_check_at = as.POSIXct(character(), tz = "UTC")
  )
}

now <- Sys.time()

# New DOIs are checked immediately. Existing non-retracted DOIs are checked
# first after 30 days and subsequently every 90 days. This makes the sweep
# continuous without repeatedly querying the entire corpus on every update.
due <- corpus_dois |>
  left_join(cache |> select(doi_for_lookup, next_check_at, openalex_is_retracted), by = "doi_for_lookup") |>
  filter(is.na(next_check_at) | next_check_at <= now)

message(sprintf("Retraction sweep: %d corpus DOIs; %d due for OpenAlex check.", nrow(corpus_dois), nrow(due)))

if (nrow(due)) {
  results <- lookup_openalex_dois(
    due$doi_for_lookup,
    api_key = api_key,
    batch_size = 50L
  )

  results <- results |>
    mutate(
      checked_at = now,
      first_checked_at = now
    )

  prior <- cache |>
    select(doi_for_lookup, first_checked_at)

  results <- results |>
    left_join(prior, by = "doi_for_lookup", suffix = c("", "_prior")) |>
    mutate(
      first_checked_at = coalesce(first_checked_at_prior, first_checked_at),
      next_check_at = if_else(
        openalex_is_retracted,
        as.POSIXct(NA, tz = "UTC"),
        if_else(
          is.na(first_checked_at_prior),
          checked_at + lubridate::days(30),
          checked_at + lubridate::days(90)
        )
      )
    ) |>
    select(
      doi_for_lookup,
      openalex_id,
      openalex_title,
      openalex_is_retracted,
      openalex_lookup_status,
      openalex_error,
      first_checked_at,
      last_checked_at = checked_at,
      next_check_at
    )

  cache <- cache |>
    filter(!doi_for_lookup %in% due$doi_for_lookup) |>
    bind_rows(results)
}

# Keep cache restricted to the current corpus and deterministic ordering.
cache <- cache |>
  semi_join(corpus_dois, by = "doi_for_lookup") |>
  arrange(doi_for_lookup)

readr::write_csv(cache, cache_file, na = "")

# Detect currently retracted works, and specifically flag those that were not
# previously known to be retracted in the cache snapshot used at the start.
current_retracted <- cache |>
  filter(openalex_is_retracted %in% TRUE) |>
  select(doi_for_lookup, openalex_id, openalex_title, last_checked_at)

previously_retracted <- character()
if (file.exists(audit_file)) {
  old_audit <- readr::read_csv(audit_file, show_col_types = FALSE, progress = FALSE)
  if ("doi_for_lookup" %in% names(old_audit)) {
    previously_retracted <- old_audit |>
      filter(openalex_is_retracted %in% TRUE) |>
      pull(doi_for_lookup)
  }
}

newly_detected <- current_retracted |>
  filter(!doi_for_lookup %in% previously_retracted) |>
  left_join(corpus_dois, by = "doi_for_lookup") |>
  mutate(detected_at = format(now, tz = "UTC", usetz = TRUE)) |>
  select(record_id, doi_for_lookup, title, openalex_id, openalex_title, last_checked_at, detected_at)

readr::write_csv(newly_detected, detected_file, na = "")
readr::write_csv(cache, audit_file, na = "")

message(sprintf("Retraction sweep complete: %d currently retracted; %d newly detected.", nrow(current_retracted), nrow(newly_detected)))
