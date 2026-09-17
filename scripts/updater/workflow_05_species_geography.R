#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(fs)
  library(here)
  library(httr2)
  library(jsonlite)
  library(purrr)
  library(readr)
  library(stringr)
  library(tibble)
})

# Workflow 05: species + primary study geography annotation.
#
# Design principles:
#   * standalone and updater-safe: all paths are supplied at runtime;
#   * reuse trustworthy non-blank annotations from the production master;
#   * deterministic annotation is used for dimensions not recoverable from master;
#   * LLM adjudication is never repeated for a dimension recovered from master;
#   * in llm-mode=new-only, API calls are limited to unresolved dimensions for
#     records without reusable master annotation;
#   * llm-mode=off performs no API calls and emits a human-review queue instead;
#   * provenance is explicit for every final dimension.

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
master_path <- arg("--master", "data/master/current/living_evidence_map_master.csv")
output_dir <- arg("--output-dir", "outputs/workflow05")
llm_mode <- arg("--llm-mode", "new-only")
model <- arg("--model", Sys.getenv("OPENAI_ANNOTATION_MODEL", "gpt-5-mini"))
max_llm_records <- as.integer(arg("--max-llm-records", "0"))

if (is.null(input_path)) stop("--input is required", call. = FALSE)
if (!file.exists(input_path)) stop("Input does not exist: ", input_path, call. = FALSE)
if (!file.exists(master_path)) stop("Master does not exist: ", master_path, call. = FALSE)
if (!llm_mode %in% c("off", "new-only")) stop("--llm-mode must be off or new-only", call. = FALSE)
if (is.na(max_llm_records) || max_llm_records < 0L) stop("--max-llm-records must be >= 0", call. = FALSE)
if (llm_mode == "new-only" && !nzchar(Sys.getenv("OPENAI_API_KEY"))) {
  stop("OPENAI_API_KEY is required when --llm-mode=new-only", call. = FALSE)
}

