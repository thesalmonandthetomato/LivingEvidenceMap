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
#
# Direct canonical-JSON adaptation of scripts/annotate_lens_update.R on main.
# The annotation method is unchanged. This stage makes NO LLM/API calls.

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
if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input canonical JSONL is required", call. = FALSE)
dir_create(output_dir, recurse = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x
clean <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}
textify <- function(x) {
  if (is.null(x)) return("")
  if (is.atomic(x)) {
    z <- clean(x)
    return(paste(z[nzchar(z)], collapse = "; "))
  }
  if (is.list(x)) return(paste(Filter(nzchar, vapply(x, textify, character(1))), collapse = "; "))
  ""
}
first_nonempty <- function(...) {
  for (x in list(...)) {
    z <- textify(x)
    if (nzchar(z)) return(z)
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

lens_id_of <- function(r) first_nonempty((r$identity %||% list())$lens_id,
  (r$canonical %||% list())$lens_id, (r$lens %||% list())$lens_id)
title_of <- function(r) first_nonempty((r$canonical %||% list())$title,
  ((r$lens %||% list())$raw_payload %||% list())$title)
abstract_of <- function(r) first_nonempty((r$canonical %||% list())$abstract,
  ((r$lens %||% list())$raw_payload %||% list())$abstract)
publication_ok <- function(r) {
  n <- r$notices
  if (is.null(n)) return(TRUE)
  isTRUE(n$record_downstream_eligible %||% n$downstream_eligible %||% TRUE)
}
dedup_ok <- function(r) {
  status <- tolower(first_nonempty((r$deduplication %||% list())$status))
  status %in% c("unique", "canonical")
}
screen_decision <- function(r) tolower(first_nonempty((r$screening %||% list())$decision))

message("Workflow 05A: loading canonical Workflow 04 JSONL.")
canonical_records <- read_jsonl(input_path)
if (!length(canonical_records)) stop("Canonical JSONL is empty", call. = FALSE)

eligible_idx <- which(vapply(canonical_records, function(r) {
  dedup_ok(r) && publication_ok(r) && screen_decision(r) %in% c("include", "uncertain")
}, logical(1)))

records <- tibble(
  record_sequence = seq_along(eligible_idx),
  canonical_index = eligible_idx,
  record_id = vapply(canonical_records[eligible_idx], lens_id_of, character(1)),
  title = vapply(canonical_records[eligible_idx], title_of, character(1)),
  abstract = vapply(canonical_records[eligible_idx], abstract_of, character(1)),
  screening_decision = vapply(canonical_records[eligible_idx], screen_decision, character(1))
)
if (any(!nzchar(records$record_id))) stop("Every Workflow 04-forwarded record must have a Lens ID", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("Workflow 04-forwarded Lens IDs are not unique", call. = FALSE)
write_csv(records, path(output_dir, "records_for_annotation.csv"), na = "")
message(sprintf("Workflow 05A: %d records forwarded from Workflow 04.", nrow(records)))

species_dictionary <- read_csv(here("config", "species_dictionary.csv"), show_col_types = FALSE, progress = FALSE)
gazetteer <- read_csv(here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE, progress = FALSE)

# Identical deterministic species call to scripts/annotate_lens_update.R.
message("Workflow 05A: starting deterministic species annotation.")
species <- annotate_species(
  records |> select(record_sequence, record_id, title, abstract),
  species_dictionary,
  progress = TRUE
)
write_csv(species$species_mentions, path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, path(output_dir, "species_annotation_failures.csv"), na = "")
if (nrow(species$failures)) stop(sprintf("Deterministic species annotation had %d technical failures", nrow(species$failures)), call. = FALSE)

# Identical deterministic geography calls to scripts/annotate_lens_update.R.
message("Workflow 05A: starting deterministic geography detection.")
geo_mentions <- detect_geography_mentions(
  records |> select(record_sequence, record_id, title, abstract),
  gazetteer,
  progress = TRUE
)
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

# The LLM must see ONLY deterministic uncertainty. The production species
# assigner marks those rows with review_required=TRUE; geography uncertainty
# is filtered inside build_annotation_adjudication_queue().
species_review <- species$species_assignments |>
  filter(review_required %in% TRUE)

message("Workflow 05A: constructing residual adjudication queue.")
queue <- build_annotation_adjudication_queue(
  records |> select(record_sequence, record_id, title, abstract),
  species_review,
  geo$summary,
  geo$ranking
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
  select(record_sequence, canonical_index, record_id, screening_decision) |>
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
  canonical_records = length(canonical_records),
  records_forwarded_from_workflow04 = nrow(records),
  species_mentions = nrow(species$species_mentions),
  species_assignment_rows = nrow(species$species_assignments),
  species_review_records = length(unique(species_review$record_id)),
  geography_mentions = nrow(geo_mentions),
  geography_review_records = if (nrow(geo$summary)) sum(geo$summary$review_required %in% TRUE) else 0L,
  annotation_adjudication_queue_records = nrow(queue),
  llm_calls = 0L,
  method_source = "scripts/annotate_lens_update.R on main"
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), path(output_dir, "workflow05_deterministic_summary.json"))
message(sprintf("Workflow 05A complete: %d records; %d residual records require LLM adjudication.", nrow(records), nrow(queue)))
