# =============================================================================
# File: scripts/validate_reference_files.R
# Purpose: One-time integrity checks for static reference assets.
#
# Validates existence, non-zero size, readability, expected structure, and
# writes SHA-256 checksums so later checks can detect silent changes.
# =============================================================================

reference_paths <- function(root = here::here()) {
  c(
    relevance_corpus = fs::path(root, "data", "reference", "salmon_evidence_map.csv"),
    gazetteer = fs::path(root, "config", "global_country_gazetteer_v3.csv"),
    relevance_model = fs::path(root, "models", "relevance", "salmon_farming_relevance_model.rds")
  )
}

validate_reference_files <- function(root = here::here()) {
  files <- reference_paths(root)

  missing <- names(files)[!fs::file_exists(files)]
  if (length(missing)) stop("Missing reference files: ", paste(missing, collapse = ", "), call. = FALSE)

  info <- fs::file_info(files)
  empty <- names(files)[is.na(info$size) | info$size <= 0]
  if (length(empty)) stop("Empty reference files: ", paste(empty, collapse = ", "), call. = FALSE)

  corpus <- readr::read_csv(files[["relevance_corpus"]], show_col_types = FALSE, progress = FALSE)
  gazetteer <- readr::read_csv(files[["gazetteer"]], show_col_types = FALSE, progress = FALSE)
  bundle <- readRDS(files[["relevance_model"]])

  miss_corpus <- setdiff(c("record_id", "title", "abstract"), names(corpus))
  miss_gazetteer <- setdiff(c("country", "iso3"), names(gazetteer))
  if (length(miss_corpus)) stop("Reference corpus missing columns: ", paste(miss_corpus, collapse = ", "), call. = FALSE)
  if (length(miss_gazetteer)) stop("Gazetteer missing columns: ", paste(miss_gazetteer, collapse = ", "), call. = FALSE)

  required_bundle <- c("model", "thresholds")
  if (length(setdiff(required_bundle, names(bundle)))) stop("Relevance model bundle is structurally invalid.", call. = FALSE)
  if (length(setdiff(c("cv_fit", "features", "idf"), names(bundle$model)))) stop("Relevance model is structurally invalid.", call. = FALSE)
  if (length(setdiff(c("exclude_threshold", "include_threshold"), names(bundle$thresholds)))) stop("Relevance thresholds are structurally invalid.", call. = FALSE)

  manifest <- tibble::tibble(
    file = names(files),
    path = unname(files),
    size_bytes = as.numeric(info$size),
    sha256 = purrr::map_chr(files, ~ digest::digest(.x, algo = "sha256", file = TRUE)),
    validation = "PASS"
  )

  out <- fs::path(root, "config", "reference_file_checksums.csv")
  readr::write_csv(manifest, out, na = "")
  manifest
}

verify_reference_checksums <- function(root = here::here()) {
  manifest_path <- fs::path(root, "config", "reference_file_checksums.csv")
  if (!fs::file_exists(manifest_path)) stop("Reference checksum manifest not found: ", manifest_path, call. = FALSE)

  manifest <- readr::read_csv(manifest_path, show_col_types = FALSE, progress = FALSE)
  files <- reference_paths(root)
  expected <- stats::setNames(manifest$sha256, manifest$file)
  actual <- purrr::map_chr(files, ~ digest::digest(.x, algo = "sha256", file = TRUE))
  changed <- names(files)[is.na(expected[names(files)]) | actual != expected[names(files)]]
  if (length(changed)) stop("Reference files differ from the recorded checksums: ", paste(changed, collapse = ", "), call. = FALSE)
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  validate_reference_files()
  message("Reference-file validation passed and checksum manifest was written.")
}