dir_create(output_dir, recurse = TRUE)
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
clean <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}
first_col <- function(df, candidates) {
  hit <- candidates[candidates %in% names(df)]
  if (!length(hit)) return(rep("", nrow(df)))
  out <- rep("", nrow(df))
  for (nm in hit) {
    x <- clean(df[[nm]])
    take <- !nzchar(out) & nzchar(x)
    out[take] <- x[take]
  }
  out
}
normalise_doi <- function(x) {
  x <- tolower(clean(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:\\s*", "", x)
  x
}
normalise_title <- function(x) {
  x <- tolower(clean(x))
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- gsub("[^[:alnum:]]+", " ", x)
  stringr::str_squish(x)
}

message("Workflow 05: reading input and production master.")
records_raw <- read_csv(input_path, show_col_types = FALSE, progress = FALSE)
master_raw <- read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!nrow(records_raw)) stop("Input contains no records", call. = FALSE)

# Normalise only the fields required by the existing annotation modules while
# preserving every original input column in the final output.
records <- records_raw
records$record_id <- first_col(records, c("record_id", "lens_id", "Lens ID", "LensID", "doi", "DOI"))
records$title <- first_col(records, c("title", "Title", "document_title", "Document Title"))
records$abstract <- first_col(records, c("abstract", "Abstract"))
if (!"record_sequence" %in% names(records)) records$record_sequence <- seq_len(nrow(records))
records$record_sequence <- as.integer(records$record_sequence)
if (any(!nzchar(records$record_id))) stop("Every input record must have record_id/lens_id/DOI", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("Input record_id values must be unique", call. = FALSE)

records$.lens_key <- tolower(first_col(records, c("lens_id", "Lens ID", "LensID", "record_id")))
records$.doi_key <- normalise_doi(first_col(records, c("doi", "DOI", "doi_id")))
records$.title_key <- normalise_title(records$title)

master <- master_raw
master$.master_row <- seq_len(nrow(master))
master$.lens_key <- tolower(first_col(master, c("lens_id", "Lens ID", "LensID", "record_id")))
master$.doi_key <- normalise_doi(first_col(master, c("doi", "DOI", "doi_id")))
master$.title_key <- normalise_title(first_col(master, c("title", "Title", "document_title", "Document Title")))

# These are deliberately conservative, final/production-oriented aliases.
# Blank values are not treated as evidence of an explicit NONE decision.
master$.species_value <- first_col(master, c(
  "final_species", "species_final", "final_farmed_species",
  "adjudicated_species", "llm_species", "deterministic_species"
))
master$.geo_iso3c <- first_col(master, c(
  "final_primary_country_iso3c", "primary_country_iso3c_final",
  "adjudicated_primary_country_iso3c", "llm_primary_country_iso3c",
  "deterministic_primary_iso3c", "primary_iso3c"
))
master$.geo_country <- first_col(master, c(
  "final_primary_country", "final_primary_countries", "primary_country_final",
  "deterministic_primary_countries", "primary_countries"
))

# Unique-match indexes. Ambiguous keys are intentionally ignored rather than
# risking transfer of annotation from the wrong publication.
unique_index <- function(values) {
  ok <- nzchar(values)
  tab <- table(values[ok])
  unique_values <- names(tab)[tab == 1L]
  idx <- which(ok & values %in% unique_values)
  setNames(idx, values[idx])
}
lens_index <- unique_index(master$.lens_key)
doi_index <- unique_index(master$.doi_key)
title_index <- unique_index(master$.title_key)

match_master_row <- function(i) {
  k <- records$.lens_key[[i]]
  if (nzchar(k) && k %in% names(lens_index)) return(unname(lens_index[[k]]))
  k <- records$.doi_key[[i]]
  if (nzchar(k) && k %in% names(doi_index)) return(unname(doi_index[[k]]))
  k <- records$.title_key[[i]]
  if (nzchar(k) && k %in% names(title_index)) return(unname(title_index[[k]]))
  NA_integer_
}
master_match <- vapply(seq_len(nrow(records)), match_master_row, integer(1))

reuse <- tibble(
  record_id = records$record_id,
  master_match_row = master_match,
  master_species = ifelse(is.na(master_match), "", master$.species_value[master_match]),
  master_primary_country_iso3c = ifelse(is.na(master_match), "", master$.geo_iso3c[master_match]),
  master_primary_countries = ifelse(is.na(master_match), "", master$.geo_country[master_match])
) |>
  mutate(
    master_species = clean(master_species),
    master_primary_country_iso3c = clean(master_primary_country_iso3c),
    master_primary_countries = clean(master_primary_countries),
    species_reused = nzchar(master_species),
    geography_reused = nzchar(master_primary_country_iso3c),
    master_match = !is.na(master_match_row)
  )

write_csv(reuse, path(output_dir, "master_annotation_reuse.csv"), na = "")
message(sprintf(
  "Workflow 05: master matches=%d/%d; species reused=%d; geography reused=%d.",
  sum(reuse$master_match), nrow(records), sum(reuse$species_reused), sum(reuse$geography_reused)
))

species_needed_ids <- reuse$record_id[!reuse$species_reused]
geo_needed_ids <- reuse$record_id[!reuse$geography_reused]

species_records <- records |> filter(record_id %in% species_needed_ids) |>
  select(record_sequence, record_id, title, abstract)
geo_records <- records |> filter(record_id %in% geo_needed_ids) |>
  select(record_sequence, record_id, title, abstract)

species_dictionary <- read_csv(here("config", "species_dictionary.csv"), show_col_types = FALSE, progress = FALSE)
gazetteer <- read_csv(here("config", "global_country_gazetteer_v3.csv"), show_col_types = FALSE, progress = FALSE)

message(sprintf("Workflow 05: deterministic species annotation required for %d records.", nrow(species_records)))
if (nrow(species_records)) {
  species <- annotate_species(species_records, species_dictionary, progress = TRUE)
} else {
  species <- list(species_mentions = tibble(), species_assignments = tibble(), failures = tibble())
}
write_csv(species$species_mentions, path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, path(output_dir, "species_annotation_failures.csv"), na = "")
if (nrow(species$failures)) stop("Deterministic species annotation produced failures", call. = FALSE)

message(sprintf("Workflow 05: deterministic geography annotation required for %d records.", nrow(geo_records)))
if (nrow(geo_records)) {
  geo_mentions <- detect_geography_mentions(geo_records, gazetteer, progress = TRUE)
  if (nrow(geo_mentions)) {
    geo <- assign_primary_country(geo_mentions)
  } else {
    geo <- list(ranking = tibble(), assignments = tibble(), summary = tibble(), review_queue = tibble())
  }
} else {
  geo_mentions <- tibble()
  geo <- list(ranking = tibble(), assignments = tibble(), summary = tibble(), review_queue = tibble())
}
write_csv(geo_mentions, path(output_dir, "geography_mentions.csv"), na = "")
write_csv(geo$ranking, path(output_dir, "geography_ranking.csv"), na = "")
write_csv(geo$assignments, path(output_dir, "geography_assignments.csv"), na = "")
write_csv(geo$summary, path(output_dir, "geography_summary.csv"), na = "")
write_csv(geo$review_queue, path(output_dir, "geography_review_queue.csv"), na = "")

# Collapse deterministic species assignments and retain their review flag.
if (nrow(species$species_assignments)) {
  species_summary <- species$species_assignments |>
    group_by(record_id) |>
    summarise(
      deterministic_species = paste(sort(unique(stats::na.omit(farmed_species[nzchar(clean(farmed_species))]))), collapse = "; "),
      deterministic_species_ids = paste(sort(unique(stats::na.omit(farmed_species_id[nzchar(clean(farmed_species_id))]))), collapse = "; "),
      species_review_required = any(review_required %in% TRUE),
      species_reasons = paste(sort(unique(stats::na.omit(assignment_reason))), collapse = " | "),
      non_target_species = paste(sort(unique(stats::na.omit(non_target_species[nzchar(clean(non_target_species))]))), collapse = "; "),
      .groups = "drop"
    )
} else {
  species_summary <- tibble(record_id = character(), deterministic_species = character(), deterministic_species_ids = character(), species_review_required = logical(), species_reasons = character(), non_target_species = character())
}

if (nrow(geo$summary)) {
  geo_summary <- geo$summary |>
    transmute(
      record_id = as.character(record_id),
      deterministic_primary_countries = clean(primary_countries),
      deterministic_primary_iso3c = clean(primary_iso3c),
      geography_review_required = review_required %in% TRUE,
      geography_review_reason = clean(review_reason)
    )
} else {
  geo_summary <- tibble(record_id = character(), deterministic_primary_countries = character(), deterministic_primary_iso3c = character(), geography_review_required = logical(), geography_review_reason = character())
}

state <- reuse |>
  left_join(species_summary, by = "record_id") |>
  left_join(geo_summary, by = "record_id") |>
  mutate(
    species_review_required = coalesce(species_review_required, FALSE) & !species_reused,
    geography_review_required = coalesce(geography_review_required, FALSE) & !geography_reused,
    deterministic_species = coalesce(deterministic_species, ""),
    deterministic_species_ids = coalesce(deterministic_species_ids, ""),
    deterministic_primary_countries = coalesce(deterministic_primary_countries, ""),
    deterministic_primary_iso3c = coalesce(deterministic_primary_iso3c, "")
  )

# Build only the genuinely unresolved queue. This avoids the historical bug of
# sending every deterministic species assignment to adjudication.
queue_records <- records |>
  select(record_sequence, record_id, title, abstract) |>
  inner_join(state |> filter(species_review_required | geography_review_required), by = "record_id")

# Geography candidates are useful to the adjudicator.
if (nrow(geo$ranking)) {
  geo_candidates <- geo$ranking |>
    group_by(record_id) |>
    summarise(
      geography_candidates = paste(unique(paste0(country_name, " [", iso3c, "]; tier ", best_tier)), collapse = "; "),
      .groups = "drop"
    )
  queue_records <- queue_records |> left_join(geo_candidates, by = "record_id")
} else {
  queue_records$geography_candidates <- ""
}
queue_records$geography_candidates <- coalesce(queue_records$geography_candidates, "")

write_csv(queue_records, path(output_dir, "annotation_adjudication_queue.csv"), na = "")
message(sprintf("Workflow 05: %d records require adjudication after master reuse + deterministic annotation.", nrow(queue_records)))

openai_annotation_model <- function(system_prompt, user_prompt, schema,
                                     api_key = Sys.getenv("OPENAI_API_KEY"), model_name = model) {
  body <- list(
    model = model_name, store = FALSE, reasoning = list(effort = "low"),
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(verbosity = "low", format = list(
      type = "json_schema", name = "salmon_annotation_adjudication", strict = TRUE,
      schema = annotation_adjudication_schema()
    ))
  )
  httr2::request("https://api.openai.com/v1/responses") |>
    httr2::req_auth_bearer_token(api_key) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 4, backoff = ~ 2^.x) |>
    httr2::req_perform() |>
    httr2::resp_body_json() |>
    extract_openai_output_text() |>
    jsonlite::fromJSON(simplifyVector = TRUE)
}

if (llm_mode == "new-only" && nrow(queue_records)) {
  if (max_llm_records > 0L && nrow(queue_records) > max_llm_records) {
    stop(sprintf("Adjudication queue has %d records, exceeding --max-llm-records=%d; refusing API calls.", nrow(queue_records), max_llm_records), call. = FALSE)
  }
  adjudication <- adjudicate_annotation_queue(queue_records, openai_annotation_model, progress = TRUE)
} else {
  adjudication <- tibble()
}
write_csv(adjudication, path(output_dir, "annotation_adjudication.csv"), na = "")

state_final <- state
if (nrow(adjudication)) state_final <- state_final |> left_join(adjudication, by = "record_id")
for (nm in c("species_decision", "llm_species", "species_reason", "geography_decision", "llm_primary_country_iso3c", "geography_reason", "llm_failed", "llm_error")) {
  if (!nm %in% names(state_final)) state_final[[nm]] <- if (nm == "llm_failed") FALSE else ""
}
state_final$species_decision <- clean(state_final$species_decision)
state_final$llm_species <- clean(state_final$llm_species)
state_final$geography_decision <- clean(state_final$geography_decision)
state_final$llm_primary_country_iso3c <- clean(state_final$llm_primary_country_iso3c)
state_final$llm_failed <- coalesce(as.logical(state_final$llm_failed), FALSE)

state_final <- state_final |>
  mutate(
    final_species = case_when(
      species_reused ~ master_species,
      species_review_required & species_decision %in% c("ACCEPT", "CHANGE") & nzchar(llm_species) ~ llm_species,
      !species_review_required & nzchar(deterministic_species) ~ deterministic_species,
      TRUE ~ ""
    ),
    species_annotation_provenance = case_when(
      species_reused ~ "historical_master",
      species_review_required & species_decision %in% c("ACCEPT", "CHANGE") & nzchar(llm_species) ~ "workflow05_llm_new_only",
      !species_review_required & nzchar(deterministic_species) ~ "workflow05_deterministic",
      TRUE ~ "workflow05_unresolved"
    ),
    final_primary_country_iso3c = case_when(
      geography_reused ~ master_primary_country_iso3c,
      geography_review_required & geography_decision %in% c("ACCEPT", "CHANGE") & nzchar(llm_primary_country_iso3c) ~ llm_primary_country_iso3c,
      !geography_review_required & nzchar(deterministic_primary_iso3c) ~ deterministic_primary_iso3c,
      TRUE ~ ""
    ),
    final_primary_countries = case_when(
      geography_reused ~ master_primary_countries,
      !geography_review_required & nzchar(deterministic_primary_countries) ~ deterministic_primary_countries,
      TRUE ~ ""
    ),
    geography_annotation_provenance = case_when(
      geography_reused ~ "historical_master",
      geography_review_required & geography_decision %in% c("ACCEPT", "CHANGE") & nzchar(llm_primary_country_iso3c) ~ "workflow05_llm_new_only",
      !geography_review_required & nzchar(deterministic_primary_iso3c) ~ "workflow05_deterministic",
      TRUE ~ "workflow05_unresolved"
    ),
    workflow05_review_required = species_annotation_provenance == "workflow05_unresolved" |
      geography_annotation_provenance == "workflow05_unresolved" |
      llm_failed
  )

final <- records_raw |>
  mutate(record_id = records$record_id) |>
  left_join(
    state_final |>
      select(record_id, final_species, final_primary_countries, final_primary_country_iso3c,
             species_annotation_provenance, geography_annotation_provenance,
             deterministic_species, deterministic_species_ids,
             deterministic_primary_countries, deterministic_primary_iso3c,
             species_review_required, geography_review_required,
             species_decision, llm_species, species_reason,
             geography_decision, llm_primary_country_iso3c, geography_reason,
             llm_failed, llm_error, workflow05_review_required),
    by = "record_id"
  )

write_csv(final, path(output_dir, "records_after_species_geography_adjudication.csv"), na = "")
review <- final |> filter(workflow05_review_required %in% TRUE)
write_csv(review, path(output_dir, "workflow05_human_review_queue.csv"), na = "")

summary <- list(
  workflow = "05_species_geography_annotation",
  completed_at = now_utc(),
  input = input_path,
  master = master_path,
  output_dir = output_dir,
  llm_mode = llm_mode,
  model = if (llm_mode == "new-only") model else NA_character_,
  records = nrow(final),
  master_matches = sum(reuse$master_match),
  species_reused_from_master = sum(reuse$species_reused),
  geography_reused_from_master = sum(reuse$geography_reused),
  species_deterministic_records = nrow(species_records),
  geography_deterministic_records = nrow(geo_records),
  adjudication_queue_records = nrow(queue_records),
  llm_calls_attempted = if (llm_mode == "new-only") nrow(queue_records) else 0L,
  llm_failures = if (nrow(adjudication)) sum(adjudication$llm_failed %in% TRUE) else 0L,
  human_review_records = nrow(review),
  complete = nrow(review) == 0L
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, na = "null"), path(output_dir, "workflow05_summary.json"))

message(sprintf(
  "Workflow 05 complete: %d records; master species=%d; master geography=%d; LLM queue=%d; human review=%d.",
  nrow(final), sum(reuse$species_reused), sum(reuse$geography_reused), nrow(queue_records), nrow(review)
))
