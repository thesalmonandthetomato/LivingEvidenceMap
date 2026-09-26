#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(digest)
  library(dplyr)
  library(jsonlite)
  library(readr)
})

source("R/species_detect.R")
source("R/species_filter.R")
source("R/species_assign.R")
source("R/species_annotation.R")

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
dictionary_path <- arg("--dictionary", "config/species_dictionary.csv")
output_dir <- arg("--output-dir", "outputs/workflow05_deterministic")
expected_records <- suppressWarnings(as.integer(arg("--expected-records", "0")))

if (is.null(input_path) || !file.exists(input_path)) {
  stop("--input must point to an existing CSV file", call. = FALSE)
}
if (!file.exists(dictionary_path)) {
  stop("--dictionary must point to an existing species dictionary CSV", call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

records_in <- read_csv(input_path, show_col_types = FALSE, progress = FALSE)
dictionary <- read_csv(dictionary_path, show_col_types = FALSE, progress = FALSE)

required <- c("record_id", "title", "abstract")
missing <- setdiff(required, names(records_in))
if (length(missing)) {
  stop("Input CSV is missing required columns: ", paste(missing, collapse = ", "), call. = FALSE)
}
if (!nrow(records_in)) stop("Input CSV contains zero records", call. = FALSE)
if (!is.na(expected_records) && expected_records > 0L && nrow(records_in) != expected_records) {
  stop(sprintf("Expected %d records, found %d", expected_records, nrow(records_in)), call. = FALSE)
}

records_in$record_id <- as.character(records_in$record_id)
if (any(is.na(records_in$record_id) | !nzchar(trimws(records_in$record_id)))) {
  stop("Every input record must have a non-empty record_id", call. = FALSE)
}
if (anyDuplicated(records_in$record_id)) {
  stop("Input record_id values must be unique", call. = FALSE)
}

if ("record_sequence" %in% names(records_in)) {
  if (any(is.na(records_in$record_sequence)) || anyDuplicated(records_in$record_sequence)) {
    stop("Existing record_sequence values must be complete and unique", call. = FALSE)
  }
  work_sequence <- records_in$record_sequence
} else {
  work_sequence <- seq_len(nrow(records_in))
  records_in$record_sequence <- work_sequence
}

records <- tibble(
  record_sequence = work_sequence,
  record_id = records_in$record_id,
  title = as.character(records_in$title),
  abstract = as.character(records_in$abstract)
)

message(sprintf("Workflow 05: accepted %d CSV records for deterministic species annotation.", nrow(records)))
species <- annotate_species(records, dictionary, progress = TRUE)

write_csv(species$species_mentions, file.path(output_dir, "species_mentions.csv"), na = "")
write_csv(species$species_assignments, file.path(output_dir, "species_assignments.csv"), na = "")
write_csv(species$failures, file.path(output_dir, "species_annotation_failures.csv"), na = "")

if (nrow(species$failures)) {
  stop(sprintf("Deterministic species annotation had %d technical failures", nrow(species$failures)), call. = FALSE)
}

assignment_summary <- species$species_assignments |>
  mutate(record_id = as.character(record_id)) |>
  group_by(record_id) |>
  summarise(
    deterministic_species_ids = paste(sort(unique(stats::na.omit(farmed_species_id))), collapse = "; "),
    deterministic_species = paste(sort(unique(stats::na.omit(farmed_species))), collapse = "; "),
    species_assignment_role = paste(sort(unique(stats::na.omit(assignment_role))), collapse = "; "),
    species_review_required = any(review_required %in% TRUE),
    species_assignment_reason = paste(sort(unique(stats::na.omit(assignment_reason))), collapse = " | "),
    non_target_species = paste(sort(unique(stats::na.omit(non_target_species))), collapse = "; "),
    .groups = "drop"
  )

annotation_fields <- c(
  "deterministic_species_ids",
  "deterministic_species",
  "species_assignment_role",
  "species_review_required",
  "species_assignment_reason",
  "non_target_species"
)

base_records <- records_in[, setdiff(names(records_in), annotation_fields), drop = FALSE]

handoff <- base_records |>
  left_join(assignment_summary, by = "record_id") |>
  mutate(
    deterministic_species_ids = if_else(
      is.na(deterministic_species_ids) | !nzchar(trimws(deterministic_species_ids)),
      "NONE",
      deterministic_species_ids
    ),
    deterministic_species = if_else(
      is.na(deterministic_species) | !nzchar(trimws(deterministic_species)),
      "NONE",
      deterministic_species
    ),
    species_assignment_role = if_else(
      is.na(species_assignment_role) | !nzchar(trimws(species_assignment_role)),
      "none",
      species_assignment_role
    ),
    species_review_required = coalesce(species_review_required, FALSE),
    species_assignment_reason = if_else(
      is.na(species_assignment_reason) | !nzchar(trimws(species_assignment_reason)),
      "No eligible species term detected",
      species_assignment_reason
    ),
    non_target_species = coalesce(non_target_species, "")
  )

if (nrow(handoff) != nrow(records_in)) stop("Workflow 05 changed record cardinality", call. = FALSE)
if (!identical(as.character(handoff$record_id), as.character(records_in$record_id))) {
  stop("Workflow 05 changed record order or record_id values", call. = FALSE)
}
if (any(is.na(handoff$species_review_required))) stop("species_review_required contains NA", call. = FALSE)

write_csv(handoff, file.path(output_dir, "workflow05_annotated.csv"), na = "")

input_sha256 <- digest(file = input_path, algo = "sha256")
dictionary_sha256 <- digest(file = dictionary_path, algo = "sha256")
module_paths <- c(
  "R/species_detect.R",
  "R/species_filter.R",
  "R/species_assign.R",
  "R/species_annotation.R"
)
module_sha256 <- stats::setNames(
  vapply(module_paths, function(p) digest(file = p, algo = "sha256"), character(1)),
  module_paths
)

manifest <- list(
  workflow = "workflow_05_deterministic_annotation",
  stage = "deterministic_species_annotation",
  input = list(
    csv = input_path,
    sha256 = input_sha256,
    records = nrow(records_in),
    required_columns = required
  ),
  output = list(
    handoff_csv = "workflow05_annotated.csv",
    records = nrow(handoff),
    record_order_preserved = TRUE
  ),
  species_dictionary = list(
    path = dictionary_path,
    sha256 = dictionary_sha256,
    rows = nrow(dictionary)
  ),
  deterministic_modules_sha256 = as.list(module_sha256),
  semantics = list(
    no_eligible_species = "NONE",
    no_eligible_species_is_uncertain = FALSE,
    llm_calls = 0L,
    geography_coding = FALSE
  ),
  counts = list(
    records_with_named_or_generic_species = sum(handoff$deterministic_species_ids != "NONE"),
    records_with_no_eligible_species = sum(handoff$deterministic_species_ids == "NONE"),
    records_requiring_species_review = sum(handoff$species_review_required %in% TRUE),
    species_mentions = nrow(species$species_mentions),
    species_assignment_rows = nrow(species$species_assignments)
  )
)

writeLines(
  toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null"),
  file.path(output_dir, "workflow05_manifest.json")
)

cat(toJSON(manifest$counts, auto_unbox = TRUE, pretty = TRUE), "\n")
