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
if (!identical(as.integer(pointer$canonical_records), 19117L)) {
  stop("Workflow 08 pointer does not describe the 19,117-record final canonical", call. = FALSE)
}

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

wanted <- c(
  "living_evidence_map_canonical_final.jsonl",
  "workflow08_excluded_records.csv"
)
files <- pointer$files
available <- vapply(files, function(x) as.character(x$filename), character(1))
missing <- setdiff(wanted, available)
if (length(missing)) stop("Pointer missing required files: ", paste(missing, collapse = ", "), call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

for (fn in wanted) {
  meta <- files[[match(fn, available)]]
  url <- paste0(
    "https://zenodo.org/api/records/",
    pointer$zenodo_record_id,
    "/files/",
    URLencode(fn, reserved = TRUE),
    "/content"
  )
  dest <- file.path(output_dir, fn)
  resp <- request(url) |>
    req_headers(Authorization = paste("Bearer", token)) |>
    req_timeout(1800) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  if (resp_status(resp) != 200L) {
    stop(sprintf("Zenodo download for %s returned HTTP %d", fn, resp_status(resp)), call. = FALSE)
  }
  writeBin(resp_body_raw(resp), dest)

  observed <- tolower(digest(file = dest, algo = "sha256", serialize = FALSE))
  expected <- tolower(as.character(meta$sha256))
  if (!identical(observed, expected)) {
    stop(sprintf("SHA-256 mismatch for %s: expected %s, observed %s", fn, expected, observed), call. = FALSE)
  }
  cat(sprintf("PASS: restored and verified %s\n", fn))
}

canonical <- file.path(output_dir, "living_evidence_map_canonical_final.jsonl")
con <- file(canonical, "rt", encoding = "UTF-8")
on.exit(close(con), add = TRUE)
n <- 0L
repeat {
  x <- readLines(con, n = 5000L, warn = FALSE)
  if (!length(x)) break
  n <- n + sum(nzchar(trimws(x)))
}
if (n != 19117L) stop(sprintf("Expected 19,117 canonical JSONL rows, found %d", n), call. = FALSE)
cat("PASS: Workflow 08 reporting state restored from Zenodo with 19,117 included canonical records\n")
