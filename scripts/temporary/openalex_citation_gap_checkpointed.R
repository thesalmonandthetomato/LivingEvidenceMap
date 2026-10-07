#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
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
seed_root <- arg("--seed-root")
metadata_root <- arg("--metadata-root")
lens_candidates_path <- arg("--lens-candidates")
output_dir <- arg("--output-dir")
seed_limit_arg <- arg("--seed-limit", "20")
seed_chunk_number <- as.integer(arg("--seed-chunk-number", "1"))
seed_chunk_size <- as.integer(arg("--seed-chunk-size", "100"))
metadata_chunk_number <- as.integer(arg("--metadata-chunk-number", "1"))
metadata_chunk_size <- as.integer(arg("--metadata-chunk-size", "5000"))
forward_seed_group_size <- as.integer(arg("--forward-seed-group-size", "50"))

if (is.null(stage) || !nzchar(stage)) stop("--stage is required", call. = FALSE)
if (is.null(output_dir) || !nzchar(output_dir)) stop("--output-dir is required", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

api_key <- Sys.getenv("OPENALEX_API_KEY", unset = "")
if (!nzchar(api_key)) api_key <- Sys.getenv("OPENALEX_API_TOKEN", unset = "")
api_base <- "https://api.openalex.org"

scalar <- function(x) {
  if (is.null(x) || !length(x)) return("")
  z <- as.character(x[[1L]])
  if (is.na(z)) "" else trimws(z)
}
normalise_oa_id <- function(x) {
  z <- trimws(as.character(x))
  z <- sub("^https?://openalex\\.org/", "", z, ignore.case = TRUE)
  z <- sub("^openalex:", "", z, ignore.case = TRUE)
  z
}
normalise_doi <- function(x) {
  z <- tolower(trimws(as.character(x)))
  z <- sub("^https?://(dx\\.)?doi\\.org/", "", z)
  z <- sub("^doi:", "", z)
  z
}
normalise_title <- function(x) {
  z <- tolower(trimws(as.character(x)))
  z <- gsub("[^[:alnum:]]+", " ", z)
  gsub("\\s+", " ", z)
}
write_json_pretty <- function(x, path) {
  writeLines(toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA),
             path, useBytes = TRUE)
}
write_jsonl <- function(rows, path) {
  con <- file(path, "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  if (length(rows)) for (x in rows) {
    writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
  }
}
read_jsonl <- function(path) {
  if (is.null(path) || !file.exists(path)) return(list())
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines, function(z) fromJSON(z, simplifyVector = FALSE))
}
read_all_lines <- function(root, pattern) {
  fs <- list.files(root, pattern = pattern, recursive = TRUE, full.names = TRUE)
  if (!length(fs)) return(character())
  sort(unique(trimws(unlist(lapply(fs, readLines, warn = FALSE, encoding = "UTF-8"),
                            use.names = FALSE))))
}
canonical_manifestation_refs <- function(rec) {
  x <- rec$manifestation_refs
  if (is.null(x) || !length(x)) return(character())
  trimws(as.character(unlist(x, recursive = TRUE, use.names = FALSE)))
}
canonical_identity <- function(rec) scalar((rec$identity %||% list())$record_id)

oa_request <- function(path = "/works", query = list()) {
  if (!nzchar(api_key)) stop("OPENALEX_API_KEY or OPENALEX_API_TOKEN is required", call. = FALSE)
  last <- NULL
  for (attempt in seq_len(6L)) {
    req <- request(paste0(api_base, path)) |>
      req_headers(
        Accept = "application/json",
        Authorization = paste("Bearer", api_key),
        `User-Agent` = "LivingEvidenceMap citation-gap chase"
      )
    if (length(query)) req <- do.call(req_url_query, c(list(req), query))
    req <- req_error(req, is_error = function(resp) FALSE)
    resp <- tryCatch(req_perform(req), error = identity)
    if (!inherits(resp, "error")) {
      st <- resp_status(resp)
      if (st < 400L) return(resp_body_json(resp, simplifyVector = FALSE))
      body <- tryCatch(resp_body_string(resp), error = function(e) "")
      last <- sprintf("OpenAlex HTTP %d: %s", st, substr(body, 1L, 1000L))
      if (!(st == 429L || st >= 500L)) stop(last, call. = FALSE)
    } else last <- conditionMessage(resp)
    if (attempt < 6L) Sys.sleep(min(30, 2^(attempt - 1L)))
  }
  stop("OpenAlex request failed after retries: ", last, call. = FALSE)
}

