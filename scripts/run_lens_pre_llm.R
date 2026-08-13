# =============================================================================
# File: scripts/run_lens_pre_llm.R
# Purpose: Import and deduplicate a validated Lens update without any LLM/API
# calls. This is the controlled first processing stage for the current refresh.
# =============================================================================

source("scripts/setup_pipeline.R")
source("scripts/validate_lens_update.R")
source("R/read_corpus.R")
source("R/deduplication.R")

update_dir <- here::here("data", "updates", "2026-08-13_lens")
incoming_file <- fs::path(update_dir, "lens-export.ris")
existing_corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")

fs::dir_create(update_dir)
validate_lens_update(incoming_file)

incoming <- read_corpus(incoming_file) |>
  dplyr::mutate(source_file = basename(incoming_file), .source = "incoming")

historical <- readr::read_csv(existing_corpus_file, show_col_types = FALSE, progress = FALSE) |>
  dplyr::mutate(.source = "existing")

dedup <- deduplicate_records(records = incoming, existing_records = historical)
combined <- dedup$records
incoming_indices <- which(combined$.source == "incoming")
duplicate_indices <- unique(dedup$automatic_duplicates$duplicate_index)
removed_incoming_indices <- intersect(incoming_indices, duplicate_indices)

new_records <- combined[setdiff(incoming_indices, removed_incoming_indices), , drop = FALSE] |>
  dplyr::select(-.source)

readr::write_csv(dplyr::bind_rows(dedup$automatic_duplicates, dedup$review_candidates),
                fs::path(update_dir, "deduplication_audit.csv"), na = "")
readr::write_csv(new_records,
                fs::path(update_dir, "records_after_deduplication.csv"), na = "")

summary <- tibble::tibble(
  incoming_records = nrow(incoming),
  existing_records = nrow(historical),
  automatic_duplicates = nrow(dedup$automatic_duplicates),
  review_candidates = nrow(dedup$review_candidates),
  new_records_after_automatic_deduplication = nrow(new_records),
  status = "PASS"
)
readr::write_csv(summary, fs::path(update_dir, "pre_llm_summary.csv"), na = "")
print(summary)
message("Lens pre-LLM import and deduplication completed. No LLM/API calls were made.")
