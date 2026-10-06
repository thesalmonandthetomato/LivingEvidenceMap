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

canonical_path <- arg("--canonical")
output_dir <- arg("--output-dir", "outputs/lens_citation_gap")
batch_size <- as.integer(arg("--batch-size", "500"))
max_batches <- as.integer(arg("--max-batches", "1"))

if (is.null(canonical_path) || !file.exists(canonical_path)) {
  stop("Canonical W08 JSONL not found: ", canonical_path, call. = FALSE)
}
if (is.na(batch_size) || batch_size < 1L || batch_size > 500L) {
  stop("--batch-size must be between 1 and 500", call. = FALSE)
}
if (is.na(max_batches) || max_batches < 0L) {
  stop("--max-batches must be >= 0 (0 means all)", call. = FALSE)
}

token <- Sys.getenv("LENS_API_TOKEN", unset = "")
if (!nzchar(token)) stop("LENS_API_TOKEN is required", call. = FALSE)

api <- "https://api.lens.org/scholarly/search"
page_size <- 500L
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
`%||%` <- function(x, y) if (is.null(x)) y else x

# Literal local equivalents of the production W00 Lens terms, applied only to
# title, abstract and keywords after citation neighbours have been retrieved.
salmon_regex <- "(?i)(\\bsalmon\\b|\\bsalmonid[A-Za-z0-9_-]*\\b|\\bSalmo\\b|\\bOncorhynchus\\b|\\brainbow\\s+trout\\b)"
farm_regex <- "(?i)(\\bfarm[A-Za-z0-9_-]*\\b|\\bcage[A-Za-z0-9_-]*\\b|\\bpens\\b|\\bpenned\\b|\\bpen\\b|\\baquacultur[A-Za-z0-9_-]*\\b|\\bcommercial[A-Za-z0-9_-]*\\b)"

extract_lens_ids <- function(path) {
  con <- file(path, open = "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  ids <- character()
  n <- 0L
  repeat {
    lines <- readLines(con, n = 1000L, warn = FALSE, encoding = "UTF-8")
    if (!length(lines)) break
    lines <- lines[nzchar(trimws(lines))]
    for (line in lines) {
      rec <- fromJSON(line, simplifyVector = FALSE)
      refs <- rec$manifestation_refs
      if (!is.null(refs) && length(refs)) {
        refs <- as.character(unlist(refs, recursive = TRUE, use.names = FALSE))
        z <- refs[startsWith(refs, "lens:")]
        if (length(z)) ids <- c(ids, sub("^lens:", "", z))
      }
      n <- n + 1L
    }
  }
  list(ids = sort(unique(ids[nzchar(ids)])), canonical_records = n)
}

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
    stop(sprintf("Lens HTTP %d%s", status,
                 if (nzchar(body)) paste0(": ", body) else ""),
         call. = FALSE)
  }
  resp_body_json(resp, simplifyVector = FALSE)
}

terms_lookup <- function(ids, include) {
  if (!length(ids)) return(list(total = 0L, data = list()))
  if (length(ids) > 500L) stop("terms_lookup received >500 IDs", call. = FALSE)

  payload <- list(
    query = list(terms = list(lens_id = unname(ids))),
    size = page_size,
    include = include
  )
  lens_request(payload)
}

as_ids <- function(x) {
  if (is.null(x) || !length(x)) return(character())
  vals <- as.character(unlist(x, recursive = TRUE, use.names = FALSE))
  vals <- trimws(vals)
  unique(vals[nzchar(vals)])
}

record_text <- function(rec) {
  kw <- rec$keywords
  if (is.list(kw)) kw <- unlist(kw, recursive = TRUE, use.names = FALSE)
  paste(
    as.character(rec$title %||% ""),
    as.character(rec$abstract %||% ""),
    paste(as.character(kw %||% character()), collapse = " "),
    sep = "\n"
  )
}

passes_gap_filter <- function(rec) {
  txt <- record_text(rec)
  grepl(salmon_regex, txt, perl = TRUE) &&
    !grepl(farm_regex, txt, perl = TRUE)
}

seed_info <- extract_lens_ids(canonical_path)
all_seed_ids <- seed_info$ids
expected <- 16716L
if (length(all_seed_ids) != expected) {
  stop(sprintf("Seed guard failed: expected %d included Lens IDs, found %d",
               expected, length(all_seed_ids)), call. = FALSE)
}

batch_index <- split(seq_along(all_seed_ids),
                     ceiling(seq_along(all_seed_ids) / batch_size))
total_batches <- length(batch_index)
if (max_batches > 0L) {
  batch_index <- batch_index[seq_len(min(max_batches, total_batches))]
}