work_select <- paste(c(
  "id","display_name","doi","publication_year","publication_date","type",
  "authorships","primary_location","keywords","abstract_inverted_index",
  "referenced_works","cited_by_count","ids"
), collapse = ",")

fetch_works_by_ids <- function(ids) {
  ids <- sort(unique(normalise_oa_id(ids)))
  ids <- ids[nzchar(ids)]
  if (!length(ids)) return(list(records = list(), cost_usd = 0))
  groups <- split(ids, ceiling(seq_along(ids) / 100L))
  out <- list(); cost <- 0
  for (g in seq_along(groups)) {
    body <- oa_request("/works", list(
      filter = paste0("openalex:", paste(groups[[g]], collapse = "|")),
      `per-page` = 100,
      select = work_select
    ))
    out <- c(out, body$results %||% list())
    cost <- cost + suppressWarnings(as.numeric(body$meta$cost_usd %||% 0))
  }
  list(records = out, cost_usd = cost)
}

query_forward <- function(seed_ids) {
  seed_ids <- sort(unique(normalise_oa_id(seed_ids)))
  seed_ids <- seed_ids[nzchar(seed_ids)]
  if (!length(seed_ids)) return(list(records = list(), cost_usd = 0))
  cursor <- "*"; out <- list(); cost <- 0
  repeat {
    body <- oa_request("/works", list(
      filter = paste0("cites:", paste(seed_ids, collapse = "|")),
      `per-page` = 100,
      cursor = cursor,
      select = "id,referenced_works"
    ))
    out <- c(out, body$results %||% list())
    cost <- cost + suppressWarnings(as.numeric(body$meta$cost_usd %||% 0))
    nxt <- scalar(body$meta$next_cursor)
    if (!nzchar(nxt) || !length(body$results %||% list())) break
    cursor <- nxt
  }
  list(records = out, cost_usd = cost)
}

reconstruct_abstract <- function(inv) {
  if (is.null(inv) || !length(inv)) return("")
  pairs <- list()
  for (word in names(inv)) {
    pos <- suppressWarnings(as.integer(unlist(inv[[word]], use.names = FALSE)))
    pos <- pos[!is.na(pos)]
    if (length(pos)) for (p in pos) pairs[[length(pairs) + 1L]] <- c(p, word)
  }
  if (!length(pairs)) return("")
  ord <- order(vapply(pairs, function(x) as.integer(x[[1L]]), integer(1)))
  paste(vapply(pairs[ord], function(x) as.character(x[[2L]]), character(1)), collapse = " ")
}
keyword_text <- function(rec) {
  k <- rec$keywords
  if (is.null(k) || !length(k)) return("")
  vals <- vapply(k, function(x) {
    if (is.list(x)) {
      z <- scalar(x$display_name)
      if (!nzchar(z)) z <- scalar(x$keyword)
      z
    } else scalar(x)
  }, character(1))
  paste(vals[nzchar(vals)], collapse = " ")
}
salmon_regex <- "(?i)(\\bsalmon\\b|\\bSalmo\\b|\\bOncorhynchus\\b|\\brainbow\\s+trout\\b)"
farm_regex <- "(?i)(\\bfarm[A-Za-z0-9_-]*\\b|\\bcage[A-Za-z0-9_-]*\\b|\\bpens\\b|\\bpenned\\b|\\bpen\\b|\\baquacultur[A-Za-z0-9_-]*\\b|\\bcommercial[A-Za-z0-9_-]*\\b)"
record_text <- function(rec) paste(
  scalar(rec$display_name),
  reconstruct_abstract(rec$abstract_inverted_index),
  keyword_text(rec),
  sep = "\n"
)
passes_gap_filter <- function(rec) {
  txt <- record_text(rec)
  grepl(salmon_regex, txt, perl = TRUE) && !grepl(farm_regex, txt, perl = TRUE)
}

