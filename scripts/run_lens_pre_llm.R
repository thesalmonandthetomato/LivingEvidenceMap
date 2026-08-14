# =============================================================================
# File: scripts/run_lens_pre_llm.R
# Purpose: Import and deduplicate a validated Lens update without LLM/API calls.
# =============================================================================

source("scripts/setup_pipeline.R")
source("scripts/validate_lens_update.R")
source("R/read_corpus.R")
source("R/relevance_screening.R")

update_dir <- here::here("data", "updates", "2026-08-13_lens")
incoming_file <- fs::path(update_dir, "lens-export.ris")
existing_corpus_file <- here::here("data", "reference", "salmon_evidence_map.csv")

fs::dir_create(update_dir)
validate_lens_update(incoming_file)

incoming <- read_corpus(incoming_file) |>
  dplyr::mutate(source_file = basename(incoming_file), .source = "incoming")

historical <- readr::read_csv(
  existing_corpus_file,
  show_col_types = FALSE,
  progress = FALSE
) |>
  dplyr::mutate(.source = "existing")

# First remove duplicates occurring within the incoming Lens update itself.
incoming_keyed <- incoming |>
  add_screening_keys()

internal_duplicate_title <- duplicated(incoming_keyed$title_key) & nzchar(incoming_keyed$title_key)
internal_duplicate_doi <- duplicated(incoming_keyed$doi_key) & !is.na(incoming_keyed$doi_key) & nzchar(incoming_keyed$doi_key)
internal_duplicate <- internal_duplicate_title | internal_duplicate_doi

message(sprintf(
  "Internal update deduplication: %d records before; %d duplicate records removed; %d records remain.",
  nrow(incoming_keyed),
  sum(internal_duplicate),
  sum(!internal_duplicate)
))

incoming_unique <- incoming_keyed[!internal_duplicate, , drop = FALSE] |>
  dplyr::select(-dplyr::any_of(c(
    "title_key", "doi_key", "first_author_key", "screening_text",
    "has_abstract", "title_prefix", "title_token_key"
  )))

# Then compare the internally unique update against the existing master.
dedup <- deduplicate_new_records(
  new_records = incoming_unique,
  master_records = historical
)

new_records <- dedup |>
  dplyr::filter(duplicate_status == "new") |>
  dplyr::select(-dplyr::any_of(c(
    "incoming_row", "duplicate_status", "duplicate_basis",
    "matched_master_record_id", "matched_master_title", "title_similarity"
  )))

audit <- dedup |>
  dplyr::filter(duplicate_status != "new")

readr::write_csv(
  audit,
  fs::path(update_dir, "deduplication_audit.csv"),
  na = ""
)
readr::write_csv(
  new_records,
  fs::path(update_dir, "records_after_deduplication.csv"),
  na = ""
)

summary <- tibble::tibble(
  incoming_records = nrow(incoming),
  internal_duplicates_removed = sum(internal_duplicate),
  unique_update_records = nrow(incoming_unique),
  existing_records = nrow(historical),
  automatic_duplicates = sum(dedup$duplicate_status == "duplicate"),
  probable_duplicate_candidates = sum(dedup$duplicate_status == "probable_duplicate"),
  possible_duplicate_candidates = sum(dedup$duplicate_status %in% c("possible_duplicate", "doi_conflict_review")),
  new_records_after_deduplication = nrow(new_records),
  status = "PASS"
)

readr::write_csv(summary, fs::path(update_dir, "pre_llm_summary.csv"), na = "")
print(summary)
message("Lens pre-LLM import and two-stage deduplication completed. No LLM/API calls were made.")
