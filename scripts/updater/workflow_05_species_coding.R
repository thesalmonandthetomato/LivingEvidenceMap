#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(digest)
  library(dplyr)
  library(jsonlite)
  library(readr)
  library(tibble)
})

source("R/species_detect.R")

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
dictionary_path <- arg("--dictionary", "config/species_dictionary.csv")
output_dir <- arg("--output-dir", "outputs/workflow05_species_coding")
expected_records <- as.integer(arg("--expected-records", "19407"))

if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input JSONL is required", call. = FALSE)
if (!file.exists(dictionary_path)) stop("Species dictionary is missing", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x
scalar <- function(x) {
  if (is.null(x) || !length(x)) return("")
  z <- as.character(x[[1L]])
  if (is.na(z)) "" else trimws(z)
}
read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) {
    tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE),
      error = function(e) stop(sprintf("Invalid JSONL line %d: %s", i, conditionMessage(e)), call. = FALSE))
  })
}
record_id_of <- function(r) scalar((r$identity %||% list())$record_id)
title_of <- function(r) scalar((r$canonical %||% list())$title)
abstract_of <- function(r) scalar((r$canonical %||% list())$abstract)

canonical <- read_jsonl(input_path)
if (!length(canonical)) stop("Input JSONL is empty", call. = FALSE)
if (!is.na(expected_records) && expected_records > 0L && length(canonical) != expected_records) {
  stop(sprintf("Expected %d W04-retained records, found %d", expected_records, length(canonical)), call. = FALSE)
}

records <- tibble(
  record_sequence = seq_along(canonical),
  record_id = vapply(canonical, record_id_of, character(1)),
  title = vapply(canonical, title_of, character(1)),
  abstract = vapply(canonical, abstract_of, character(1))
)
if (any(!nzchar(records$record_id))) stop("Every record requires a stable record_id", call. = FALSE)
if (anyDuplicated(records$record_id)) stop("record_id values must be unique", call. = FALSE)

dictionary <- read_csv(dictionary_path, show_col_types = FALSE, progress = FALSE)
eligible_ids <- c(
  "SAL_SALAR", "ONC_MYKISS", "ONC_TSHAWYTSCHA", "ONC_KISUTCH",
  "ONC_NERKA", "ONC_KETA", "ONC_GORBUSCHA", "ONC_MASOU", "UNSPEC_SALMON"
)
if (!all(dictionary$species_id %in% eligible_ids)) {
  stop("Dictionary contains a species code outside the approved W05 vocabulary", call. = FALSE)
}

message(sprintf("Workflow 05: deterministic title/abstract species coding for %d records.", nrow(records)))

mention_list <- vector("list", nrow(records))
for (i in seq_len(nrow(records))) {
  m <- detect_species_mentions(records$title[[i]], records$abstract[[i]], dictionary)
  if (nrow(m)) {
    m$record_sequence <- records$record_sequence[[i]]
    m$record_id <- records$record_id[[i]]
    mention_list[[i]] <- m
  }
  if (i == 1L || i %% 1000L == 0L || i == nrow(records)) {
    message(sprintf("Workflow 05: %d/%d records", i, nrow(records)))
  }
}
mentions <- bind_rows(mention_list)

# If any named eligible species is present, suppress the generic
# UNSPEC_SALMON coding for that record.
if (nrow(mentions)) {
  codes <- mentions |>
    distinct(record_id, species_id, preferred_name) |>
    group_by(record_id) |>
    group_modify(function(.x, .y) {
      if (any(.x$species_id != "UNSPEC_SALMON")) {
        .x <- .x |> filter(species_id != "UNSPEC_SALMON")
      }
      .x
    }) |>
    ungroup()
} else {
  codes <- tibble(record_id = character(), species_id = character(), preferred_name = character())
}

summary_by_record <- if (nrow(codes)) {
  codes |>
    group_by(record_id) |>
    summarise(
      farmed_species_codes = paste(sort(unique(species_id)), collapse = "; "),
      farmed_species = paste(sort(unique(preferred_name)), collapse = "; "),
      .groups = "drop"
    )
} else {
  tibble(record_id = character(), farmed_species_codes = character(), farmed_species = character())
}

handoff <- records |>
  left_join(summary_by_record, by = "record_id") |>
  mutate(
    farmed_species_codes = coalesce(farmed_species_codes, "NONE"),
    farmed_species = coalesce(farmed_species, "NONE")
  )

stopifnot(
  nrow(handoff) == nrow(records),
  !anyDuplicated(handoff$record_id),
  identical(as.character(handoff$record_id), as.character(records$record_id))
)

write_csv(records, file.path(output_dir, "records_for_annotation.csv"), na = "")
write_csv(mentions, file.path(output_dir, "species_matches.csv"), na = "")
write_csv(codes, file.path(output_dir, "species_codes_long.csv"), na = "")
write_csv(handoff, file.path(output_dir, "workflow05_species_coded.csv"), na = "")

counts <- handoff |>
  count(farmed_species_codes, farmed_species, name = "records", sort = TRUE)
write_csv(counts, file.path(output_dir, "species_record_counts.csv"), na = "")

manifest <- list(
  workflow = "workflow_05_species_coding",
  purpose = "deterministic species coding from title and abstract only",
  records = nrow(records),
  input_sha256 = digest(file = input_path, algo = "sha256", serialize = FALSE),
  dictionary_sha256 = digest(file = dictionary_path, algo = "sha256", serialize = FALSE),
  dictionary_rows = nrow(dictionary),
  species_matches = nrow(mentions),
  coded_records = sum(handoff$farmed_species_codes != "NONE"),
  none_records = sum(handoff$farmed_species_codes == "NONE"),
  rules = list(
    sources = c("title", "abstract"),
    deterministic_lexical_matching = TRUE,
    case_insensitive = TRUE,
    html_jats_markup_normalised = TRUE,
    whitespace_hyphen_variants_tolerated = TRUE,
    listed_misspellings_supported = TRUE,
    fuzzy_matching = FALSE,
    semantic_inference = FALSE,
    unspecified_suppressed_when_named_species_present = TRUE
  )
)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), file.path(output_dir, "workflow05_manifest.json"))
cat(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), "\n")
