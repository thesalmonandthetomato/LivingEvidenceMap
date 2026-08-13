# =============================================================================
# File: scripts/70_run_lens_update.R
# Purpose: Run a new Lens.org RIS update through the established salmon evidence
#          map workflow, in the required order.
#
# Order:
#   1. Import RIS
#   2. Bramer-style deduplication against the existing corpus and within the
#      incoming batch
#   3. Publication-status screening (notices + OpenAlex retractions)
#   4. Statistical relevance screening with the saved validated model
#   5. LLM adjudication of statistically uncertain records
#   6. Species annotation
#   7. Geography annotation
#   8. Topics (deliberately NOT run by this update script)
#
# The species/geography functions are deliberately kept as separate annotation
# stages so that their existing deterministic rules and LLM adjudication remain
# unchanged. This script establishes the correct ordering and produces the
# retained corpus that those stages consume.
# =============================================================================

source("scripts/00_setup.R")
source("R/read_corpus.R")
source("R/deduplication.R")
source("R/publication_status.R")
source("R/relevance_screening.R")
source("R/load_relevance_model.R")
source("R/llm_screening.R")

ensure_relevance_packages()

incoming_dir <- here::here("data_updates", "incoming")
include_file <- here::here("data_raw", "INCLUDES fixed abstracts.txt")
exclude_file <- here::here("data_raw", "EXCLUDES.ris")
model_file <- here::here(
  "models", "relevance", "salmon_farming_relevance_model.rds"
)
output_dir <- here::here("outputs", "lens_update")

fs::dir_create(output_dir)

stopifnot(
  file.exists(include_file),
  file.exists(exclude_file),
  file.exists(model_file)
)

ris_files <- fs::dir_ls(
  incoming_dir,
  regexp = "\\.ris$",
  type = "file",
  recurse = FALSE
)

if (!length(ris_files)) {
  stop("No Lens.org RIS files found in: ", incoming_dir, call. = FALSE)
}

# -----------------------------------------------------------------------------
# 1. Import
# -----------------------------------------------------------------------------
incoming <- dplyr::bind_rows(lapply(ris_files, read_corpus)) |>
  dplyr::mutate(
    source_file = rep(basename(ris_files), lengths(lapply(ris_files, function(x) read_corpus(x)$record_id)))
  )

historical <- dplyr::bind_rows(
  read_corpus(include_file) |>
    dplyr::mutate(historical_decision = "include"),
  read_corpus(exclude_file) |>
    dplyr::mutate(historical_decision = "exclude")
)

# -----------------------------------------------------------------------------
# 2. Bramer-style deduplication
# -----------------------------------------------------------------------------
dedup <- deduplicate_records(
  records = incoming,
  existing_records = historical
)

combined <- dedup$records
incoming_indices <- which(combined$.source == "incoming")
duplicate_indices <- unique(dedup$automatic_duplicates$duplicate_index)
removed_incoming_indices <- intersect(incoming_indices, duplicate_indices)

new_records <- combined[
  setdiff(incoming_indices, removed_incoming_indices),
  , drop = FALSE
] |>
  dplyr::select(-.source)

dplyr::bind_rows(
  dedup$automatic_duplicates,
  dedup$review_candidates
) |>
  readr::write_csv(
    fs::path(output_dir, "deduplication_audit.csv"),
    na = ""
  )

readr::write_csv(
  new_records,
  fs::path(output_dir, "records_after_deduplication.csv"),
  na = ""
)

# -----------------------------------------------------------------------------
# 3. Publication status / retractions
# -----------------------------------------------------------------------------
publication <- check_publication_status(new_records)

readr::write_csv(
  publication$audit,
  fs::path(output_dir, "publication_status_audit.csv"),
  na = ""
)
readr::write_csv(
  publication$removed,
  fs::path(output_dir, "removed_retractions_and_notices.csv"),
  na = ""
)
readr::write_csv(
  publication$cleared,
  fs::path(output_dir, "records_after_publication_status.csv"),
  na = ""
)

