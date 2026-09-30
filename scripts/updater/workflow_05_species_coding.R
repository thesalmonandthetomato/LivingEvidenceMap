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
config_path <- arg("--config", "user_input/workflow05_coding_config.json")
dictionary_path <- arg("--dictionary")
output_dir <- arg("--output-dir", "outputs/workflow05_species_coding")
expected_records <- as.integer(arg("--expected-records", "0"))

if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input JSONL is required", call. = FALSE)
if (!file.exists(config_path)) stop("Workflow 05 coding config is missing", call. = FALSE)
coding_config <- fromJSON(config_path, simplifyVector = FALSE)
cfg_scalar <- function(x) {
  if (is.null(x) || !length(x)) return("")
  y <- as.character(x[[1L]])
  if (is.na(y)) "" else trimws(y)
}
if (is.null(dictionary_path) || !nzchar(trimws(dictionary_path))) dictionary_path <- cfg_scalar(coding_config$dictionary_path)
if (!nzchar(dictionary_path) || !file.exists(dictionary_path)) stop("Deterministic concepts CSV is missing", call. = FALSE)

entity_value <- cfg_scalar(coding_config$entity_value)
generic_code <- cfg_scalar(coding_config$generic_code)
none_code <- cfg_scalar(coding_config$none_code)
default_group <- cfg_scalar(coding_config$default_group)
is_candidate <- isTRUE(coding_config$is_candidate)
code_map <- unlist(coding_config$code_map, use.names = TRUE)
scientific_genera <- tolower(trimws(unlist(coding_config$scientific_genera, use.names = FALSE)))
pluralisable_common_head_terms <- tolower(trimws(unlist(coding_config$pluralisable_common_head_terms, use.names = FALSE)))

if (!nzchar(entity_value)) stop("Workflow 05 config lacks entity_value", call. = FALSE)
if (!nzchar(generic_code)) stop("Workflow 05 config lacks generic_code", call. = FALSE)
if (!nzchar(none_code)) stop("Workflow 05 config lacks none_code", call. = FALSE)
if (!length(code_map) || any(!nzchar(names(code_map))) || any(!nzchar(as.character(code_map)))) stop("Workflow 05 config has invalid code_map", call. = FALSE)
if (!generic_code %in% unname(code_map)) stop("Workflow 05 generic_code is absent from code_map", call. = FALSE)
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
if (is.na(expected_records) || expected_records < 0L) stop("--expected-records must be >= 0", call. = FALSE)
if (expected_records > 0L && length(canonical) != expected_records) {
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

concepts <- read_csv(dictionary_path, show_col_types = FALSE, progress = FALSE)
if (!identical(names(concepts), c("coding","entity","terms"))) {
  stop("W05 concepts CSV must contain exactly: coding, entity, terms", call. = FALSE)
}
if (!nrow(concepts)) stop("W05 concepts CSV contains zero rows", call. = FALSE)
if (any(!nzchar(trimws(concepts$coding))) || any(!nzchar(trimws(concepts$entity))) || any(!nzchar(trimws(concepts$terms)))) {
  stop("Every W05 concept row requires non-empty coding, entity and terms", call. = FALSE)
}
if (any(concepts$entity != entity_value)) {
  stop(sprintf("W05 concepts must use entity = '%s'", entity_value), call. = FALSE)
}

if (!all(concepts$coding %in% names(code_map))) {
  stop("Concept CSV contains a coding absent from Workflow 05 code_map", call. = FALSE)
}

infer_synonym_type <- function(coding, term) {
  term <- trimws(term)
  if (identical(unname(code_map[[coding]]), generic_code)) return("generic")
  if (grepl("^[[:alpha:]]\\.[[:space:]]+[[:alpha:]-]+$", term, perl = TRUE)) return("abbreviation")

  first <- tolower(strsplit(term, "[[:space:]]+", perl = TRUE)[[1L]][1L])
  if (first %in% scientific_genera) return("scientific")
  "common"
}

expanded <- lapply(seq_len(nrow(concepts)), function(i) {
  terms <- trimws(strsplit(concepts$terms[[i]], ";", fixed = TRUE)[[1L]])
  terms <- unique(terms[nzchar(terms)])
  coding <- concepts$coding[[i]]
  tibble(
    species_id = unname(code_map[[coding]]),
    preferred_name = coding,
    scientific_name = "",
    synonym = terms,
    synonym_type = vapply(terms, function(term) infer_synonym_type(coding, term), character(1)),
    is_farmed_candidate = is_candidate,
    default_group = default_group,
    notes = ""
  )
})
dictionary <- bind_rows(expanded)

message(sprintf("Workflow 05: deterministic title/abstract species coding for %d records.", nrow(records)))

mention_list <- vector("list", nrow(records))
for (i in seq_len(nrow(records))) {
  m <- detect_species_mentions(records$title[[i]], records$abstract[[i]], dictionary, generic_species_id = generic_code, pluralisable_common_head_terms = pluralisable_common_head_terms)
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
      if (any(.x$species_id != generic_code)) {
        .x <- .x |> filter(species_id != generic_code)
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
    farmed_species_codes = coalesce(farmed_species_codes, none_code),
    farmed_species = coalesce(farmed_species, none_code)
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
  dictionary_rows = nrow(concepts),
  expanded_terms = nrow(dictionary),
  species_matches = nrow(mentions),
  coded_records = sum(handoff$farmed_species_codes != none_code),
  none_records = sum(handoff$farmed_species_codes == none_code),
  coding_config_sha256 = digest(file = config_path, algo = "sha256", serialize = FALSE),
  entity_value = entity_value,
  generic_code = generic_code,
  none_code = none_code,
  rules = list(
    sources = c("title", "abstract"),
    deterministic_lexical_matching = TRUE,
    case_insensitive = TRUE,
    html_jats_markup_normalised = TRUE,
    whitespace_hyphen_variants_tolerated = TRUE,
    listed_misspellings_supported = TRUE,
    matcher_behaviour_inferred_from_terms = TRUE,
    fuzzy_matching = FALSE,
    semantic_inference = FALSE,
    generic_code_suppressed_when_specific_code_present = TRUE,
    generic_code = generic_code,
    pluralisable_common_head_terms = pluralisable_common_head_terms
  )
)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), file.path(output_dir, "workflow05_manifest.json"))
cat(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), "\n")
