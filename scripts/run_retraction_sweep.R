source("R/publication_status.R")
library(dplyr)
library(readr)
library(lubridate)

corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")
cache_file <- here::here("data", "reference", "openalex_retraction_status.csv")
sweep_audit_file <- here::here("data", "reference", "retraction_sweep_audit.csv")
detected_file <- here::here("data", "reference", "new_retractions_detected.csv")

api_key <- Sys.getenv("OPENALEX_API_KEY")
if (!nzchar(api_key)) stop("OPENALEX_API_KEY was not found.")
if (!file.exists(corpus_file)) stop("Corpus file was not found: ", corpus_file)

corpus <- readr::read_csv(corpus_file, show_col_types = FALSE, progress = FALSE)
if (!"record_id" %in% names(corpus)) stop("Corpus lacks record_id")
doi_col <- if ("doi_key" %in% names(corpus)) "doi_key" else if ("doi" %in% names(corpus)) "doi" else NULL
corpus$doi_for_lookup <- if (is.null(doi_col)) "" else normalise_doi_for_openalex(corpus[[doi_col]])
corpus_dois <- corpus |>
  transmute(record_id = as.character(record_id), doi_for_lookup, title = if ("title" %in% names(corpus)) as.character(title) else "") |>
  filter(nzchar(doi_for_lookup)) |>
  distinct(doi_for_lookup, .keep_all = TRUE)

if (file.exists(cache_file)) {
  cache <- readr::read_csv(cache_file, show_col_types = FALSE, progress = FALSE) |>
    mutate(
      doi_for_lookup = normalise_doi_for_openalex(doi_for_lookup),
      first_checked_at = as.POSIXct(first_checked_at, tz = "UTC"),
      last_checked_at = as.POSIXct(last_checked_at, tz = "UTC"),
      next_check_at = as.POSIXct(next_check_at, tz = "UTC")
    )
} else {
  cache <- tibble::tibble(
    doi_for_lookup = character(), openalex_id = character(), openalex_title = character(),
    openalex_is_retracted = logical(), openalex_lookup_status = character(), openalex_error = character(),
    first_checked_at = as.POSIXct(character(), tz = "UTC"), last_checked_at = as.POSIXct(character(), tz = "UTC"),
    next_check_at = as.POSIXct(character(), tz = "UTC")
  )
}

previously_retracted <- cache |>
  filter(openalex_is_retracted %in% TRUE) |>
  pull(doi_for_lookup)

now <- Sys.time()
max_dois_per_run <- as.integer(Sys.getenv("OPENALEX_SWEEP_MAX_DOIS", "500"))
if (is.na(max_dois_per_run) || max_dois_per_run < 1) max_dois_per_run <- 500L

due <- corpus_dois |>
  left_join(cache |> select(doi_for_lookup, next_check_at), by = "doi_for_lookup") |>
  filter(is.na(next_check_at) | next_check_at <= now) |>
  arrange(is.na(next_check_at), next_check_at, doi_for_lookup) |>
  slice_head(n = max_dois_per_run)

message(sprintf("Retraction sweep: %d corpus DOIs; %d due; checking %d this run.", nrow(corpus_dois), sum(is.na(corpus_dois$doi_for_lookup) == FALSE), nrow(due)))

if (nrow(due)) {
  results <- lookup_openalex_dois(due$doi_for_lookup, api_key = api_key, batch_size = 50L) |>
    mutate(checked_at = now)
  prior <- cache |> select(doi_for_lookup, first_checked_at)
  results <- results |>
    left_join(prior, by = "doi_for_lookup", suffix = c("", "_prior")) |>
    mutate(
      first_checked_at = coalesce(first_checked_at_prior, checked_at),
      next_check_at = if_else(
        openalex_is_retracted,
        as.POSIXct(NA, tz = "UTC"),
        if_else(is.na(first_checked_at_prior), checked_at + days(30), checked_at + days(90))
      )
    ) |>
    select(doi_for_lookup, openalex_id, openalex_title, openalex_is_retracted, openalex_lookup_status,
           openalex_error, first_checked_at, last_checked_at = checked_at, next_check_at)
  cache <- cache |> filter(!doi_for_lookup %in% due$doi_for_lookup) |> bind_rows(results)
}

cache <- cache |> semi_join(corpus_dois, by = "doi_for_lookup") |> arrange(doi_for_lookup)
current_retracted <- cache |> filter(openalex_is_retracted %in% TRUE) |>
  select(doi_for_lookup, openalex_id, openalex_title, last_checked_at)
newly_detected <- current_retracted |>
  filter(!doi_for_lookup %in% previously_retracted) |>
  left_join(corpus_dois, by = "doi_for_lookup") |>
  mutate(detected_at = format(now, tz = "UTC", usetz = TRUE)) |>
  select(record_id, doi_for_lookup, title, openalex_id, openalex_title, last_checked_at, detected_at)

readr::write_csv(cache, cache_file, na = "")
readr::write_csv(newly_detected, detected_file, na = "")
readr::write_csv(
  tibble::tibble(
    swept_at = format(now, tz = "UTC", usetz = TRUE), corpus_dois = nrow(corpus_dois),
    due_dois = nrow(due), checked_dois = nrow(due), currently_retracted = nrow(current_retracted),
    newly_detected_retractions = nrow(newly_detected)
  ),
  sweep_audit_file,
  na = ""
)
message(sprintf("Retraction sweep complete: %d currently retracted; %d newly detected.", nrow(current_retracted), nrow(newly_detected)))
