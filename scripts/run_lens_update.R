# =============================================================================
# File: scripts/run_lens_update.R
# Purpose: Run the Lens update with deterministic deduplication followed by
#          API adjudication of residual duplicate candidates.
#
# Retraction/publication-status surveillance is deliberately NOT part of this
# critical update path. Existing-corpus surveillance is handled asynchronously
# by the rolling retraction sweep; Lens ingestion must not block on OpenAlex.
# =============================================================================

source("scripts/setup_pipeline.R")
source("scripts/validate_lens_update.R")
source("R/read_corpus.R")
source("R/relevance_screening.R")
source("R/load_relevance_model.R")
source("R/llm_screening.R")
source("scripts/duplicate_adjudication.R")

ensure_relevance_packages()

update_dir <- here::here("data", "updates", "2026-08-13_lens")
incoming_file <- fs::path(update_dir, "lens-export.ris")
existing_corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")
model_file <- here::here("models", "relevance", "salmon_farming_relevance_model.rds")
output_dir <- update_dir

fs::dir_create(output_dir)
validate_lens_update(incoming_file)
stopifnot(file.exists(existing_corpus_file), file.exists(model_file))

incoming <- read_corpus(incoming_file) |>
  dplyr::mutate(source_file = basename(incoming_file), .source = "incoming")

historical <- readr::read_csv(existing_corpus_file, show_col_types = FALSE, progress = FALSE) |>
  dplyr::mutate(.source = "existing")

dedup <- deduplicate_new_records(new_records = incoming, master_records = historical)
audit <- dedup
residual <- audit |>
  dplyr::filter(duplicate_status %in% c("probable_duplicate", "possible_duplicate", "doi_conflict_review"))
adjudication_file <- fs::path(output_dir, "duplicate_adjudication.csv")

if (nrow(residual)) {
  if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required because residual duplicate candidates remain.")
  candidate_file <- tempfile(fileext = ".csv")
  readr::write_csv(residual, candidate_file, na = "")
  run_duplicate_adjudication(candidate_file, incoming_file, existing_corpus_file, adjudication_file)
  adjudication <- readr::read_csv(adjudication_file, show_col_types = FALSE)
  if (nrow(adjudication) != nrow(residual)) stop(sprintf("Expected %d duplicate adjudications, found %d.", nrow(residual), nrow(adjudication)))
  if (anyDuplicated(adjudication$incoming_row)) stop("Duplicate adjudication returned duplicate incoming_row values.")
  invalid_decisions <- setdiff(unique(adjudication$decision), c("duplicate", "not_duplicate", "uncertain"))
  if (length(invalid_decisions)) stop(paste("Invalid duplicate adjudication decision(s):", paste(invalid_decisions, collapse = ", ")))
  if (any(adjudication$decision == "uncertain")) stop("Duplicate adjudication returned uncertain decision(s); update halted for review.")
  audit <- audit |>
    dplyr::left_join(adjudication |> dplyr::select(incoming_row, api_decision = decision, api_confidence = confidence, api_rationale = rationale), by = "incoming_row") |>
    dplyr::mutate(final_duplicate_status = dplyr::case_when(
      duplicate_status == "duplicate" ~ "duplicate",
      !is.na(api_decision) & api_decision == "duplicate" ~ "duplicate",
      !is.na(api_decision) & api_decision == "not_duplicate" ~ "new",
      duplicate_status == "new" ~ "new",
      TRUE ~ "uncertain"
    ))
} else {
  adjudication <- tibble::tibble(incoming_row = integer(), matched_master_record_id = character(), duplicate_basis = character(), title_similarity = double(), decision = character(), confidence = double(), rationale = character())
  readr::write_csv(adjudication, adjudication_file, na = "")
  audit <- audit |> dplyr::mutate(final_duplicate_status = duplicate_status)
}

readr::write_csv(audit, fs::path(output_dir, "deduplication_audit.csv"), na = "")
new_records <- audit |>
  dplyr::filter(final_duplicate_status == "new") |>
  dplyr::select(incoming_row) |>
  dplyr::inner_join(incoming |> dplyr::mutate(incoming_row = dplyr::row_number()), by = "incoming_row") |>
  dplyr::select(-incoming_row, -.source)
readr::write_csv(new_records, fs::path(output_dir, "records_after_deduplication.csv"), na = "")

summary <- tibble::tibble(
  incoming_records = nrow(incoming), existing_records = nrow(historical),
  automatic_duplicates = sum(audit$duplicate_status == "duplicate", na.rm = TRUE),
  residual_candidates = nrow(residual), api_duplicates = sum(audit$api_decision == "duplicate", na.rm = TRUE),
  api_not_duplicates = sum(audit$api_decision == "not_duplicate", na.rm = TRUE), api_uncertain = sum(audit$api_decision == "uncertain", na.rm = TRUE),
  new_records_after_deduplication = nrow(new_records), status = "PASS"
)
readr::write_csv(summary, fs::path(output_dir, "pre_llm_summary.csv"), na = "")
print(summary)

relevance <- screen_with_saved_relevance_model(new_records, model_path = model_file)
message("Lens update: relevance model complete; preparing compact relevance audit.")
relevance_audit <- relevance |> dplyr::select(dplyr::any_of(c("record_id", "doi", "title", "relevance_probability", "relevance_decision")))
message(sprintf("Lens update: writing relevance audit for %d records.", nrow(relevance_audit)))
readr::write_csv(relevance_audit, fs::path(output_dir, "relevance_screening.csv"), na = "")
message("Lens update: relevance audit written.")

