# Helper functions for manuscript visualisations from the Workflow 08 canonical JSONL.
#
# The authoritative analytical input after Workflow 08 is the included-only
# canonical JSONL, not the legacy CSV master. Set CANONICAL_JSONL or pass
# --canonical-jsonl <path> when running a visualisation script.

canonical_arg <- function(flag, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

.clean_scalar <- function(x) {
  z <- as.character(x %||% "")
  if (length(z) == 0L || is.na(z[[1L]])) "" else z[[1L]]
}

.clean_vec <- function(x) {
  z <- as.character(x %||% character())
  z <- trimws(z[!is.na(z)])
  unique(z[nzchar(z)])
}

canonical_jsonl_path <- function(path = NULL) {
  explicit <- path %||% canonical_arg("--canonical-jsonl") %||% Sys.getenv("CANONICAL_JSONL", unset = "")
  if (nzchar(explicit)) {
    if (!file.exists(explicit)) stop("Canonical JSONL not found: ", explicit, call. = FALSE)
    return(explicit)
  }
  candidates <- c(
    file.path("data", "master", "current", "living_evidence_map_canonical_final.jsonl"),
    file.path("outputs", "workflow08_corrected", "living_evidence_map_canonical_final.jsonl"),
    file.path("outputs", "workflow08", "living_evidence_map_canonical_final.jsonl")
  )
  hit <- candidates[file.exists(candidates)]
  if (!length(hit)) {
    stop(
      "Canonical JSONL not found. Provide --canonical-jsonl or set CANONICAL_JSONL. ",
      "Expected the included-only Workflow 08 file living_evidence_map_canonical_final.jsonl.",
      call. = FALSE
    )
  }
  hit[[1L]]
}

read_canonical_records <- function(path = NULL) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.", call. = FALSE)
  path <- canonical_jsonl_path(path)
  con <- file(path, "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  rows <- vector("list", 0L)
  n <- 0L
  repeat {
    line <- readLines(con, n = 1L, warn = FALSE)
    if (!length(line)) break
    if (!nzchar(trimws(line))) next
    rec <- jsonlite::fromJSON(line, simplifyVector = FALSE)
    scr <- rec$screening %||% list(final_included = TRUE)
    if (!isTRUE(scr$final_included %||% TRUE)) next
    id <- rec$identity %||% list()
    can <- rec$canonical %||% list()
    sp <- rec$species %||% list()
    geo <- rec$geography %||% list()
    topics <- rec$topics %||% list()
    assignments <- topics$assignments %||% list()
    paths <- .clean_vec(vapply(assignments, function(a) .clean_scalar(a$hierarchy_path), character(1)))
    n <- n + 1L
    rows[[n]] <- data.frame(
      record_id = .clean_scalar(id$record_id),
      title = .clean_scalar(can$title),
      year = suppressWarnings(as.integer(.clean_scalar(can$year %||% can$publication_year))),
      final_species = paste(.clean_vec(sp$labels), collapse = ";"),
      final_primary_country_iso3c = paste(.clean_vec(geo$iso3c), collapse = ";"),
      geography_status = .clean_scalar(geo$status),
      topic_hierarchy_paths = paste(paths, collapse = ";"),
      topic_count = length(paths),
      stringsAsFactors = FALSE
    )
  }
  if (!length(rows)) stop("No included canonical records parsed from: ", path, call. = FALSE)
  out <- do.call(rbind, rows)
  if (any(!nzchar(out$record_id)) || anyDuplicated(out$record_id)) {
    stop("Canonical JSONL contains missing or duplicate record_id values.", call. = FALSE)
  }
  out
}

load_figure_master <- function(path = NULL) {
  read_canonical_records(path)
}

split_semicolon <- function(x) {
  z <- trimws(unlist(strsplit(as.character(x %||% ""), ";", fixed = TRUE), use.names = FALSE))
  z[nzchar(z)]
}
