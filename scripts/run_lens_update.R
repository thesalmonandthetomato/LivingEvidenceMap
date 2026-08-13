# =============================================================================
# File: scripts/run_lens_update.R
# Purpose: Run the established salmon scoping-review Lens update workflow.
#
# Order:
#   1. Import Lens RIS
#   2. Deduplicate against the existing evidence-map corpus and within batch
#   3. Remove publication notices/retractions
#   4. Statistical relevance screening
#   5. LLM adjudication of statistically uncertain screening records
#   6. Species annotation
#   7. Geography annotation
#   8. Species/geography LLM adjudication
#   9. Topic classification (small API smoke test only for this refresh)
#
# The topic methods remain part of the production pipeline and are always last.
# This refresh does not reclassify the full corpus for topics.
#
# All inputs are read from LivingEvidenceMap. There is no runtime dependency on
# the historical salmonscopingreview repository.
# =============================================================================

source("scripts/00_setup.R")
source("R/read_corpus.R")
source("R/deduplication.R")
source("R/publication_status.R")
source("R/relevance_screening.R")
source("R/load_relevance_model.R")
source("R/llm_screening.R")

ensure_relevance_packages()

update_dir <- here::here("data", "updates", "2026-08-13_lens")
incoming_file <- fs::path(update_dir, "lens-export.ris")
existing_corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")
model_file <- here::here("models", "relevance", "salmon_farming_relevance_model.rds")
output_dir <- update_dir

fs::dir_create(output_dir)

stopifnot(file.exists(incoming_file), file.exists(existing_corpus_file), file.exists(model_file))

# 1. Import
incoming <- read_corpus(incoming_file) |>
  dplyr::mutate(source_file = basename(incoming_file), record_sequence = dplyr::row_number(), .source = "incoming")

historical <- readr::read_csv(existing_corpus_file, show_col_types = FALSE, progress = FALSE) |>
  dplyr::mutate(.source = "existing")

# 2. Deduplication

dedup <- deduplicate_records(records = incoming, existing_records = historical)
combined <- dedup$records
incoming_indices <- which(combined$.source == "incoming")
duplicate_indices <- unique(dedup$automatic_duplicates$duplicate_index)
removed_incoming_indices <- intersect(incoming_indices, duplicate_indices)

new_records <- combined[setdiff(incoming_indices, removed_incoming_indices), , drop = FALSE] |>
  dplyr::select(-.source)

readr::write_csv(dplyr::bind_rows(dedup$automatic_duplicates, dedup$review_candidates), fs::path(output_dir, "deduplication_audit.csv"), na = "")
readr::write_csv(new_records, fs::path(output_dir, "records_after_deduplication.csv"), na = "")

# 3. Publication status / retractions
publication <- check_publication_status(new_records)
readr::write_csv(publication$audit, fs::path(output_dir, "publication_status_audit.csv"), na = "")
readr::write_csv(publication$removed, fs::path(output_dir, "removed_retractions_and_notices.csv"), na = "")
readr::write_csv(publication$cleared, fs::path(output_dir, "records_after_publication_status.csv"), na = "")

# 4. Statistical relevance screening
relevance <- screen_with_saved_relevance_model(publication$cleared, model_path = model_file)
readr::write_csv(relevance, fs::path(output_dir, "relevance_screening.csv"), na = "")

# 5. LLM adjudication of statistical uncertainty
llm_input <- relevance |>
  dplyr::filter(relevance_decision == "review") |>
  dplyr::mutate(llm_record_key = dplyr::row_number())

if (nrow(llm_input)) {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(api_key)) stop("OPENAI_API_KEY is required because statistically uncertain records remain.")
  llm_results <- purrr::map_dfr(seq_len(nrow(llm_input)), function(i) {
    row <- llm_input[i, ]
    screen_salmon_record(llm_record_key = row$llm_record_key, record_id = row$record_id,
                         title = row$title, abstract = row$abstract, api_key = api_key)
  })
} else {
  llm_results <- tibble::tibble(llm_record_key = integer(), record_id = character(),
                                llm_decision = character(), llm_reason = character(),
                                llm_failed = logical(), llm_error = character())
}

readr::write_csv(llm_results, fs::path(output_dir, "llm_screening.csv"), na = "")

final_screened <- relevance |>
  dplyr::left_join(llm_results |>
                     dplyr::select(record_id, llm_decision, llm_reason, llm_failed, llm_error),
                   by = "record_id") |>
  dplyr::mutate(final_screening_decision = dplyr::case_when(
    relevance_decision == "automatic_retain" ~ "retain",
    relevance_decision == "automatic_exclude" ~ "exclude",
    relevance_decision == "review" & llm_decision == "retain" & !llm_failed ~ "retain",
    relevance_decision == "review" & llm_decision == "exclude" & !llm_failed ~ "exclude",
    TRUE ~ "uncertain"
  ))

readr::write_csv(final_screened, fs::path(output_dir, "screening_final.csv"), na = "")
retained <- final_screened |> dplyr::filter(final_screening_decision == "retain")
readr::write_csv(retained, fs::path(output_dir, "records_retained_for_annotation.csv"), na = "")
readr::write_csv(final_screened |> dplyr::filter(final_screening_decision == "uncertain"),
                fs::path(output_dir, "screening_uncertain.csv"), na = "")

summary <- tibble::tibble(
  stage = c("Lens RIS records", "Removed as definitive duplicates", "Remaining after deduplication",
            "Removed as retractions/notices", "Remaining after publication status", "Automatic retain",
            "Automatic exclude", "LLM retain", "LLM exclude", "Still uncertain"),
  n = c(nrow(incoming), length(removed_incoming_indices), nrow(new_records), nrow(publication$removed),
        nrow(publication$cleared), sum(relevance$relevance_decision == "automatic_retain"),
        sum(relevance$relevance_decision == "automatic_exclude"),
        sum(final_screened$final_screening_decision == "retain" & relevance$relevance_decision == "review"),
        sum(final_screened$final_screening_decision == "exclude" & relevance$relevance_decision == "review"),
        sum(final_screened$final_screening_decision == "uncertain"))
)
readr::write_csv(summary, fs::path(output_dir, "screening_summary.csv"), na = "")

# 6-8. Species, geography, and annotation adjudication
source("scripts/annotate_lens_update.R")

# 9. Topics are always last. For this refresh, run only the controlled API smoke test.
source("scripts/topic_smoke_test.R")

message("Lens update completed through species/geography adjudication and topic smoke test.")
