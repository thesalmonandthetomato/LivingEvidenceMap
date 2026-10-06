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

stage <- arg("--stage")
canonical_path <- arg("--canonical")
output_dir <- arg("--output-dir")
checkpoint_root <- arg("--checkpoint-root")
batch_number <- as.integer(arg("--batch-number", "1"))
batch_size <- as.integer(arg("--batch-size", "500"))
chunk_number <- as.integer(arg("--chunk-number", "1"))
chunk_size <- as.integer(arg("--chunk-size", "5000"))

if (is.null(stage)) stop("--stage is required", call. = FALSE)
if (is.null(output_dir)) stop("--output-dir is required", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

api <- "https://api.lens.org/scholarly/search"
page_size <- 500L
token <- Sys.getenv("LENS_API_TOKEN", unset = "")

extract_lens_ids <- function(path) {
  if (is.null(path) || !file.exists(path)) stop("Canonical W08 JSONL not found", call. = FALSE)
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
  if (!nzchar(token)) stop("LENS_API_TOKEN is required for this stage", call. = FALSE)
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

id_lookup <- function(ids, include) {
  if (!length(ids)) return(list(total = 0L, data = list()))
  if (length(ids) > 500L) stop("id_lookup received >500 IDs", call. = FALSE)
  quoted <- paste(sprintf('"%s"', ids), collapse = " OR ")
  payload <- list(
    query = sprintf("lens_id:(%s)", quoted),
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

reference_lens_ids <- function(x) {
  if (is.null(x) || !length(x)) return(character())
  vals <- vapply(x, function(ref) {
    if (is.list(ref)) as.character(ref$lens_id %||% "") else as.character(ref)
  }, character(1))
  vals <- trimws(vals)
  unique(vals[nzchar(vals)])
}

write_jsonl <- function(records, path) {
  con <- file(path, open = "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  if (length(records)) {
    for (rec in records) {
      writeLines(toJSON(rec, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
    }
  }
}

read_all_lines <- function(pattern) {
  files <- list.files(checkpoint_root, pattern = pattern, recursive = TRUE, full.names = TRUE)
  vals <- unlist(lapply(files, function(f) readLines(f, warn = FALSE, encoding = "UTF-8")),
                 use.names = FALSE)
  sort(unique(trimws(vals[nzchar(trimws(vals))])))
}

salmon_regex <- "(?i)(\\bsalmon\\b|\\bsalmonid[A-Za-z0-9_-]*\\b|\\bSalmo\\b|\\bOncorhynchus\\b|\\brainbow\\s+trout\\b)"
farm_regex <- "(?i)(\\bfarm[A-Za-z0-9_-]*\\b|\\bcage[A-Za-z0-9_-]*\\b|\\bpens\\b|\\bpenned\\b|\\bpen\\b|\\baquacultur[A-Za-z0-9_-]*\\b|\\bcommercial[A-Za-z0-9_-]*\\b)"

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

if (stage == "seed") {
  seed_info <- extract_lens_ids(canonical_path)
  all_seed_ids <- seed_info$ids
  if (length(all_seed_ids) != 16716L) {
    stop(sprintf("Seed guard failed: expected 16716 Lens IDs, found %d", length(all_seed_ids)),
         call. = FALSE)
  }

  total_batches <- ceiling(length(all_seed_ids) / batch_size)
  if (batch_number < 1L || batch_number > total_batches) {
    stop(sprintf("Batch %d outside 1..%d", batch_number, total_batches), call. = FALSE)
  }

  start <- (batch_number - 1L) * batch_size + 1L
  end <- min(batch_number * batch_size, length(all_seed_ids))
  seed_ids <- all_seed_ids[start:end]

  body <- id_lookup(seed_ids, c(
    "lens_id", "title", "external_ids",
    "references", "scholarly_citations"
  ))
  dat <- body$data %||% list()

  returned_ids <- vapply(dat, function(x) as.character(x$lens_id %||% ""), character(1))
  returned_ids <- returned_ids[nzchar(returned_ids)]
  missing_ids <- setdiff(seed_ids, returned_ids)

  forward <- character()
  backward <- character()
  for (rec in dat) {
    forward <- c(forward, as_ids(rec$scholarly_citations))
    backward <- c(backward, reference_lens_ids(rec$references))
  }
  forward <- sort(unique(forward))
  backward <- sort(unique(backward))

  writeLines(seed_ids, file.path(output_dir, "seed_ids_requested.txt"))
  writeLines(sort(returned_ids), file.path(output_dir, "seed_ids_returned.txt"))
  writeLines(sort(missing_ids), file.path(output_dir, "seed_ids_missing.txt"))
  writeLines(forward, file.path(output_dir, "forward_neighbour_ids.txt"))
  writeLines(backward, file.path(output_dir, "backward_neighbour_ids.txt"))
  write_jsonl(dat, file.path(output_dir, "seed_records.jsonl"))

  summary <- list(
    schema = "lens-citation-seed-checkpoint-v1",
    batch_number = batch_number,
    total_batches = total_batches,
    requested_seed_ids = length(seed_ids),
    returned_seed_records = length(dat),
    missing_seed_ids = length(missing_ids),
    unique_forward_neighbour_ids = length(forward),
    unique_backward_neighbour_ids = length(backward),
    unique_neighbour_ids_either = length(unique(c(forward, backward)))
  )
  write_json(summary, file.path(output_dir, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "prepare") {
  if (is.null(checkpoint_root) || !dir.exists(checkpoint_root)) {
    stop("--checkpoint-root must contain downloaded seed artifacts", call. = FALSE)
  }
  forward <- read_all_lines("forward_neighbour_ids\\.txt$")
  backward <- read_all_lines("backward_neighbour_ids\\.txt$")
  all_ids <- sort(unique(c(forward, backward)))

  dir.create(file.path(output_dir, "chunks"), recursive = TRUE, showWarnings = FALSE)
  n_chunks <- ceiling(length(all_ids) / chunk_size)
  if (length(all_ids)) {
    for (k in seq_len(n_chunks)) {
      s <- (k - 1L) * chunk_size + 1L
      e <- min(k * chunk_size, length(all_ids))
      writeLines(all_ids[s:e], file.path(output_dir, "chunks", sprintf("chunk_%03d.txt", k)))
    }
  }

  writeLines(forward, file.path(output_dir, "all_forward_neighbour_ids.txt"))
  writeLines(backward, file.path(output_dir, "all_backward_neighbour_ids.txt"))
  writeLines(all_ids, file.path(output_dir, "all_unique_neighbour_ids.txt"))

  matrix <- if (n_chunks > 0L) seq_len(n_chunks) else integer()
  writeLines(toJSON(matrix, auto_unbox = FALSE), file.path(output_dir, "matrix.json"))

  summary <- list(
    schema = "lens-citation-neighbour-index-v1",
    unique_forward_neighbours = length(forward),
    unique_backward_neighbours = length(backward),
    unique_neighbours_either = length(all_ids),
    metadata_chunk_size = chunk_size,
    metadata_chunks = n_chunks
  )
  write_json(summary, file.path(output_dir, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "metadata") {
  if (is.null(checkpoint_root) || !dir.exists(checkpoint_root)) {
    stop("--checkpoint-root must contain the neighbour index artifact", call. = FALSE)
  }
  chunk_file <- list.files(checkpoint_root,
                           pattern = sprintf("chunk_%03d\\.txt$", chunk_number),
                           recursive = TRUE, full.names = TRUE)
  if (length(chunk_file) != 1L) {
    stop(sprintf("Expected exactly one chunk file for chunk %d, found %d",
                 chunk_number, length(chunk_file)), call. = FALSE)
  }
  ids <- readLines(chunk_file, warn = FALSE, encoding = "UTF-8")
  ids <- ids[nzchar(trimws(ids))]

  groups <- split(seq_along(ids), ceiling(seq_along(ids) / 500L))
  records <- list()
  for (g in seq_along(groups)) {
    body <- id_lookup(ids[groups[[g]]], c("lens_id", "title", "abstract", "keywords", "external_ids"))
    dat <- body$data %||% list()
    records <- c(records, dat)
    message(sprintf("Metadata chunk %d request %d/%d: returned %d",
                    chunk_number, g, length(groups), length(dat)))
  }

  if (length(records)) {
    lids <- vapply(records, function(x) as.character(x$lens_id %||% ""), character(1))
    records <- records[!duplicated(lids)]
  }
  keep <- if (length(records)) vapply(records, passes_gap_filter, logical(1)) else logical()
  candidates <- records[keep]

  write_jsonl(records, file.path(output_dir, "all_metadata_records.jsonl"))
  write_jsonl(candidates, file.path(output_dir, "candidate_records.jsonl"))
  writeLines(vapply(candidates, function(x) as.character(x$lens_id %||% ""), character(1)),
             file.path(output_dir, "candidate_ids.txt"))

  summary <- list(
    schema = "lens-citation-metadata-checkpoint-v1",
    chunk_number = chunk_number,
    ids_requested = length(ids),
    metadata_records_returned = length(records),
    candidate_records = length(candidates)
  )
  write_json(summary, file.path(output_dir, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "finalise") {
  if (is.null(checkpoint_root) || !dir.exists(checkpoint_root)) {
    stop("--checkpoint-root must contain downloaded seed/index/metadata artifacts", call. = FALSE)
  }

  seed_info <- extract_lens_ids(canonical_path)
  included_ids <- seed_info$ids
  forward <- read_all_lines("all_forward_neighbour_ids\\.txt$")
  backward <- read_all_lines("all_backward_neighbour_ids\\.txt$")
  candidate_ids <- read_all_lines("candidate_ids\\.txt$")
  candidate_ids <- setdiff(candidate_ids, included_ids)

  forward_candidates <- sort(intersect(candidate_ids, forward))
  backward_candidates <- sort(intersect(candidate_ids, backward))
  both <- sort(intersect(forward_candidates, backward_candidates))
  either <- sort(unique(c(forward_candidates, backward_candidates)))

  writeLines(forward_candidates, file.path(output_dir, "forward_unique_candidate_ids.txt"))
  writeLines(backward_candidates, file.path(output_dir, "backward_unique_candidate_ids.txt"))
  writeLines(both, file.path(output_dir, "both_directions_candidate_ids.txt"))
  writeLines(either, file.path(output_dir, "either_direction_unique_candidate_ids.txt"))

  # Preserve complete candidate metadata in one final JSONL, deduplicated by Lens ID.
  metadata_files <- list.files(checkpoint_root, pattern = "candidate_records\\.jsonl$",
                               recursive = TRUE, full.names = TRUE)
  by_id <- new.env(hash = TRUE, parent = emptyenv())
  ordered_ids <- character()
  for (f in metadata_files) {
    lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
    for (line in lines[nzchar(trimws(lines))]) {
      rec <- fromJSON(line, simplifyVector = FALSE)
      lid <- as.character(rec$lens_id %||% "")
      if (!nzchar(lid) || !(lid %in% either)) next
      if (!exists(lid, envir = by_id, inherits = FALSE)) {
        assign(lid, rec, envir = by_id)
        ordered_ids <- c(ordered_ids, lid)
      }
    }
  }
  final_records <- lapply(sort(unique(ordered_ids)), function(id) get(id, envir = by_id, inherits = FALSE))
  write_jsonl(final_records, file.path(output_dir, "candidate_records_deduplicated.jsonl"))

  summary <- list(
    schema = "lens-citation-gap-full-run-v1",
    canonical_records = seed_info$canonical_records,
    included_lens_manifestation_ids = length(included_ids),
    text_scope = c("title", "abstract", "keywords"),
    salmon_terms = c("salmon", "salmonid*", "Salmo", "Oncorhynchus", "rainbow trout"),
    excluded_farming_terms = c("farm*", "cage*", "pens", "penned", "pen", "aquacultur*", "commercial*"),
    forward_unique_candidates = length(forward_candidates),
    backward_unique_candidates = length(backward_candidates),
    candidates_in_both_directions = length(both),
    either_direction_unique_candidates = length(either),
    candidate_metadata_records_written = length(final_records)
  )
  write_json(summary, file.path(output_dir, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

stop("Unknown --stage: ", stage, call. = FALSE)
