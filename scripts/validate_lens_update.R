# =============================================================================
# File: scripts/validate_lens_update.R
# Purpose: Validate a Lens search-update file before any downstream processing.
#
# This is a gate: failure stops the update before deduplication, screening,
# annotation, or LLM/API calls.
# =============================================================================

validate_lens_update <- function(path, min_records = 1L) {
  if (!fs::file_exists(path)) {
    stop("Lens update file does not exist: ", path, call. = FALSE)
  }

  info <- fs::file_info(path)
  if (is.na(info$size) || info$size <= 0) {
    stop("Lens update file is empty: ", path, call. = FALSE)
  }

  if (tolower(tools::file_ext(path)) != "ris") {
    stop("Expected a Lens RIS file (.ris).", call. = FALSE)
  }

  raw <- readLines(path, warn = FALSE, encoding = "UTF-8")
  if (!length(raw)) stop("Lens RIS contains no text.", call. = FALSE)

  er_lines <- grep("^ER[[:space:]]*-[[:space:]]*$", raw, ignore.case = TRUE)
  record_starts <- grep("^TY[[:space:]]*-[[:space:]]*", raw, ignore.case = TRUE)
  titles <- grep("^TI[[:space:]]*-[[:space:]]*", raw, ignore.case = TRUE)

  if (!length(er_lines)) stop("Lens RIS contains no recognisable ER record terminators.", call. = FALSE)
  if (length(record_starts) < min_records) stop("Lens RIS contains too few records.", call. = FALSE)
  if (!length(titles)) stop("Lens RIS contains no title fields.", call. = FALSE)

  report <- tibble::tibble(
    file = fs::path_rel(path, start = here::here()),
    size_bytes = as.numeric(info$size),
    lines = length(raw),
    records_by_ty = length(record_starts),
    records_by_er = length(er_lines),
    title_fields = length(titles),
    validation = "PASS"
  )

  readr::write_csv(report, fs::path(fs::path_dir(path), "input_validation.csv"), na = "")
  report
}

if (sys.nframe() == 0L) {
  update_dir <- here::here("data", "updates", "2026-08-13_lens")
  validate_lens_update(fs::path(update_dir, "lens-export.ris"))
  message("Lens update input validation passed.")
}
