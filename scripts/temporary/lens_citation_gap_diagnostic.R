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
scroll_ttl <- "1m"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

salmon_terms <- 'salmon OR salmonid* OR Salmo OR Oncorhynchus OR "rainbow trout"'
farm_terms <- 'farm* OR cage* OR pens OR penned OR pen OR aquacultur* OR commercial*'
positive <- sprintf("(title:(%s) OR abstract:(%s) OR keyword:(%s))",
                    salmon_terms, salmon_terms, salmon_terms)
negative <- sprintf("(title:(%s) OR abstract:(%s) OR keyword:(%s))",
                    farm_terms, farm_terms, farm_terms)
text_query <- sprintf("(%s) AND NOT (%s)", positive, negative)

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
        refs <- as.character(unlist(refs, use.names = FALSE))
        z <- refs[startsWith(refs, "lens:")]
        if (length(z)) ids <- c(ids, sub("^lens:", "", z))
      }
      n <- n + 1L
    }
  }
  ids <- unique(ids[nzchar(ids)])
  list(ids = ids, canonical_records = n)
}

lens_request <- function(payload) {
  last_error <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(api) |>
      req_headers(
        Authorization = paste("Bearer", token),
        `Content-Type` = "application/json",
        Accept = "application/json"
      ) |>
      req_body_json(payload, auto_unbox = TRUE) |>
      req_error(is_error = function(resp) FALSE)
    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, "error")) {
      status <- resp_status(resp)
      if (status < 400L) return(resp_body_json(resp, simplifyVector = FALSE))
      retryable <- status == 429L || status >= 500L
      last_error <- sprintf("Lens HTTP %s", status)
      if (!retryable) stop(last_error, call. = FALSE)
    } else {
      last_error <- conditionMessage(resp)
    }
    if (attempt < 6L) {
      delay <- min(60, 2^(attempt - 1L))
      message(sprintf("Lens request attempt %d failed (%s); retrying in %ss",
                      attempt, last_error, delay))
      Sys.sleep(delay)
    }
  }
  stop(sprintf("Lens request failed after 6 attempts: %s", last_error), call. = FALSE)
}

