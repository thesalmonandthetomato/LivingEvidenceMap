#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(fs)
  library(httr2)
  library(jsonlite)
  library(readr)
  library(tibble)
})

# Workflow 05B: LLM adjudication of residual deterministic uncertainty only.
#
# This is a direct canonical-JSON adaptation of the adjudication section of
# scripts/annotate_lens_update.R on main. It consumes the deterministic outputs
# produced by Workflow 05A and calls the model ONLY for rows in
# annotation_adjudication_queue.csv.

source("scripts/setup_pipeline.R")
source("R/llm_adjudication.R")

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
deterministic_dir <- arg("--deterministic-dir", "outputs/workflow05/deterministic")
output_dir <- arg("--output-dir", "outputs/workflow05/final")
model <- arg("--model", "gpt-5-mini")

if (is.null(input_path) || !file.exists(input_path)) stop("Valid --input canonical JSONL is required", call. = FALSE)
queue_path <- path(deterministic_dir, "annotation_adjudication_queue.csv")
state_path <- path(deterministic_dir, "deterministic_annotation_summary.csv")
records_path <- path(deterministic_dir, "records_for_annotation.csv")
for (p in c(queue_path, state_path, records_path)) if (!file.exists(p)) stop("Missing deterministic Workflow 05 artefact: ", p, call. = FALSE)
dir_create(output_dir, recurse = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x
clean <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(seq_along(lines), function(i) {
    tryCatch(jsonlite::fromJSON(lines[[i]], simplifyVector = FALSE),
      error = function(e) stop(sprintf("Invalid JSONL line %d: %s", i, conditionMessage(e)), call. = FALSE))
  })
}
write_jsonl <- function(records, path_out) {
  con <- file(path_out, open = "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  for (r in records) writeLines(toJSON(r, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
}

queue <- read_csv(queue_path, show_col_types = FALSE, progress = FALSE)
state <- read_csv(state_path, show_col_types = FALSE, progress = FALSE)
records <- read_csv(records_path, show_col_types = FALSE, progress = FALSE)
canonical_records <- read_jsonl(input_path)

openai_annotation_model <- function(system_prompt, user_prompt, schema,
                                     api_key = Sys.getenv("OPENAI_API_KEY"), model_name = model) {
  if (!nzchar(api_key)) stop("OPENAI_API_KEY was not found.")
  body <- list(
    model = model_name,
    store = FALSE,
    reasoning = list(effort = "low"),
    input = list(
      list(role = "system", content = list(list(type = "input_text", text = system_prompt))),
      list(role = "user", content = list(list(type = "input_text", text = user_prompt)))
    ),
    text = list(verbosity = "low", format = list(
      type = "json_schema",
      name = "salmon_annotation_adjudication",
      strict = TRUE,
      schema = schema
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

# Same gate as the production updater: no queue means no API calls.
if (nrow(queue)) {
  if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required because deterministic annotation left residual uncertainty.")
  message(sprintf("Workflow 05B: LLM adjudication starting for %d uncertain records only.", nrow(queue)))
  adjudication <- adjudicate_annotation_queue(queue, openai_annotation_model, progress = TRUE)
} else {
  message("Workflow 05B: adjudication queue empty; no API calls required.")
  adjudication <- tibble(
    record_id = character(),
    species_decision = character(),
    llm_species = character(),
    species_reason = character(),
    geography_decision = character(),
    llm_primary_country_iso3c = character(),
    geography_reason = character(),
    llm_failed = logical(),
    llm_error = character()
  )
}

write_csv(adjudication, path(output_dir, "annotation_adjudication.csv"), na = "")

# Match weekly updater behaviour: technical API/model failures are not treated
# as substantive uncertainty and must fail the run.
if (nrow(adjudication) && any(adjudication$llm_failed %in% TRUE)) {
  stop(sprintf("Technical LLM failure detected in %d annotation adjudication row(s)", sum(adjudication$llm_failed %in% TRUE)), call. = FALSE)
}

final <- state |>
  left_join(adjudication, by = "record_id")
write_csv(final, path(output_dir, "records_after_species_geography_adjudication.csv"), na = "")

# Residual substantive uncertainty is retained for the later combined
# post-topic human-review gate; Workflow 05 does not notify or promote.
review <- final |>
  filter(
    species_decision == "UNRESOLVED" |
      geography_decision == "UNRESOLVED"
  )
write_csv(review, path(output_dir, "workflow05_review_queue.csv"), na = "")

# Write Workflow 05 evidence into the canonical JSON while preserving every
# upstream field and every record, including Workflow 04 exclusions.
for (i in seq_len(nrow(final))) {
  idx <- as.integer(final$canonical_index[[i]])
  if (is.na(idx) || idx < 1L || idx > length(canonical_records)) stop("Invalid canonical_index for record ", final$record_id[[i]], call. = FALSE)

  species_review_required <- isTRUE(final$species_review_required[[i]])
  geography_review_required <- isTRUE(final$geography_review_required[[i]])
  sp_dec <- clean(final$species_decision[[i]])
  geo_dec <- clean(final$geography_decision[[i]])

  species_status <- if (!species_review_required) "resolved_deterministic" else if (sp_dec %in% c("ACCEPT", "CHANGE")) "resolved_llm_adjudicated" else "unresolved"
  geography_status <- if (!geography_review_required) "resolved_deterministic" else if (geo_dec %in% c("ACCEPT", "CHANGE")) "resolved_llm_adjudicated" else "unresolved"

  annotation <- list(
    workflow = "workflow_05_species_geography",
    method_source = "scripts/annotate_lens_update.R on main",
    completed_at = now_utc(),
    species = list(
      deterministic_species = clean(final$deterministic_species[[i]]),
      deterministic_species_ids = clean(final$deterministic_species_ids[[i]]),
      review_required = species_review_required,
      assignment_reason = clean(final$species_assignment_reason[[i]]),
      non_target_species = clean(final$non_target_species[[i]]),
      adjudication_decision = if (species_review_required) sp_dec else "NOT_REVIEWED",
      llm_species = if (species_review_required) clean(final$llm_species[[i]]) else "",
      llm_reason = if (species_review_required) clean(final$species_reason[[i]]) else "",
      status = species_status
    ),
    geography = list(
      deterministic_primary_countries = clean(final$deterministic_primary_countries[[i]]),
      deterministic_primary_iso3c = clean(final$deterministic_primary_iso3c[[i]]),
      review_required = geography_review_required,
      review_reason = clean(final$geography_review_reason[[i]]),
      adjudication_decision = if (geography_review_required) geo_dec else "NOT_REVIEWED",
      llm_primary_country_iso3c = if (geography_review_required) clean(final$llm_primary_country_iso3c[[i]]) else "",
      llm_reason = if (geography_review_required) clean(final$geography_reason[[i]]) else "",
      status = geography_status
    )
  )

  if (is.null(canonical_records[[idx]]$annotations)) canonical_records[[idx]]$annotations <- list()
  canonical_records[[idx]]$annotations$species_geography <- annotation
}

write_jsonl(canonical_records, path(output_dir, "records.jsonl"))

summary <- list(
  workflow = "workflow_05_species_geography",
  stage = "complete",
  canonical_records = length(canonical_records),
  records_forwarded_from_workflow04 = nrow(final),
  deterministic_review_queue_records = nrow(queue),
  llm_calls_attempted = nrow(queue),
  llm_technical_failures = 0L,
  residual_substantive_uncertainty = nrow(review),
  substantive_uncertainty_deferred_to_post_topic_gate = TRUE,
  email_notification_sent = FALSE,
  method_source = "scripts/annotate_lens_update.R on main",
  model = if (nrow(queue)) model else NA_character_
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, na = "null"), path(output_dir, "workflow05_summary.json"))
message(sprintf("Workflow 05 complete: %d records annotated; %d LLM adjudications; %d residual review records.", nrow(final), nrow(queue), nrow(review)))