# -----------------------------------------------------------------------------
# 4. Statistical relevance screening using the saved validated model
# -----------------------------------------------------------------------------
relevance <- screen_with_saved_relevance_model(
  publication$cleared,
  model_path = model_file
)

readr::write_csv(
  relevance,
  fs::path(output_dir, "relevance_screening.csv"),
  na = ""
)

# -----------------------------------------------------------------------------
# 5. LLM adjudication of statistical uncertainty
# -----------------------------------------------------------------------------
llm_input <- relevance |>
  dplyr::filter(relevance_decision == "review") |>
  dplyr::mutate(llm_record_key = dplyr::row_number())

if (nrow(llm_input)) {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(api_key)) {
    stop("OPENAI_API_KEY is required because statistically uncertain records remain.")
  }

  llm_results <- purrr::map_dfr(seq_len(nrow(llm_input)), function(i) {
    row <- llm_input[i, ]
    screen_salmon_record(
      llm_record_key = row$llm_record_key,
      record_id = row$record_id,
      title = row$title,
      abstract = row$abstract,
      api_key = api_key
    )
  })

  readr::write_csv(
    llm_results,
    fs::path(output_dir, "llm_screening.csv"),
    na = ""
  )
} else {
  llm_results <- tibble::tibble(
    llm_record_key = integer(), record_id = character(),
    llm_decision = character(), llm_reason = character(),
    llm_failed = logical(), llm_error = character()
  )
  readr::write_csv(
    llm_results,
    fs::path(output_dir, "llm_screening.csv"),
    na = ""
  )
}

final_screened <- relevance |>
  dplyr::left_join(
    llm_results |>
      dplyr::select(record_id, llm_decision, llm_reason, llm_failed, llm_error),
    by = "record_id"
  ) |>
  dplyr::mutate(
    final_screening_decision = dplyr::case_when(
      relevance_decision == "automatic_retain" ~ "retain",
      relevance_decision == "automatic_exclude" ~ "exclude",
      relevance_decision == "review" & llm_decision == "retain" & !llm_failed ~ "retain",
      relevance_decision == "review" & llm_decision == "exclude" & !llm_failed ~ "exclude",
      TRUE ~ "uncertain"
    )
  )

readr::write_csv(
  final_screened,
  fs::path(output_dir, "screening_final.csv"),
  na = ""
)

readr::write_csv(
  final_screened |>
    dplyr::filter(final_screening_decision == "retain"),
  fs::path(output_dir, "records_retained_for_annotation.csv"),
  na = ""
)

readr::write_csv(
  final_screened |>
    dplyr::filter(final_screening_decision == "uncertain"),
  fs::path(output_dir, "screening_uncertain.csv"),
  na = ""
)

summary <- tibble::tibble(
  stage = c(
    "Lens RIS records",
    "Removed as definitive duplicates",
    "Remaining after deduplication",
    "Removed as retractions/notices",
    "Remaining after publication status",
    "Automatic retain",
    "Automatic exclude",
    "LLM retain",
    "LLM exclude",
    "Still uncertain"
  ),
  n = c(
    nrow(incoming),
    length(removed_incoming_indices),
    nrow(new_records),
    nrow(publication$removed),
    nrow(publication$cleared),
    sum(relevance$relevance_decision == "automatic_retain"),
    sum(relevance$relevance_decision == "automatic_exclude"),
    sum(final_screened$final_screening_decision == "retain" & relevance$relevance_decision == "review"),
    sum(final_screened$final_screening_decision == "exclude" & relevance$relevance_decision == "review"),
    sum(final_screened$final_screening_decision == "uncertain")
  )
)

readr::write_csv(summary, fs::path(output_dir, "screening_summary.csv"), na = "")

message("Lens update completed through relevance/LLM screening.")
message("Retained records for species/geography annotation: ",
        fs::path(output_dir, "records_retained_for_annotation.csv"))
message("Topics are deliberately not run by this update.")
