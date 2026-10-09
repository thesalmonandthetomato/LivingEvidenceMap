#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

pointer_path <- arg("--pointer")
output_dir <- arg("--output-dir")

if (is.null(pointer_path) || is.null(output_dir)) {
  stop("Required: --pointer --output-dir", call. = FALSE)
}
if (!file.exists(pointer_path)) stop("Pointer not found: ", pointer_path, call. = FALSE)

pointer <- fromJSON(pointer_path, simplifyVector = FALSE)
if (!identical(pointer$status, "published") || !identical(as.character(pointer$workflow), "08")) {
  stop("Invalid Workflow 08 pointer", call. = FALSE)
}
expected_records <- suppressWarnings(as.integer(pointer$canonical_records))
if (is.na(expected_records) || expected_records < 0L) {
  stop("Workflow 08 pointer has invalid canonical_records", call. = FALSE)
}

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

download_file <- function(filename, dest) {
  url <- paste0(
    "https://zenodo.org/api/records/",
    pointer$zenodo_record_id,
    "/files/",
    URLencode(filename, reserved = TRUE),
    "/content"
  )
  resp <- request(url) |>
    req_headers(Authorization = paste("Bearer", token)) |>
    req_timeout(1800) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  if (resp_status(resp) != 200L) {
    stop(sprintf("Zenodo download for %s returned HTTP %d", filename, resp_status(resp)), call. = FALSE)
  }
  writeBin(resp_body_raw(resp), dest)
  invisible(dest)
}

verify_sha <- function(path, expected, label) {
  if (is.null(expected) || !nzchar(as.character(expected))) {
    stop("Missing expected SHA-256 for ", label, call. = FALSE)
  }
  observed <- tolower(digest(file = path, algo = "sha256", serialize = FALSE))
  expected <- tolower(as.character(expected))
  if (!identical(observed, expected)) {
    stop(sprintf("SHA-256 mismatch for %s: expected %s, observed %s", label, expected, observed), call. = FALSE)
  }
  cat(sprintf("PASS: restored and verified %s\n", label))
  invisible(observed)
}

# New lossless Workflow 08 pointers store the canonical JSONL as gzip and
# expose archive/uncompressed checksums at top level. Older pointers store the
# uncompressed JSONL directly and include a files array. Support both.
if (!is.null(pointer$canonical_archive_filename) &&
    identical(as.character(pointer$canonical_archive_compression), "gzip")) {

  gz_name <- as.character(pointer$canonical_archive_filename)
  gz_dest <- file.path(output_dir, gz_name)
  canonical <- file.path(output_dir, "living_evidence_map_canonical_final.jsonl")

  download_file(gz_name, gz_dest)
  verify_sha(gz_dest, pointer$canonical_archive_sha256, gz_name)

  in_con <- gzfile(gz_dest, open = "rb")
  out_con <- file(canonical, open = "wb")
  repeat {
    buf <- readBin(in_con, what = "raw", n = 1024L * 1024L)
    if (!length(buf)) break
    writeBin(buf, out_con)
  }
  close(in_con)
  close(out_con)

  verify_sha(canonical, pointer$final_canonical_jsonl_sha256, basename(canonical))
  if (!is.null(pointer$final_canonical_jsonl_bytes)) {
    if (unname(file.info(canonical)$size) != as.numeric(pointer$final_canonical_jsonl_bytes)) {
      stop("Uncompressed canonical byte-count mismatch", call. = FALSE)
    }
  }

  exclusions_name <- "workflow08_excluded_records.csv"
  exclusions <- file.path(output_dir, exclusions_name)
  download_file(exclusions_name, exclusions)
  verify_sha(exclusions, pointer$excluded_records_csv_sha256, exclusions_name)

} else {
  wanted <- c(
    "living_evidence_map_canonical_final.jsonl",
    "workflow08_excluded_records.csv"
  )
  files <- pointer$files
  if (is.null(files) || !length(files)) {
    stop("Legacy Workflow 08 pointer is missing its files inventory", call. = FALSE)
  }
  available <- vapply(files, function(x) as.character(x$filename), character(1))
  missing <- setdiff(wanted, available)
  if (length(missing)) stop("Pointer missing required files: ", paste(missing, collapse = ", "), call. = FALSE)

  for (fn in wanted) {
    meta <- files[[match(fn, available)]]
    dest <- file.path(output_dir, fn)
    download_file(fn, dest)
    verify_sha(dest, meta$sha256, fn)
  }
  canonical <- file.path(output_dir, "living_evidence_map_canonical_final.jsonl")
}

con <- file(canonical, "rt", encoding = "UTF-8")
n <- 0L
repeat {
  x <- readLines(con, n = 5000L, warn = FALSE)
  if (!length(x)) break
  n <- n + sum(nzchar(trimws(x)))
}
close(con)

if (n != expected_records) stop(sprintf("Expected %d canonical JSONL rows from pointer, found %d", expected_records, n), call. = FALSE)
cat(sprintf("PASS: Workflow 08 reporting state restored from Zenodo with %d included canonical records\n", n))
