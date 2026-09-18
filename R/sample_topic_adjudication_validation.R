#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1L) {
  stop("Usage: Rscript R/sample_topic_adjudication_validation.R <disagreement_csv> [output_csv] [n] [seed]", call. = FALSE)
}

input_path <- args[[1]]
output_path <- if (length(args) >= 2L) args[[2]] else "data/validation/topic_adjudication_validation_sample.csv"
sample_n <- if (length(args) >= 3L) as.integer(args[[3]]) else 200L
seed <- if (length(args) >= 4L) as.integer(args[[4]]) else 20260918L

adjudication_log <- "docs/topic_adjudication_ranked_luna_2026-09.csv"

if (!file.exists(input_path)) {
  stop("Disagreement CSV not found: ", input_path, call. = FALSE)
}
if (!file.exists(adjudication_log)) {
  stop("Adjudication log not found: ", adjudication_log, call. = FALSE)
}
if (is.na(sample_n) || sample_n < 1L) {
  stop("Sample size must be a positive integer.", call. = FALSE)
}
if (is.na(seed)) {
  stop("Seed must be an integer.", call. = FALSE)
}

conflicts <- read.csv(input_path, stringsAsFactors = FALSE, check.names = FALSE)
derivation <- read.csv(adjudication_log, stringsAsFactors = FALSE, check.names = FALSE)

required_conflict <- c("record_id", "title")
missing_conflict <- setdiff(required_conflict, names(conflicts))
if (length(missing_conflict)) {
  stop("Disagreement CSV missing required columns: ", paste(missing_conflict, collapse = ", "), call. = FALSE)
}
required_derivation <- c("record_id", "title")
missing_derivation <- setdiff(required_derivation, names(derivation))
if (length(missing_derivation)) {
  stop("Adjudication log missing required columns: ", paste(missing_derivation, collapse = ", "), call. = FALSE)
}

if (anyNA(conflicts$record_id) || any(conflicts$record_id == "")) {
  stop("Disagreement table contains missing/blank record_id values.", call. = FALSE)
}
if (anyDuplicated(conflicts$record_id)) {
  dup <- unique(conflicts$record_id[duplicated(conflicts$record_id)])
  stop("Disagreement table contains duplicate record_id values: ", paste(head(dup, 10L), collapse = ", "), call. = FALSE)
}

# Exclude all records used in rule derivation. This is derived programmatically
# from the authoritative adjudication log; no record IDs are transcribed here.
derivation_ids <- unique(derivation$record_id)
eligible <- conflicts[!(conflicts$record_id %in% derivation_ids), , drop = FALSE]

if (nrow(eligible) == 0L) {
  stop("No eligible disagreements remain after excluding derivation records.", call. = FALSE)
}

actual_n <- min(sample_n, nrow(eligible))
set.seed(seed)
idx <- sample.int(nrow(eligible), size = actual_n, replace = FALSE)
sampled <- eligible[idx, , drop = FALSE]

# Preserve source fields and append sampling provenance only.
sampled$validation_sample_rank <- seq_len(nrow(sampled))
sampled$validation_sample_seed <- seed
sampled$validation_source_file <- normalizePath(input_path, winslash = "/", mustWork = TRUE)
sampled$validation_rule_set <- "data/reference/topic_adjudication_rules_v1.json"
sampled$validation_policy <- "data/reference/topic_adjudication_policy_v1.json"
sampled$manual_adjudication_status <- ""
sampled$manual_final_coding <- ""
sampled$manual_rationale <- ""
sampled$candidate_rule_ids <- ""
sampled$candidate_rule_coding <- ""
sampled$candidate_rule_status <- ""
sampled$exact_pathway_match <- ""
sampled$exact_full_ranked_match <- ""
sampled$tp <- ""
sampled$fp <- ""
sampled$fn <- ""
sampled$manual_review_required_after_rules <- ""

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
write.csv(sampled, output_path, row.names = FALSE, na = "")

manifest_path <- sub("\\.csv$", "_manifest.csv", output_path)
manifest <- data.frame(
  input_path = normalizePath(input_path, winslash = "/", mustWork = TRUE),
  output_path = output_path,
  adjudication_log = adjudication_log,
  seed = seed,
  requested_n = sample_n,
  eligible_n = nrow(eligible),
  sampled_n = nrow(sampled),
  derivation_records_excluded = length(intersect(conflicts$record_id, derivation_ids)),
  stringsAsFactors = FALSE
)
write.csv(manifest, manifest_path, row.names = FALSE)

cat("PASS: validation sample created\n")
cat("  input disagreements:", nrow(conflicts), "\n")
cat("  derivation records excluded:", length(intersect(conflicts$record_id, derivation_ids)), "\n")
cat("  eligible disagreements:", nrow(eligible), "\n")
cat("  sampled:", nrow(sampled), "\n")
cat("  seed:", seed, "\n")
cat("  output:", output_path, "\n")
cat("  manifest:", manifest_path, "\n")
