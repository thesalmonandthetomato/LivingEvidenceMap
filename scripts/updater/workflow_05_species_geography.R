#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(fs)
  library(here)
  library(jsonlite)
  library(readr)
  library(tibble)
})

# Workflow 05A: deterministic species and geography identification.
# The annotation method is unchanged from the established Workflow 05/main
# implementation. This adapter differs only in consuming the stable canonical
# record_id corpus already retained by Workflow 04.

source("scripts/setup_pipeline.R")
source("R/species_detect.R")
source("R/species_filter.R")
source("R/species_assign.R")
source("R/species_annotation.R")
source("R/geography_detect.R")
source("R/geography_primary_country.R")
source("R/llm_adjudication.R")

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}
input_path <- arg("--input")
output_dir <- arg("--output-dir", "outputs/workflow05/deterministic")
expected_records <- as.integer(arg("--expected-records", "19407"))
if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input canonical JSONL is required", call. = FALSE)
dir_create(output_dir, recurse = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x
clean <- function(x) { x <- as.character(x); x[is.na(x)] <- ""; trimws(x) }
first_nonempty <- function(...) {
  for (x in list(...)) {
    if (is.null(x)) next
    z <- clean(unlist(x, use.names = FALSE))
    z <- z[nzchar(z)]
    if (length(z)) return(z[[1L]])
  }
  ""
}
read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) {
    tryCatch(jsonlite::fromJSON(lines[[i]], simplifyVector = FALSE),
      error = function(e) stop(sprintf("Invalid JSONL line %d: %s", i, conditionMessage(e)), call. = FALSE))
  })
}
record_id_of <- function(r) first_nonempty((r$identity %||% list())$record_id)
title_of <- function(r) first_nonempty((r$canonical %||% list())$title)
abstract_of <- function(r) first_nonempty((r$canonical %||% list())$abstract)

message("Workflow 05A: loading Workflow 04-retained canonical JSONL.")
canonical_records <- read_jsonl(input_path)
if (!length(canonical_records)) stop("Canonical JSONL is empty", call. = FALSE)
if (!is.na(expected_records) && expected_records > 0L && length(canonical_records) != expected_records) {
  stop(sprintf("Expected %d Workflow 04-retained records, found %d", expected_records, length(canonical_records)), call. = FALSE)
}

