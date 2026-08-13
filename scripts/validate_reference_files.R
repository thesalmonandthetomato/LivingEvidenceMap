# =============================================================================
# File: scripts/validate_reference_files.R
# Purpose: One-time integrity checks for static reference assets.
#
# The script validates existence, non-zero size, readability, and basic expected
# structure. It also writes SHA-256 checksums so future runs can detect silent
# changes to reference assets.
# =============================================================================

validate_reference_files <- function(root = here::here()) {
  files <- c(
    relevance_corpus = fs::path(root, "data", "reference", "salmon_evidence_map.csv"),
    gazetteer = fs::path(root, "config", "global_country_gazetteer_v3.csv"),
    relevance_model = fs::path(root, "models", "relevance", "salmon_farming_relevance_model.rds")
  )

  missing <- names(files)[!fs::file_exists(files)]
  if (length(missing)) {
    stop("Missing reference files: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  info <- fs::file_info(files)
  empty <- names(files)[is.na(info$size) | info$size <= 0]
  if (length(empty)) {
    stop("Empty reference files: ", paste(empty, collapse = ", "), call. = FALSE)
  }

  corpus <- readr::read_csv(files[["relevance_corpus"]], show_col_types = FALSE, progress = FALSE)
  gazetteer <- readr::read_csv(files[["gazetteer"]], show_col_types = FALSE, progress = FALSE)
  model <- readRDS(files[["relevance_model"]])

  required_corpus <- c("record_id", "title", "abstract")
  required_gazetteer <- c("country", "iso3")

  miss_corpus <- setdiff(required_corpus, names(corpus))
  miss_gazetteer <- setdiff(required_gazetteer, names(gazetteer))
  if (length(miss_corpus)) stop("Reference corpus missing columns: ", paste(miss_corpus, collapse = ", "), call. = FALSE)
  if (length(miss_gazetteer)) stop("Gazetteer missing columns: ", paste(miss_gazetteer, collapse = ", "), call. = FALSE)
  if (!is.list(model)) stop("Relevance model did not deserialize to an R list/object.", call. = FALSE)

  manifest <- tibble::tibble(
    file = names(files),
    path = unname(files),
    size_bytes = as.numeric(info$size),
    sha256 = unname(digest::digest(files, algo = "sha256", file = TRUE)),
    validation = "PASS"
  )

  out <- fs::path(root, "config", "reference_file_checksums.csv")
  readr::write_csv(manifest, out, na = "")
  manifest
}

if (sys.nframe() == 0L) {
  validate_reference_files()
  message("Reference-file validation passed and checksum manifest was written.")
}
