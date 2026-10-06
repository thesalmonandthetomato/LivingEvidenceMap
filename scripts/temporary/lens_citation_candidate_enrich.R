#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}
`%||%` <- function(x, y) if (is.null(x)) y else x

ids_path <- arg("--candidate-ids")
output_dir <- arg("--output-dir", "outputs/lens_candidate_enrichment")
chunk_size <- as.integer(arg("--chunk-size", "500"))
if (is.null(ids_path) || !file.exists(ids_path)) stop("--candidate-ids file is required", call. = FALSE)
if (is.na(chunk_size) || chunk_size < 1L || chunk_size > 500L) stop("--chunk-size must be 1..500", call. = FALSE)

token <- Sys.getenv("LENS_API_TOKEN", unset = "")
if (!nzchar(token)) stop("LENS_API_TOKEN is required", call. = FALSE)
api <- "https://api.lens.org/scholarly/search"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

lens_request <- function(payload) {
  req <- request(api) |>
    req_headers(
      Authorization = paste("Bearer", token),
      `Content-Type` = "application/json",
      Accept = "application/json"
    ) |>
    req_body_json(payload, auto_unbox = TRUE) |>
    req_error(is_error = function(resp) FALSE)
  resp <- req_perform(req)
  status <- resp_status(resp)
  if (status >= 400L) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Lens HTTP %d%s", status, if (nzchar(body)) paste0(": ", body) else ""), call. = FALSE)
  }
  resp_body_json(resp, simplifyVector = FALSE)
}

lookup <- function(ids) {
  quoted <- paste(sprintf('"%s"', ids), collapse = " OR ")
  include <- c(
    "lens_id", "title", "abstract", "keywords", "authors", "publication_type",
    "external_ids", "date_published", "year_published", "source",
    "source_urls", "start_page", "end_page", "volume", "issue",
    "references_count", "scholarly_citations_count"
  )
  lens_request(list(
    query = sprintf("lens_id:(%s)", quoted),
    size = 500L,
    include = include
  ))
}

write_jsonl <- function(rows, path) {
  con <- file(path, "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  for (x in rows) {
    writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
  }
}

ids <- readLines(ids_path, warn = FALSE, encoding = "UTF-8")
ids <- sort(unique(trimws(ids[nzchar(trimws(ids))])))
groups <- split(seq_along(ids), ceiling(seq_along(ids) / chunk_size))

records <- list()
for (g in seq_along(groups)) {
  requested <- ids[groups[[g]]]
  body <- lookup(requested)
  dat <- body$data %||% list()
  records <- c(records, dat)
  dir.create(file.path(output_dir, "checkpoints"), showWarnings = FALSE, recursive = TRUE)
  write_jsonl(dat, file.path(output_dir, "checkpoints", sprintf("metadata_%04d.jsonl", g)))
  writeLines(requested, file.path(output_dir, "checkpoints", sprintf("requested_%04d.txt", g)))
  message(sprintf("Candidate enrichment checkpoint %d/%d: requested=%d returned=%d",
                  g, length(groups), length(requested), length(dat)))
}

if (length(records)) {
  lids <- vapply(records, function(x) as.character(x$lens_id %||% ""), character(1))
  records <- records[!duplicated(lids)]
}
write_jsonl(records, file.path(output_dir, "candidate_lens_metadata_full.jsonl"))
returned <- if (length(records)) vapply(records, function(x) as.character(x$lens_id %||% ""), character(1)) else character()
writeLines(setdiff(ids, returned), file.path(output_dir, "candidate_ids_missing_from_lens.txt"))

summary <- list(
  schema = "living-evidence-map-citation-candidate-lens-enrichment-v1",
  candidate_ids_requested = length(ids),
  candidate_records_returned = length(records),
  candidate_ids_missing = length(setdiff(ids, returned)),
  api_calls = length(groups),
  openai_api_called = FALSE
)
write_json(summary, file.path(output_dir, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
