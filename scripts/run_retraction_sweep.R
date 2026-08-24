source("R/publication_status.R")
library(dplyr)
library(readr)
library(lubridate)
library(purrr)

corpus_file <- here::here("data", "master", "current", "living_evidence_map_master.csv")
cache_file <- here::here("data", "reference", "openalex_retraction_status.csv")
api_key <- Sys.getenv("OPENALEX_API_KEY")
if (!nzchar(api_key)) stop("OPENALEX_API_KEY was not found.")

corpus <- readr::read_csv(corpus_file, show_col_types = FALSE, progress = FALSE)
# The master evidence-map field is `doi`. Do not prefer the legacy/internal
# `doi_key` field: it does not contain the complete DOI coverage of the master.
if (!"doi" %in% names(corpus)) stop("The master corpus does not contain the expected `doi` column.")
doi_col <- "doi"

corpus_dois <- corpus |>
  transmute(
    record_id = as.character(record_id),
    doi_raw = as.character(.data[[doi_col]]),
    doi_for_lookup = normalise_doi_for_openalex(.data[[doi_col]])
  ) |>
  filter(nzchar(doi_for_lookup)) |>
  distinct(doi_for_lookup, .keep_all = TRUE)

cache_spec <- cols(
  doi_for_lookup = col_character(),
  openalex_id = col_character(),
  openalex_title = col_character(),
  openalex_is_retracted = col_logical(),
  openalex_lookup_status = col_character(),
  openalex_error = col_character(),
  last_checked_at = col_datetime(format = ""),
  next_check_at = col_datetime(format = "")
)

if (file.exists(cache_file)) {
  cache <- readr::read_csv(cache_file, col_types = cache_spec, na = c("", "NA"), show_col_types = FALSE)
} else {
  cache <- tibble::tibble(
    doi_for_lookup = character(),
    openalex_id = character(),
    openalex_title = character(),
    openalex_is_retracted = logical(),
    openalex_lookup_status = character(),
    openalex_error = character(),
    last_checked_at = as.POSIXct(character(), tz = "UTC"),
    next_check_at = as.POSIXct(character(), tz = "UTC")
  )
}

cache <- cache |>
  mutate(
    doi_for_lookup = as.character(doi_for_lookup),
    openalex_id = as.character(openalex_id),
    openalex_title = as.character(openalex_title),
    openalex_is_retracted = as.logical(openalex_is_retracted),
    openalex_lookup_status = as.character(openalex_lookup_status),
    openalex_error = as.character(openalex_error),
    last_checked_at = as.POSIXct(last_checked_at, tz = "UTC"),
    next_check_at = as.POSIXct(next_check_at, tz = "UTC")
  )

old_retracted <- cache |>
  filter(openalex_is_retracted %in% TRUE) |>
  pull(doi_for_lookup)

now <- Sys.time()
due <- corpus_dois

message(sprintf(
  "Full retraction sweep: %d corpus DOI values; checking %d unique DOI values.",
  nrow(filter(corpus, !is.na(.data[[doi_col]]), nzchar(trimws(as.character(.data[[doi_col]]))))),
  nrow(due)
))

if (nrow(due)) {
  batches <- split(due$doi_for_lookup, ceiling(seq_along(due$doi_for_lookup) / 25L))
  total_batches <- length(batches)
  batch_results <- vector("list", total_batches)

  for (i in seq_along(batches)) {
    batch <- batches[[i]]
    message(sprintf("OpenAlex retraction sweep: batch %d/%d (%d DOIs)", i, total_batches, length(batch)))
    result <- lookup_openalex_dois(batch, api_key = api_key, batch_size = length(batch))
    batch_results[[i]] <- result |>
      transmute(
        doi_for_lookup = as.character(doi_for_lookup),
        openalex_id = as.character(openalex_id),
        openalex_title = as.character(openalex_title),
        openalex_is_retracted = as.logical(openalex_is_retracted),
        openalex_lookup_status = as.character(openalex_lookup_status),
        openalex_error = as.character(openalex_error),
        last_checked_at = now,
        next_check_at = case_when(
          openalex_is_retracted %in% TRUE ~ as.POSIXct(NA, tz = "UTC"),
          openalex_lookup_status == "failed" ~ now + days(1),
          TRUE ~ now + days(90)
        )
      )
  }

  r <- bind_rows(batch_results)
  cache <- cache |>
    filter(!doi_for_lookup %in% due$doi_for_lookup) |>
    bind_rows(r)
}

cache <- cache |>
  semi_join(corpus_dois, by = "doi_for_lookup") |>
  arrange(doi_for_lookup)

current <- cache |>
  filter(openalex_is_retracted %in% TRUE) |>
  inner_join(corpus_dois, by = "doi_for_lookup")

new <- current |>
  filter(!doi_for_lookup %in% old_retracted) |>
  mutate(detected_at = format(now, tz = "UTC", usetz = TRUE))

readr::write_csv(cache, cache_file, na = "")
readr::write_csv(new, here::here("data", "reference", "new_retractions_detected.csv"), na = "")
readr::write_csv(
  tibble::tibble(
    swept_at = format(now, tz = "UTC", usetz = TRUE),
    corpus_records = nrow(corpus),
    corpus_doi_values = nrow(filter(corpus, !is.na(.data[[doi_col]]), nzchar(trimws(as.character(.data[[doi_col]]))))),
    corpus_dois = nrow(corpus_dois),
    checked_dois = nrow(due),
    currently_retracted = nrow(current),
    newly_detected_retractions = nrow(new)
  ),
  here::here("data", "reference", "retraction_sweep_audit.csv"),
  na = ""
)

message(sprintf(
  "Retraction sweep complete: %d currently retracted; %d newly detected.",
  nrow(current), nrow(new)
))