records <- tibble(
  record_sequence = seq_along(canonical_records),
  canonical_index = seq_along(canonical_records),
  record_id = vapply(canonical_records, record_id_of, character(1)),
  title = vapply(canonical_records, title_of, character(1)),
  abstract = vapply(canonical_records, abstract_of, character(1))
)
if (any(!nzchar(records$record_id))) stop("Every Workflow 05 record must have a stable canonical record_id", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("Workflow 05 stable record_id values are not unique", call. = FALSE)
write_csv(records, path(output_dir, "records_for_annotation.csv"), na = "")
message(sprintf("Workflow 05A: %d Workflow 04-retained records accepted.", nrow(records)))

species_dictionary <- read_csv(here("config", "species_dictionary.csv"), show_col_types = FALSE, progress = FALSE)
gazetteer <- read_csv(here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE, progress = FALSE)

message("Workflow 05A: starting established deterministic species annotation.")
species <- annotate_species(records |> select(record_sequence, record_id, title, abstract), species_dictionary, progress = TRUE)
write_csv(species$species_mentions, path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, path(output_dir, "species_annotation_failures.csv"), na = "")
if (nrow(species$failures)) stop(sprintf("Deterministic species annotation had %d technical failures", nrow(species$failures)), call. = FALSE)

message("Workflow 05A: starting established deterministic geography detection.")
geo_mentions <- detect_geography_mentions(records |> select(record_sequence, record_id, title, abstract), gazetteer, progress = TRUE)
if (nrow(geo_mentions)) {
  geo <- assign_primary_country(geo_mentions)
} else {
  geo <- list(
    ranking = tibble(record_id=character(), country_name=character(), iso3c=character(), best_tier=integer()),
    assignments = tibble(),
    summary = tibble(record_id=character(), review_required=logical(), review_reason=character(), primary_countries=character(), primary_iso3c=character()),
    review_queue = tibble()
  )
}
write_csv(geo_mentions, path(output_dir, "geography_mentions.csv"), na = "")
write_csv(geo$ranking, path(output_dir, "geography_ranking.csv"), na = "")
write_csv(geo$assignments, path(output_dir, "geography_assignments.csv"), na = "")
write_csv(geo$summary, path(output_dir, "geography_summary.csv"), na = "")
write_csv(geo$review_queue, path(output_dir, "geography_review_queue.csv"), na = "")

species_review <- species$species_assignments |> filter(review_required %in% TRUE)
message("Workflow 05A: constructing residual adjudication queue.")
queue <- build_annotation_adjudication_queue(
  records |> select(record_sequence, record_id, title, abstract),
  species_review, geo$summary, geo$ranking
)
write_csv(queue, path(output_dir, "annotation_adjudication_queue.csv"), na = "")

sp_summary <- species$species_assignments |>
  mutate(record_id = as.character(record_id)) |>
  group_by(record_id) |>
  summarise(
    deterministic_species = paste(sort(unique(stats::na.omit(farmed_species))), collapse = "; "),
    deterministic_species_ids = paste(sort(unique(stats::na.omit(farmed_species_id))), collapse = "; "),
    species_review_required = any(review_required %in% TRUE),
    species_assignment_reason = paste(sort(unique(stats::na.omit(assignment_reason))), collapse = " | "),
    non_target_species = paste(sort(unique(stats::na.omit(non_target_species))), collapse = "; "),
    .groups = "drop"
  )

geo_summary <- records |> select(record_id) |>
  left_join(
    geo$summary |>
      transmute(
        record_id = as.character(record_id),
        deterministic_primary_countries = dplyr::coalesce(as.character(primary_countries), ""),
        deterministic_primary_iso3c = dplyr::coalesce(as.character(primary_iso3c), ""),
        geography_review_required = review_required %in% TRUE,
        geography_review_reason = dplyr::coalesce(as.character(review_reason), "")
      ),
    by = "record_id"
  ) |>
  mutate(
    deterministic_primary_countries = coalesce(deterministic_primary_countries, ""),
    deterministic_primary_iso3c = coalesce(deterministic_primary_iso3c, ""),
    geography_review_required = coalesce(geography_review_required, FALSE),
    geography_review_reason = coalesce(geography_review_reason, "")
  )

deterministic <- records |>
  select(record_sequence, canonical_index, record_id) |>
  left_join(sp_summary, by = "record_id") |>
  left_join(geo_summary, by = "record_id") |>
  mutate(
    species_review_required = coalesce(species_review_required, FALSE),
    geography_review_required = coalesce(geography_review_required, FALSE)
  )
write_csv(deterministic, path(output_dir, "deterministic_annotation_summary.csv"), na = "")

summary <- list(
  workflow = "workflow_05_species_geography",
  stage = "deterministic",
  stable_identity = "canonical record_id",
  records_forwarded_from_workflow04 = nrow(records),
  species_mentions = nrow(species$species_mentions),
  species_assignment_rows = nrow(species$species_assignments),
  species_review_records = length(unique(species_review$record_id)),
  geography_mentions = nrow(geo_mentions),
  geography_review_records = if (nrow(geo$summary)) sum(geo$summary$review_required %in% TRUE) else 0L,
  annotation_adjudication_queue_records = nrow(queue),
  llm_calls = 0L,
  method_source = "exact established species/geography R modules and dictionaries from main"
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), path(output_dir, "workflow05_deterministic_summary.json"))
message(sprintf("Workflow 05A complete: %d records; %d residual records require adjudication.", nrow(records), nrow(queue)))