extract_external_ids_lens <- function(rec) {
  ans <- character()
  ids <- rec$external_ids
  if (is.null(ids) || !length(ids)) return(ans)
  for (x in ids) {
    if (!is.list(x)) next
    typ <- tolower(scalar(x$type)); val <- scalar(x$value)
    if (!nzchar(typ) || !nzchar(val)) next
    if (typ == "doi") val <- normalise_doi(val)
    ans[paste0(typ, ":", val)] <- val
  }
  ans
}
extract_external_ids_oa <- function(rec) {
  ans <- character()
  doi <- normalise_doi(scalar(rec$doi))
  if (nzchar(doi)) ans[paste0("doi:", doi)] <- doi
  ids <- rec$ids
  if (is.list(ids)) {
    for (typ in c("doi","pmid","pmcid")) {
      val <- scalar(ids[[typ]])
      if (!nzchar(val)) next
      if (typ == "doi") val <- normalise_doi(val)
      val <- sub("^https?://[^/]+/", "", val)
      ans[paste0(typ, ":", tolower(val))] <- tolower(val)
    }
  }
  ans
}

if (stage == "seed-index") {
  if (is.null(canonical_path) || !file.exists(canonical_path)) stop("--canonical is required", call. = FALSE)
  recs <- read_jsonl(canonical_path)
  rows <- list()
  for (rec in recs) {
    cid <- canonical_identity(rec)
    if (!nzchar(cid)) next
    refs <- canonical_manifestation_refs(rec)
    oa <- normalise_oa_id(sub("^openalex:", "", refs[grepl("^openalex:", refs, ignore.case = TRUE)], ignore.case = TRUE))
    lens <- refs[grepl("^lens:", refs, ignore.case = TRUE)]
    oa <- unique(oa[nzchar(oa)])
    if (length(oa) && !length(lens)) for (oid in oa) {
      rows[[length(rows) + 1L]] <- data.frame(
        seed_canonical_id = cid, seed_openalex_id = oid, stringsAsFactors = FALSE
      )
    }
  }
  mapping_all <- if (length(rows)) unique(do.call(rbind, rows)) else data.frame()
  if (!nrow(mapping_all)) stop("No OpenAlex-only canonical records found", call. = FALSE)
  mapping_all <- mapping_all[order(mapping_all$seed_canonical_id, mapping_all$seed_openalex_id), , drop = FALSE]
  canonical_ids_all <- unique(mapping_all$seed_canonical_id)
  if (tolower(seed_limit_arg) == "all") {
    selected_cids <- canonical_ids_all
  } else {
    lim <- as.integer(seed_limit_arg)
    if (is.na(lim) || lim < 1L) stop("--seed-limit must be >=1 or all", call. = FALSE)
    selected_cids <- head(canonical_ids_all, lim)
  }
  mapping <- mapping_all[mapping_all$seed_canonical_id %in% selected_cids, , drop = FALSE]
  write.csv(mapping_all, file.path(output_dir, "openalex_only_seed_mapping_all.csv"), row.names = FALSE)
  write.csv(mapping, file.path(output_dir, "openalex_only_seed_mapping_selected.csv"), row.names = FALSE)
  writeLines(sort(unique(mapping$seed_openalex_id)), file.path(output_dir, "seed_openalex_ids.txt"))
  n_chunks <- ceiling(nrow(mapping) / seed_chunk_size)
  matrix <- if (n_chunks) seq_len(n_chunks) else integer()
  writeLines(toJSON(matrix, auto_unbox = FALSE), file.path(output_dir, "matrix.json"))
  summary <- list(
    schema = "openalex-only-citation-seed-index-v1",
    canonical_records_total = length(recs),
    openalex_only_canonical_records = length(canonical_ids_all),
    openalex_only_manifestation_ids = length(unique(mapping_all$seed_openalex_id)),
    selected_canonical_records = length(unique(mapping$seed_canonical_id)),
    selected_manifestation_ids = length(unique(mapping$seed_openalex_id)),
    seed_limit = seed_limit_arg,
    seed_chunk_size = seed_chunk_size,
    seed_chunks = n_chunks,
    selection_rule = "canonical record has >=1 OpenAlex manifestation and zero Lens manifestations"
  )
  write_json_pretty(summary, file.path(output_dir, "summary.json"))
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "chase") {
  if (is.null(seed_root) || !dir.exists(seed_root)) stop("--seed-root is required", call. = FALSE)
  mf <- list.files(seed_root, pattern = "openalex_only_seed_mapping_selected\\.csv$", recursive = TRUE, full.names = TRUE)
  if (length(mf) != 1L) stop("Expected one selected seed mapping", call. = FALSE)
  m <- read.csv(mf, stringsAsFactors = FALSE)
  s <- (seed_chunk_number - 1L) * seed_chunk_size + 1L
  e <- min(seed_chunk_number * seed_chunk_size, nrow(m))
  if (s > nrow(m)) stop("Seed chunk out of range", call. = FALSE)
  z <- m[s:e, , drop = FALSE]
  seed_ids <- sort(unique(z$seed_openalex_id))
  seed_to_canonical <- setNames(z$seed_canonical_id, z$seed_openalex_id)

  fetched <- fetch_works_by_ids(seed_ids)
  seed_records <- fetched$records
  edges <- list()
  backward_ids <- character()
  for (rec in seed_records) {
    sid <- normalise_oa_id(scalar(rec$id))
    cid <- seed_to_canonical[[sid]] %||% ""
    refs <- normalise_oa_id(as.character(unlist(rec$referenced_works %||% character(), use.names = FALSE)))
    refs <- unique(refs[nzchar(refs)])
    backward_ids <- c(backward_ids, refs)
    if (length(refs)) for (cand in refs) edges[[length(edges) + 1L]] <- data.frame(
      seed_canonical_id = cid, seed_openalex_id = sid,
      candidate_openalex_id = cand, direction = "seed_cites_candidate",
      stringsAsFactors = FALSE
    )
  }

  forward_ids <- character(); forward_cost <- 0
  groups <- split(seed_ids, ceiling(seq_along(seed_ids) / forward_seed_group_size))
  for (g in seq_along(groups)) {
    f <- query_forward(groups[[g]])
    forward_cost <- forward_cost + f$cost_usd
    group_seed <- groups[[g]]
    for (rec in f$records) {
      cand <- normalise_oa_id(scalar(rec$id))
      refs <- normalise_oa_id(as.character(unlist(rec$referenced_works %||% character(), use.names = FALSE)))
      hits <- intersect(group_seed, refs)
      if (length(hits)) {
        forward_ids <- c(forward_ids, cand)
        for (sid in hits) edges[[length(edges) + 1L]] <- data.frame(
          seed_canonical_id = seed_to_canonical[[sid]] %||% "",
          seed_openalex_id = sid,
          candidate_openalex_id = cand,
          direction = "candidate_cites_seed",
          stringsAsFactors = FALSE
        )
      }
    }
  }
  E <- if (length(edges)) unique(do.call(rbind, edges)) else data.frame(
    seed_canonical_id=character(),seed_openalex_id=character(),
    candidate_openalex_id=character(),direction=character()
  )
  write.csv(E, file.path(output_dir, "citation_edges.csv"), row.names = FALSE)
  writeLines(sort(unique(backward_ids)), file.path(output_dir, "backward_neighbour_ids.txt"))
  writeLines(sort(unique(forward_ids)), file.path(output_dir, "forward_neighbour_ids.txt"))
  write_jsonl(seed_records, file.path(output_dir, "seed_records.jsonl"))
  summary <- list(
    schema = "openalex-only-citation-chase-checkpoint-v1",
    seed_chunk_number = seed_chunk_number,
    seed_manifestations = length(seed_ids),
    seed_records_returned = length(seed_records),
    backward_neighbours = length(unique(backward_ids)),
    forward_neighbours = length(unique(forward_ids)),
    unique_neighbours = length(unique(c(backward_ids, forward_ids))),
    citation_edges = nrow(E),
    openalex_cost_usd = fetched$cost_usd + forward_cost
  )
  write_json_pretty(summary, file.path(output_dir, "summary.json"))
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "prepare") {
  if (is.null(seed_root) || !dir.exists(seed_root)) stop("--seed-root is required", call. = FALSE)
  edge_files <- list.files(seed_root, pattern = "citation_edges\\.csv$", recursive = TRUE, full.names = TRUE)
  if (!length(edge_files)) stop("No citation edge checkpoints found", call. = FALSE)
  E <- unique(do.call(rbind, lapply(edge_files, read.csv, stringsAsFactors = FALSE)))
  all_ids <- sort(unique(E$candidate_openalex_id))
  dir.create(file.path(output_dir, "chunks"), recursive = TRUE, showWarnings = FALSE)
  n_chunks <- ceiling(length(all_ids) / metadata_chunk_size)
  if (n_chunks) for (k in seq_len(n_chunks)) {
    s <- (k - 1L) * metadata_chunk_size + 1L
    e <- min(k * metadata_chunk_size, length(all_ids))
    writeLines(all_ids[s:e], file.path(output_dir, "chunks", sprintf("chunk_%03d.txt", k)))
  }
  write.csv(E, file.path(output_dir, "citation_edges_all.csv"), row.names = FALSE)
  writeLines(all_ids, file.path(output_dir, "all_unique_neighbour_ids.txt"))
  writeLines(toJSON(if (n_chunks) seq_len(n_chunks) else integer(), auto_unbox = FALSE),
             file.path(output_dir, "matrix.json"))
  summary <- list(
    schema = "openalex-only-citation-neighbour-index-v1",
    citation_edges = nrow(E),
    unique_forward_neighbours = length(unique(E$candidate_openalex_id[E$direction == "candidate_cites_seed"])),
    unique_backward_neighbours = length(unique(E$candidate_openalex_id[E$direction == "seed_cites_candidate"])),
    unique_neighbours_either = length(all_ids),
    metadata_chunk_size = metadata_chunk_size,
    metadata_chunks = n_chunks
  )
  write_json_pretty(summary, file.path(output_dir, "summary.json"))
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "metadata") {
  if (is.null(metadata_root) || !dir.exists(metadata_root)) stop("--metadata-root is required", call. = FALSE)
  cf <- list.files(metadata_root, pattern = sprintf("chunk_%03d\\.txt$", metadata_chunk_number),
                   recursive = TRUE, full.names = TRUE)
  if (length(cf) != 1L) stop("Expected exactly one metadata chunk file", call. = FALSE)
  ids <- readLines(cf, warn = FALSE, encoding = "UTF-8")
  f <- fetch_works_by_ids(ids)
  records <- f$records
  keep <- if (length(records)) vapply(records, passes_gap_filter, logical(1)) else logical()
  candidates <- records[keep]
  write_jsonl(records, file.path(output_dir, "all_metadata_records.jsonl"))
  write_jsonl(candidates, file.path(output_dir, "candidate_records.jsonl"))
  writeLines(vapply(candidates, function(x) normalise_oa_id(scalar(x$id)), character(1)),
             file.path(output_dir, "candidate_ids.txt"))
  summary <- list(
    schema = "openalex-only-citation-metadata-checkpoint-v1",
    metadata_chunk_number = metadata_chunk_number,
    ids_requested = length(ids),
    metadata_records_returned = length(records),
    candidate_records = length(candidates),
    openalex_cost_usd = f$cost_usd
  )
  write_json_pretty(summary, file.path(output_dir, "summary.json"))
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

if (stage == "finalise") {
  for (p in c(canonical_path, seed_root, metadata_root, lens_candidates_path)) {
    if (is.null(p) || !(file.exists(p) || dir.exists(p))) stop("Required finalise input missing: ", p, call. = FALSE)
  }

  canonical <- read_jsonl(canonical_path)
  included_oa <- character()
  for (rec in canonical) {
    refs <- canonical_manifestation_refs(rec)
    x <- refs[grepl("^openalex:", refs, ignore.case = TRUE)]
    included_oa <- c(included_oa, normalise_oa_id(sub("^openalex:", "", x, ignore.case = TRUE)))
  }
  included_oa <- unique(included_oa[nzchar(included_oa)])

  candidate_ids <- read_all_lines(metadata_root, "candidate_ids\\.txt$")
  candidate_ids <- setdiff(candidate_ids, included_oa)

  meta_files <- list.files(metadata_root, pattern = "candidate_records\\.jsonl$", recursive = TRUE, full.names = TRUE)
  oa_by_id <- new.env(hash = TRUE, parent = emptyenv())
  for (f in meta_files) for (rec in read_jsonl(f)) {
    oid <- normalise_oa_id(scalar(rec$id))
    if (nzchar(oid) && oid %in% candidate_ids && !exists(oid, oa_by_id, inherits = FALSE)) {
      assign(oid, rec, oa_by_id)
    }
  }

  lens_records <- read_jsonl(lens_candidates_path)
  lens_id_map <- new.env(hash = TRUE, parent = emptyenv())
  lens_title_map <- new.env(hash = TRUE, parent = emptyenv())
  for (lr in lens_records) {
    lid <- scalar(lr$lens_id)
    if (!nzchar(lid)) next
    ids <- extract_external_ids_lens(lr)
    if (length(ids)) for (k in names(ids)) if (!exists(k, lens_id_map, inherits = FALSE)) assign(k, lid, lens_id_map)
    nt <- normalise_title(scalar(lr$title))
    if (nchar(nt) >= 20L && !exists(nt, lens_title_map, inherits = FALSE)) assign(nt, lid, lens_title_map)
  }

  matches <- list(); unique_oa <- list(); both_rows <- list()
  for (oid in sort(candidate_ids)) {
    rec <- if (exists(oid, oa_by_id, inherits = FALSE)) get(oid, oa_by_id) else list(id = oid)
    ids <- extract_external_ids_oa(rec)
    hit <- ""; basis <- ""
    if (length(ids)) {
      ks <- names(ids)
      found <- ks[vapply(ks, exists, logical(1), envir = lens_id_map, inherits = FALSE)]
      if (length(found)) {
        hit <- get(found[[1L]], envir = lens_id_map, inherits = FALSE)
        basis <- sub(":.*$", "", found[[1L]])
      }
    }
    if (!nzchar(hit)) {
      nt <- normalise_title(scalar(rec$display_name))
      if (nchar(nt) >= 20L && exists(nt, lens_title_map, inherits = FALSE)) {
        hit <- get(nt, envir = lens_title_map, inherits = FALSE)
        basis <- "exact_normalised_title"
      }
    }
    if (nzchar(hit)) {
      matches[[length(matches) + 1L]] <- data.frame(
        candidate_openalex_id = oid, matching_lens_id = hit,
        match_basis = basis, openalex_title = scalar(rec$display_name),
        stringsAsFactors = FALSE
      )
      both_rows[[length(both_rows) + 1L]] <- list(
        logical_candidate_id = paste0("lens:", hit),
        provenance = list(lens = TRUE, openalex = TRUE, lens_id = hit, openalex_id = oid,
                          cross_source_match_basis = basis),
        openalex = rec
      )
    } else {
      unique_oa[[length(unique_oa) + 1L]] <- rec
    }
  }

  M <- if (length(matches)) do.call(rbind, matches) else data.frame(
    candidate_openalex_id=character(),matching_lens_id=character(),
    match_basis=character(),openalex_title=character()
  )
  write.csv(M, file.path(output_dir, "openalex_candidates_matching_lens.csv"), row.names = FALSE)
  write_jsonl(unique_oa, file.path(output_dir, "openalex_candidates_unique_vs_lens.jsonl"))

  Efiles <- list.files(seed_root, pattern = "citation_edges_all\\.csv$", recursive = TRUE, full.names = TRUE)
  if (!length(Efiles)) Efiles <- list.files(seed_root, pattern = "citation_edges\\.csv$", recursive = TRUE, full.names = TRUE)
  E <- if (length(Efiles)) unique(do.call(rbind, lapply(Efiles, read.csv, stringsAsFactors = FALSE))) else data.frame()
  if (nrow(E)) E <- E[E$candidate_openalex_id %in% candidate_ids, , drop = FALSE]
  write.csv(E, file.path(output_dir, "openalex_candidate_citation_edges.csv"), row.names = FALSE)

  combined <- list()
  matched_lens <- if (nrow(M)) unique(M$matching_lens_id) else character()
  for (lr in lens_records) {
    lid <- scalar(lr$lens_id)
    oids <- if (nrow(M)) M$candidate_openalex_id[M$matching_lens_id == lid] else character()
    combined[[length(combined) + 1L]] <- list(
      logical_candidate_id = paste0("lens:", lid),
      provenance = list(lens = TRUE, openalex = length(oids) > 0L, lens_id = lid,
                        openalex_ids = as.list(oids)),
      lens = lr
    )
  }
  for (rec in unique_oa) {
    oid <- normalise_oa_id(scalar(rec$id))
    combined[[length(combined) + 1L]] <- list(
      logical_candidate_id = paste0("openalex:", oid),
      provenance = list(lens = FALSE, openalex = TRUE, openalex_id = oid),
      openalex = rec
    )
  }
  write_jsonl(combined, file.path(output_dir, "combined_candidate_records_deduplicated.jsonl"))

  summary <- list(
    schema = "openalex-only-plus-lens-citation-gap-final-v1",
    openalex_seed_rule = "included canonical records with OpenAlex manifestation(s) and no Lens manifestation",
    text_scope = c("title", "abstract", "keywords"),
    salmon_terms = c("salmon", "Salmo", "Oncorhynchus", "rainbow trout"),
    excluded_farming_terms = c("farm*", "cage*", "pens", "penned", "pen", "aquacultur*", "commercial*"),
    lens_candidates_existing = length(lens_records),
    openalex_candidates_after_filter_and_included_removal = length(candidate_ids),
    openalex_candidates_matching_existing_lens = nrow(M),
    openalex_candidates_unique_vs_lens = length(unique_oa),
    combined_unique_candidates = length(lens_records) + length(unique_oa),
    cross_source_deduplication = c("shared DOI/PMID/PMCID exact", "exact normalised title"),
    openai_api_called = FALSE
  )
  write_json_pretty(summary, file.path(output_dir, "summary.json"))
  cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), "\n")
  quit(save = "no", status = 0L)
}

stop("Unknown --stage: ", stage, call. = FALSE)
