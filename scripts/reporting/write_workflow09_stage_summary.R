#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}
req <- function(x, label) {
  if (is.null(x) || !nzchar(trimws(as.character(x)))) stop(label, " is required", call. = FALSE)
  as.character(x)
}
num <- function(x, default = NA_integer_) {
  if (is.null(x) || !length(x)) return(default)
  z <- suppressWarnings(as.integer(x[[1L]]))
  if (is.na(z)) default else z
}
val <- function(x, default = NULL) {
  if (is.null(x) || !length(x)) return(default)
  x[[1L]]
}

stage <- toupper(req(arg("--stage"), "--stage"))
if (!grepl("^W0[0-8]$", stage)) stop("--stage must be W00-W08", call. = FALSE)
run_id <- req(arg("--run-id", Sys.getenv("GITHUB_RUN_ID", "")), "--run-id")
pointer_path <- arg("--pointer", "")
status_path <- arg("--status", "docs/current_run/current_run_status.json")
output_dir <- arg("--output-dir", "docs/reporting/workflow_09_inputs/current")

if (!file.exists(status_path)) stop("Current-run status not found: ", status_path, call. = FALSE)
status <- fromJSON(status_path, simplifyVector = FALSE)

if (!nzchar(pointer_path) && stage != "W00") {
  stage_run <- as.character((status$workflow_runs %||% list())[[stage]] %||% "")
  dirs <- c(
    W01 = "docs/deduplication/zenodo",
    W02 = "docs/enrichment/zenodo",
    W03 = "docs/publication_status/zenodo",
    W04 = "docs/workflow04/zenodo",
    W05 = "docs/workflow05/zenodo",
    W06 = "docs/workflow06/zenodo",
    W07 = "docs/workflow07/zenodo",
    W08 = "docs/workflow08/zenodo"
  )
  if (nzchar(stage_run)) pointer_path <- file.path(unname(dirs[[stage]]), paste0("run-", stage_run, ".json"))
}

pointer <- NULL
pointer_sha <- NULL
if (nzchar(pointer_path)) {
  if (!file.exists(pointer_path)) stop("Pointer not found: ", pointer_path, call. = FALSE)
  pointer <- fromJSON(pointer_path, simplifyVector = FALSE)
  pointer_sha <- digest(file = pointer_path, algo = "sha256", serialize = FALSE)
}

counts <- status$counts %||% list()
metrics <- switch(
  stage,
  W00 = list(
    search_results = num(counts$search_results),
    search_date = as.character(status$search$search_date %||% "")
  ),
  W01 = {
    n_source <- num(pointer$source_manifestations, num(counts$search_results))
    n_canon <- num(pointer$canonical_records, num(counts$deduplicated_records))
    list(
      source_manifestations = n_source,
      canonical_records = n_canon,
      duplicates_removed = if (!is.na(n_source) && !is.na(n_canon)) n_source - n_canon else NA_integer_,
      canonical_sha256 = as.character(pointer$canonical_jsonl_sha256 %||% "")
    )
  },
  W02 = list(
    enriched_records = num(counts$enriched_records),
    cumulative_patch_records = num(pointer$cumulative_patch_records),
    upstream_workflow01_canonical_sha256 = as.character(pointer$upstream_workflow01_canonical_sha256 %||% ""),
    final_enriched_sha256 = as.character(pointer$final_enriched_sha256 %||% "")
  ),
  W03 = list(
    records = num(pointer$records),
    retraction_exclusions = num(pointer$exclude_from_workflow04, num(counts$retraction_exclusions)),
    status_counts = pointer$status_counts %||% list()
  ),
  W04 = list(
    records = num(pointer$records),
    retained = num(pointer$retained, num(counts$screened_include)),
    excluded = num(pointer$excluded, num(counts$screened_exclude)),
    unresolved = num(pointer$unresolved, 0L)
  ),
  W05 = list(
    records = num(pointer$records),
    coded_records = num(pointer$coded_records),
    none_records = num(pointer$none_records)
  ),
  W06 = list(
    records = num(pointer$records),
    resolved = num(pointer$resolved_n),
    none = num(pointer$none_n),
    unresolved = num(pointer$unresolved_n),
    evidence_not_grounded = num(pointer$evidence_not_grounded_n),
    model_failures = num(pointer$llm_failures_n)
  ),
  W07 = list(
    records = num(pointer$records),
    raw_topic_assignments = num(pointer$raw_topic_assignments),
    zero_topic_records = num(pointer$zero_topic_records),
    included_uncoded_records = num(pointer$included_uncoded_records),
    late_automatic_exclusions = num(pointer$late_automatic_exclusions),
    human_adjudication_records = num(pointer$human_adjudication_records)
  ),
  W08 = list(
    source_canonical_population = num(pointer$source_canonical_population),
    canonical_records = num(pointer$canonical_records),
    excluded_records = num(pointer$excluded_records),
    decision_issues = num(pointer$w08_decision_issues),
    geography_with = num(counts$geography$with),
    geography_without = num(counts$geography$without),
    topic_with = num(counts$topics$with),
    topic_without = num(counts$topics$without),
    final_canonical_sha256 = as.character(pointer$final_canonical_jsonl_sha256 %||% ""),
    exclusions_sha256 = as.character(pointer$excluded_records_csv_sha256 %||% "")
  )
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
out <- file.path(output_dir, paste0(tolower(stage), "_summary.json"))
payload <- list(
  schema = "living-evidence-map-workflow09-stage-summary-v1",
  stage = stage,
  source_run_id = as.character(run_id),
  update_id = as.character(status$update_id %||% ""),
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  pointer_path = if (nzchar(pointer_path)) pointer_path else NULL,
  pointer_sha256 = pointer_sha,
  status = "complete",
  metrics = metrics
)
writeLines(toJSON(payload, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), out, useBytes = TRUE)
cat(sprintf("PASS: wrote %s reporting summary to %s\n", stage, out))