message(sprintf("Canonical included records: %d", seed_info$canonical_records))
message(sprintf("Included Lens manifestation IDs: %d", length(all_seed_ids)))
message(sprintf("Seed batch size: %d; seed batches to run: %d of %d",
                batch_size, length(batch_index), total_batches))

forward_neighbours <- character()
backward_neighbours <- character()
seed_rows_returned <- 0L
seed_queries <- 0L

for (j in seq_along(batch_index)) {
  seed_ids <- all_seed_ids[batch_index[[j]]]
  body <- terms_lookup(
    seed_ids,
    c("lens_id", "references", "scholarly_citations")
  )
  seed_queries <- seed_queries + 1L
  dat <- body$data %||% list()
  seed_rows_returned <- seed_rows_returned + length(dat)

  message(sprintf("Seed batch %d: requested %d IDs; Lens returned %d seed records",
                  j, length(seed_ids), length(dat)))

  for (rec in dat) {
    backward_neighbours <- c(backward_neighbours, as_ids(rec$references))
    forward_neighbours <- c(forward_neighbours, as_ids(rec$scholarly_citations))
  }
}

forward_neighbours <- sort(unique(forward_neighbours))
backward_neighbours <- sort(unique(backward_neighbours))

message(sprintf("Raw unique citation neighbours from selected seed batches: forward=%d backward=%d",
                length(forward_neighbours), length(backward_neighbours)))

all_neighbours <- sort(unique(c(forward_neighbours, backward_neighbours)))
metadata_groups <- split(seq_along(all_neighbours),
                         ceiling(seq_along(all_neighbours) / 500L))

candidate_ids <- character()
metadata_queries <- 0L
metadata_records_returned <- 0L

for (k in seq_along(metadata_groups)) {
  ids <- all_neighbours[metadata_groups[[k]]]
  body <- terms_lookup(ids, c("lens_id", "title", "abstract", "keywords"))
  metadata_queries <- metadata_queries + 1L
  dat <- body$data %||% list()
  metadata_records_returned <- metadata_records_returned + length(dat)

  if (length(dat)) {
    keep <- vapply(dat, passes_gap_filter, logical(1))
    if (any(keep)) {
      candidate_ids <- c(
        candidate_ids,
        vapply(dat[keep], function(x) as.character(x$lens_id %||% ""), character(1))
      )
    }
  }
}

candidate_ids <- sort(unique(candidate_ids[nzchar(candidate_ids)]))

# Defensive removal of any already-included Lens IDs.
candidate_ids <- setdiff(candidate_ids, all_seed_ids)

forward_candidates <- sort(intersect(candidate_ids, forward_neighbours))
backward_candidates <- sort(intersect(candidate_ids, backward_neighbours))
both_candidates <- sort(intersect(forward_candidates, backward_candidates))
either_candidates <- sort(unique(c(forward_candidates, backward_candidates)))

writeLines(forward_candidates, file.path(output_dir, "forward_unique_candidate_ids.txt"))
writeLines(backward_candidates, file.path(output_dir, "backward_unique_candidate_ids.txt"))
writeLines(both_candidates, file.path(output_dir, "both_directions_candidate_ids.txt"))
writeLines(either_candidates, file.path(output_dir, "either_direction_unique_candidate_ids.txt"))

summary <- list(
  schema = "living-evidence-map-lens-citation-gap-diagnostic-v2",
  method = "citationchaser-style two-stage Lens terms lookup plus local text filter",
  canonical_records = seed_info$canonical_records,
  included_lens_manifestation_ids = length(all_seed_ids),
  seed_batch_size = batch_size,
  total_seed_batches_available = total_batches,
  seed_batches_run = length(batch_index),
  seed_queries = seed_queries,
  seed_rows_returned = seed_rows_returned,
  unique_forward_neighbour_ids = length(forward_neighbours),
  unique_backward_neighbour_ids = length(backward_neighbours),
  unique_neighbour_ids_either_direction = length(all_neighbours),
  metadata_queries = metadata_queries,
  metadata_records_returned = metadata_records_returned,
  text_scope = c("title", "abstract", "keywords"),
  salmon_terms = c("salmon", "salmonid*", "Salmo", "Oncorhynchus", "rainbow trout"),
  excluded_farming_terms = c("farm*", "cage*", "pens", "penned", "pen", "aquacultur*", "commercial*"),
  forward_unique_candidates = length(forward_candidates),
  backward_unique_candidates = length(backward_candidates),
  candidates_in_both_directions = length(both_candidates),
  either_direction_unique_candidates = length(either_candidates)
)

write_json(summary, file.path(output_dir, "summary.json"),
           auto_unbox = TRUE, pretty = TRUE, na = "null")
cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, na = "null"), "\n")