message("LLM screening: constructing review set.")
llm_input <- relevance |> dplyr::filter(relevance_decision == "review") |> dplyr::mutate(llm_record_key = dplyr::row_number())
message(sprintf("LLM screening: %d of %d records require API review.", nrow(llm_input), nrow(relevance)))

if (nrow(llm_input)) {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(api_key)) stop("OPENAI_API_KEY is required because statistically uncertain records remain.")
  batch_size <- 25L
  batch_starts <- seq(1L, nrow(llm_input), by = batch_size)
  n_batches <- length(batch_starts)
  message(sprintf("LLM screening: %d records in %d batches of up to %d.", nrow(llm_input), n_batches, batch_size))
  llm_results <- purrr::map_dfr(seq_along(batch_starts), function(batch_index) {
    start <- batch_starts[[batch_index]]
    end <- min(start + batch_size - 1L, nrow(llm_input))
    batch <- llm_input[start:end, ]
    message(sprintf("LLM screening: batch %d/%d (%d records).", batch_index, n_batches, nrow(batch)))
    result <- screen_salmon_batch(batch, api_key = api_key)
    message(sprintf("LLM screening: batch %d/%d complete (%d records).", batch_index, n_batches, nrow(result)))
    result
  })
} else {
  llm_results <- tibble::tibble(llm_record_key = integer(), record_id = character(), llm_decision = character(), llm_reason = character(), llm_failed = logical(), llm_error = character())
}

message("LLM screening: all batches returned.")
message(sprintf("LLM screening: validating %d results against %d input records.", nrow(llm_results), nrow(llm_input)))
if (nrow(llm_results) != nrow(llm_input)) stop(sprintf("LLM screening returned %d results for %d input records.", nrow(llm_results), nrow(llm_input)))
message("LLM screening: result count validation passed.")
expected_keys <- sort(llm_input$llm_record_key)
returned_keys <- sort(llm_results$llm_record_key)
if (!identical(expected_keys, returned_keys)) stop(sprintf("LLM screening key mismatch: %d missing, %d unexpected.", length(setdiff(expected_keys, returned_keys)), length(setdiff(returned_keys, expected_keys))))
message("LLM screening: key validation passed.")
message("LLM screening: writing llm_screening.csv.")
readr::write_csv(llm_results, fs::path(output_dir, "llm_screening.csv"), na = "")
message("LLM screening: llm_screening.csv written.")

message("Lens update: constructing final screening table by direct key assignment.")
final_screened <- relevance
final_screened$llm_decision <- NA_character_
final_screened$llm_reason <- NA_character_
final_screened$llm_failed <- NA
final_screened$llm_error <- NA_character_

if (nrow(llm_results)) {
  review_positions <- which(final_screened$relevance_decision == "review")
  if (length(review_positions) != nrow(llm_results)) stop("LLM review-position count does not match LLM result count.")
  order_idx <- match(seq_len(nrow(llm_input)), llm_results$llm_record_key)
  if (anyNA(order_idx)) stop("LLM results are missing one or more review keys.")
  final_screened$llm_decision[review_positions] <- llm_results$llm_decision[order_idx]
  final_screened$llm_reason[review_positions] <- llm_results$llm_reason[order_idx]
  final_screened$llm_failed[review_positions] <- llm_results$llm_failed[order_idx]
  final_screened$llm_error[review_positions] <- llm_results$llm_error[order_idx]
}

message("Lens update: LLM results assigned; deriving final screening decisions.")
final_screened$final_screening_decision <- dplyr::case_when(
  final_screened$relevance_decision == "automatic_retain" ~ "retain",
  final_screened$relevance_decision == "automatic_exclude" ~ "exclude",
  final_screened$relevance_decision == "review" & final_screened$llm_decision == "retain" & !final_screened$llm_failed ~ "retain",
  final_screened$relevance_decision == "review" & final_screened$llm_decision == "exclude" & !final_screened$llm_failed ~ "exclude",
  TRUE ~ "uncertain"
)
message("Lens update: final screening table constructed.")

# The full relevance object contains all Lens metadata. Writing it with
# readr/vroom can become unexpectedly expensive on CI after the LLM columns
# are added. Write the three required deliverables with base R's streaming CSV
# writer instead; this keeps the post-screening stage bounded and avoids the
# second apparent hang observed after final_screened construction.
message("Lens update: writing screening_final.csv.")
utils::write.csv(final_screened, fs::path(output_dir, "screening_final.csv"), row.names = FALSE, na = "")
message("Lens update: screening_final.csv written.")

retained <- final_screened |> dplyr::filter(final_screening_decision == "retain")
message(sprintf("Lens update: writing retained records (%d).", nrow(retained)))
utils::write.csv(retained, fs::path(output_dir, "records_retained_for_annotation.csv"), row.names = FALSE, na = "")
message("Lens update: retained records written.")

uncertain <- final_screened |> dplyr::filter(final_screening_decision == "uncertain")
message(sprintf("Lens update: writing uncertain records (%d).", nrow(uncertain)))
utils::write.csv(uncertain, fs::path(output_dir, "screening_uncertain.csv"), row.names = FALSE, na = "")
message("Lens update: uncertain records written.")

message("Lens update: starting annotation stage.")
source("scripts/annotate_lens_update.R")
message("Lens update: annotation stage complete; starting topic smoke test.")
source("scripts/topic_smoke_test.R")
message("Lens update completed through species/geography adjudication and topic smoke test.")