run_batch <- function(seed_ids, field, direction, batch_number) {
  id_clause <- paste(seed_ids, collapse = " OR ")
  citation_clause <- sprintf("%s:(%s)", field, id_clause)
  full_query <- sprintf("(%s) AND (%s) AND NOT (%s)",
                        citation_clause, positive, negative)

  payload <- list(
    query = list(
      query_string = list(query = full_query)
    ),
    stemming = FALSE,
    size = page_size,
    scroll = scroll_ttl,
    include = c("lens_id")
  )

  ids <- character()
  raw_retrieved <- 0L
  reported_total <- NULL
  pages <- 0L

  repeat {
    body <- lens_request(payload)
    pages <- pages + 1L
    if (is.null(reported_total)) {
      reported_total <- as.integer(body$total %||% 0L)
      message(sprintf("%s batch %d: Lens reported %d matching works",
                      direction, batch_number, reported_total))
    }
    dat <- body$data %||% list()
    raw_retrieved <- raw_retrieved + length(dat)
    if (length(dat)) {
      batch_ids <- vapply(dat, function(x) as.character(x$lens_id %||% ""), character(1))
      ids <- c(ids, batch_ids[nzchar(batch_ids)])
    }
    if (!length(dat) || raw_retrieved >= reported_total) break
    scroll_id <- as.character(body$scroll_id %||% "")
    if (!nzchar(scroll_id)) {
      stop(sprintf("%s batch %d: missing scroll_id before all results were retrieved",
                   direction, batch_number), call. = FALSE)
    }
    payload <- list(scroll_id = scroll_id, scroll = scroll_ttl, include = c("lens_id"))
  }

  ids <- unique(ids)

  list(
    direction = direction,
    batch = batch_number,
    seed_count = length(seed_ids),
    field = field,
    reported_total = reported_total,
    raw_retrieved = raw_retrieved,
    unique_ids_retrieved = length(ids),
    pages = pages,
    ids = ids
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

seed_info <- extract_lens_ids(canonical_path)
all_seed_ids <- sort(seed_info$ids)
if (!length(all_seed_ids)) stop("No Lens IDs found in W08 manifestation_refs", call. = FALSE)

expected <- 16716L
if (length(all_seed_ids) != expected) {
  stop(sprintf("Seed guard failed: expected %d included Lens IDs, found %d",
               expected, length(all_seed_ids)), call. = FALSE)
}

batch_index <- split(seq_along(all_seed_ids),
                     ceiling(seq_along(all_seed_ids) / batch_size))
if (max_batches > 0L) {
  batch_index <- batch_index[seq_len(min(max_batches, length(batch_index)))]
}

message(sprintf("Canonical included records: %d", seed_info$canonical_records))
message(sprintf("Included Lens IDs: %d", length(all_seed_ids)))
message(sprintf("Batch size: %d; batches to run: %d of %d",
                batch_size, length(batch_index), ceiling(length(all_seed_ids) / batch_size)))

directions <- list(
  forward = "reference.lens_id",
  backward = "referenced_by"
)

results <- list()
for (direction in names(directions)) {
  field <- directions[[direction]]
  for (j in seq_along(batch_index)) {
    idx <- batch_index[[j]]
    z <- run_batch(all_seed_ids[idx], field, direction, j)
    results[[length(results) + 1L]] <- z
    writeLines(z$ids,
               file.path(output_dir, sprintf("%s_batch_%02d_ids.txt", direction, j)))
    write_json(
      z[setdiff(names(z), "ids")],
      file.path(output_dir, sprintf("%s_batch_%02d_summary.json", direction, j)),
      auto_unbox = TRUE, pretty = TRUE, na = "null"
    )
  }
}

forward_ids_raw <- unique(unlist(lapply(results[vapply(results, function(x) x$direction == "forward", logical(1))],
                                        function(x) x$ids), use.names = FALSE))
backward_ids_raw <- unique(unlist(lapply(results[vapply(results, function(x) x$direction == "backward", logical(1))],
                                         function(x) x$ids), use.names = FALSE))

forward_overlap <- intersect(forward_ids_raw, all_seed_ids)
backward_overlap <- intersect(backward_ids_raw, all_seed_ids)
forward_ids <- setdiff(forward_ids_raw, all_seed_ids)
backward_ids <- setdiff(backward_ids_raw, all_seed_ids)
both_ids <- intersect(forward_ids, backward_ids)
either_ids <- union(forward_ids, backward_ids)

writeLines(sort(forward_ids), file.path(output_dir, "forward_unique_candidate_ids.txt"))
writeLines(sort(backward_ids), file.path(output_dir, "backward_unique_candidate_ids.txt"))
writeLines(sort(both_ids), file.path(output_dir, "both_directions_candidate_ids.txt"))
writeLines(sort(either_ids), file.path(output_dir, "either_direction_unique_candidate_ids.txt"))

batch_rows <- lapply(results, function(x) {
  data.frame(
    direction = x$direction,
    batch = x$batch,
    seed_count = x$seed_count,
    query_field = x$field,
    reported_total = x$reported_total,
    raw_retrieved = x$raw_retrieved,
    unique_ids_retrieved = x$unique_ids_retrieved,
    pages = x$pages,
    stringsAsFactors = FALSE
  )
})
write.csv(do.call(rbind, batch_rows),
          file.path(output_dir, "batch_summary.csv"), row.names = FALSE)

summary <- list(
  schema = "living-evidence-map-lens-citation-gap-diagnostic-v1",
  canonical_records = seed_info$canonical_records,
  included_lens_ids = length(all_seed_ids),
  batch_size = batch_size,
  total_possible_batches_per_direction = ceiling(length(all_seed_ids) / batch_size),
  batches_run_per_direction = length(batch_index),
  primary_queries_run = length(results),
  text_scope = c("title", "abstract", "keyword"),
  salmon_terms = salmon_terms,
  excluded_farming_terms = farm_terms,
  query_string = text_query,
  forward_query_field = "reference.lens_id",
  backward_query_field = "referenced_by",
  forward_unique_before_included_id_safeguard = length(forward_ids_raw),
  backward_unique_before_included_id_safeguard = length(backward_ids_raw),
  forward_included_ids_removed = length(forward_overlap),
  backward_included_ids_removed = length(backward_overlap),
  forward_unique_candidates = length(forward_ids),
  backward_unique_candidates = length(backward_ids),
  candidates_in_both_directions = length(both_ids),
  either_direction_unique_candidates = length(either_ids)
)
write_json(summary, file.path(output_dir, "summary.json"),
           auto_unbox = TRUE, pretty = TRUE, na = "null")
cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, na = "null"), "\n")
