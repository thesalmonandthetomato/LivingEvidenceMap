#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
  library(digest)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

lens_path <- arg("--lens")
scopus_path <- arg("--scopus")
openalex_path <- arg("--openalex")
agricola_path <- arg("--agricola")
canonical_path <- arg("--canonical")
output_dir <- arg("--output-dir")
canonical_ref <- arg("--canonical-ref", "unknown")
canonical_commit <- arg("--canonical-commit", "unknown")
workflow_commit <- arg("--workflow-commit", "unknown")
workflow01_run_id <- arg("--workflow01-run-id", "unknown")
reviewed_duplicates_path <- arg("--reviewed-duplicates")
reviewed_not_duplicates_path <- arg("--reviewed-not-duplicates")

required_args <- list(lens_path, scopus_path, openalex_path, agricola_path, canonical_path, output_dir)
if (any(vapply(required_args, is.null, logical(1)))) {
  stop("Required: --lens --scopus --openalex --agricola --canonical --output-dir", call. = FALSE)
}

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  y <- as.character(x[[1L]])
  if (!nzchar(trimws(y))) NULL else y
}
norm_text <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- iconv(x, to = "ASCII//TRANSLIT")
  if (is.na(x)) return(NULL)
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", " ", x, perl = TRUE)
  x <- trimws(gsub("\\s+", " ", x, perl = TRUE))
  if (!nzchar(x)) NULL else x
}
norm_doi <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, perl = TRUE)
  x <- sub("^doi:\\s*", "", x, perl = TRUE)
  x <- sub("\\.$", "", x)
  if (!nzchar(x)) NULL else x
}
norm_pages <- function(x) {
  x <- norm_text(x)
  if (is.null(x)) return(NULL)
  gsub(" ", "", x, fixed = TRUE)
}
first_author <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  if (is.character(x)) {
    z <- scalar(x)
    if (is.null(z)) return(NULL)
    z <- strsplit(z, "\\||;|,")[[1L]][1L]
    parts <- strsplit(trimws(z), "\\s+")[[1L]]
    return(tolower(gsub("[^a-z0-9]", "", parts[[1L]], perl = TRUE)))
  }
  a <- x[[1L]]
  if (is.character(a)) return(first_author(a))
  if (is.list(a)) {
    z <- scalar(a$surname %||% a$last_name %||% a$family %||% a$display_name %||% a$name %||% a$full_name)
    if (is.null(z)) return(NULL)
    if (!is.null(a$surname) || !is.null(a$last_name) || !is.null(a$family)) return(norm_text(z))
    parts <- strsplit(norm_text(z) %||% "", " ")[[1L]]
    if (!length(parts)) return(NULL)
    return(parts[[1L]])
  }
  NULL
}
source_kind <- function(r) {
  if (is.list(r$lens)) return("lens")
  p <- scalar(r$source$provider)
  if (identical(p, "scopus")) return("scopus")
  if (identical(p, "openalex")) return("openalex")
  if (identical(p, "agricola_via_europe_pmc")) return("agricola")
  stop(sprintf("Unknown source provider: %s", p %||% "<missing>"), call. = FALSE)
}
source_record_id <- function(r) {
  if (source_kind(r) == "lens") {
    return(as.character(r$identity$lens_id %||% r$identity$record_id %||% ""))
  }
  as.character(r$sidecar_identity$sidecar_record_id %||% "")
}
lens_id <- function(r) {
  if (source_kind(r) != "lens") return(NULL)
  scalar(r$identity$lens_id %||% r$canonical$lens_id %||% r$lens$raw_payload$lens_id)
}
record_doi <- function(r) {
  if (source_kind(r) == "lens") {
    d <- norm_doi(r$canonical$doi)
    if (!is.null(d)) return(d)
    ids <- r$lens$raw_payload$external_ids %||% list()
    for (z in ids) {
      if (is.list(z) && identical(tolower(as.character(z$type %||% "")), "doi")) {
        d <- norm_doi(z$value)
        if (!is.null(d)) return(d)
      }
    }
    return(NULL)
  }
  norm_doi(r$mapped_fields$doi %||% r$sidecar_identity$doi)
}
record_title <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$title %||% r$lens$raw_payload$title))
  scalar(r$mapped_fields$title)
}
record_authors <- function(r) {
  if (source_kind(r) == "lens") return(r$canonical$authors %||% r$lens$raw_payload$authors)
  r$mapped_fields$authors %||% r$mapped_fields$first_author
}
record_year <- function(r) {
  z <- if (source_kind(r) == "lens") {
    r$canonical$year %||% r$lens$raw_payload$year_published %||% r$lens$raw_payload$date_published
  } else r$mapped_fields$year %||% r$mapped_fields$publication_date
  y <- suppressWarnings(as.integer(substr(as.character(z %||% ""), 1L, 4L)))
  if (is.na(y)) NA_integer_ else y
}
record_journal <- function(r) {
  if (source_kind(r) == "lens") {
    s <- r$canonical$source %||% r$lens$raw_payload$source
    if (is.list(s)) return(scalar(s$title))
    return(scalar(s))
  }
  scalar(r$mapped_fields$source %||% r$mapped_fields$journal)
}
record_volume <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$volume %||% r$lens$raw_payload$volume))
  scalar(r$mapped_fields$volume)
}
record_issue <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$issue %||% r$lens$raw_payload$issue))
  scalar(r$mapped_fields$issue)
}
record_pages <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$pages %||% r$lens$raw_payload$pages))
  scalar(r$mapped_fields$pages %||% r$mapped_fields$article_number)
}
record_abstract <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$abstract %||% r$lens$raw_payload$abstract))
  scalar(r$mapped_fields$abstract)
}
record_type <- function(r) {
  if (source_kind(r) == "lens") return(scalar(r$canonical$publication_type %||% r$lens$raw_payload$publication_type))
  scalar(r$mapped_fields$publication_type)
}

read_jsonl <- function(path, fun) {
  con <- file(path, "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  i <- 0L
  repeat {
    lines <- readLines(con, n = 500L, warn = FALSE)
    if (!length(lines)) break
    for (line in lines) {
      if (!nzchar(trimws(line))) next
      i <- i + 1L
      fun(fromJSON(line, simplifyVector = FALSE), i, line)
    }
  }
  i
}

paths <- c(lens = lens_path, scopus = scopus_path, openalex = openalex_path, agricola = agricola_path)
meta_rows <- list()
n_by_source <- integer()

for (src in names(paths)) {
  n_by_source[[src]] <- read_jsonl(paths[[src]], function(r, i, line) {
    rid <- source_record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s record %d has blank source record ID", src, i), call. = FALSE)
    ttl <- record_title(r)
    yr <- record_year(r)
    meta_rows[[length(meta_rows) + 1L]] <<- data.frame(
      idx = length(meta_rows) + 1L,
      source = src,
      source_record_id = rid,
      lens_id = lens_id(r) %||% NA_character_,
      doi = record_doi(r) %||% NA_character_,
      title = ttl %||% NA_character_,
      title_norm = norm_text(ttl) %||% NA_character_,
      first_author = first_author(record_authors(r)) %||% NA_character_,
      year = yr,
      journal = record_journal(r) %||% NA_character_,
      journal_norm = norm_text(record_journal(r)) %||% NA_character_,
      volume = norm_text(record_volume(r)) %||% NA_character_,
      issue = norm_text(record_issue(r)) %||% NA_character_,
      pages = norm_pages(record_pages(r)) %||% NA_character_,
      has_abstract = !is.null(record_abstract(r)),
      publication_type = record_type(r) %||% NA_character_,
      stringsAsFactors = FALSE
    )
  })
}
meta <- do.call(rbind, meta_rows)
if (anyDuplicated(paste(meta$source, meta$source_record_id, sep = "::"))) {
  stop("Duplicate source namespace + source_record_id combinations found", call. = FALSE)
}

lens_ids_needed <- unique(meta$lens_id[!is.na(meta$lens_id) & nzchar(meta$lens_id)])
canonical_lines <- new.env(hash = TRUE, parent = emptyenv())
canonical_top_level_fields <- character()
canonical_matched <- 0L
canonical_records <- read_jsonl(canonical_path, function(r, i, line) {
  id <- scalar(r$identity$lens_id %||% r$canonical$lens_id %||% r$identity$record_id)
  canonical_top_level_fields <<- union(canonical_top_level_fields, names(r))
  if (!is.null(id) && id %in% lens_ids_needed) {
    assign(id, line, envir = canonical_lines)
    canonical_matched <<- canonical_matched + 1L
  }
})

meta$canonical_overlay_present <- !is.na(meta$lens_id) &
  vapply(meta$lens_id, function(x) !is.na(x) && exists(x, envir = canonical_lines, inherits = FALSE), logical(1))


pair_hash <- function(a, b) {
  joined <- paste(sort(c(as.character(a), as.character(b))), collapse = "|")
  substr(digest(joined, algo = "sha256", serialize = FALSE), 1L, 16L)
}

reviewed_duplicate_keys <- new.env(hash = TRUE, parent = emptyenv())
preferred_canonical_ids <- character()
reviewed_duplicate_count <- 0L
if (!is.null(reviewed_duplicates_path) && file.exists(reviewed_duplicates_path)) {
  read_jsonl(reviewed_duplicates_path, function(r, i, line) {
    a <- scalar(r$lens_id_a); b <- scalar(r$lens_id_b)
    if (!is.null(a) && !is.null(b) && identical(r$decision, "duplicate")) {
      assign(paste(sort(c(a,b)), collapse = "|"), r, envir = reviewed_duplicate_keys)
      reviewed_duplicate_count <<- reviewed_duplicate_count + 1L
      pref <- scalar(r$preferred_canonical_lens_id)
      if (!is.null(pref)) preferred_canonical_ids <<- unique(c(preferred_canonical_ids, pref))
    }
  })
}

reviewed_not_duplicate_hashes <- character()
if (!is.null(reviewed_not_duplicates_path) && file.exists(reviewed_not_duplicates_path)) {
  x <- fromJSON(reviewed_not_duplicates_path, simplifyVector = FALSE)
  reviewed_not_duplicate_hashes <- unique(vapply(x$pairs %||% list(), function(z) as.character(z$hash %||% ""), character(1)))
  reviewed_not_duplicate_hashes <- reviewed_not_duplicate_hashes[nzchar(reviewed_not_duplicate_hashes)]
}

lens_index <- setNames(meta$idx[!is.na(meta$lens_id) & nzchar(meta$lens_id)], meta$lens_id[!is.na(meta$lens_id) & nzchar(meta$lens_id)])

pair_env <- new.env(hash = TRUE, parent = emptyenv())
add_pair <- function(i, j, block) {
  if (i == j) return()
  a <- min(i, j); b <- max(i, j)
  key <- paste(a, b, sep = "::")
  if (!exists(key, envir = pair_env, inherits = FALSE)) {
    assign(key, list(i = a, j = b, blocks = block), envir = pair_env)
  } else {
    z <- get(key, envir = pair_env, inherits = FALSE)
    z$blocks <- unique(c(z$blocks, block))
    assign(key, z, envir = pair_env)
  }
}
add_block_pairs <- function(values, block_name, max_group = 200L) {
  ok <- which(!is.na(values) & nzchar(values))
  if (!length(ok)) return(list(groups = 0L, skipped = 0L))
  groups <- split(ok, values[ok])
  groups <- groups[lengths(groups) > 1L]
  skipped <- 0L
  for (g in groups) {
    if (length(g) > max_group) {
      skipped <- skipped + 1L
      next
    }
    cmb <- combn(g, 2L)
    for (k in seq_len(ncol(cmb))) add_pair(cmb[1L, k], cmb[2L, k], block_name)
  }
  list(groups = length(groups), skipped = skipped)
}

block_stats <- list(
  doi = add_block_pairs(meta$doi, "same_doi"),
  exact_title = add_block_pairs(meta$title_norm, "exact_title"),
  author_year = add_block_pairs(ifelse(!is.na(meta$first_author) & !is.na(meta$year), paste(meta$first_author, meta$year, sep = "::"), NA), "first_author_year"),
  journal_volume_pages = add_block_pairs(ifelse(!is.na(meta$journal_norm) & !is.na(meta$volume) & !is.na(meta$pages), paste(meta$journal_norm, meta$volume, meta$pages, sep = "::"), NA), "journal_volume_pages")
)


if (length(ls(reviewed_duplicate_keys, all.names = TRUE))) {
  for (key in ls(reviewed_duplicate_keys, all.names = TRUE)) {
    ids <- strsplit(key, "\\|", fixed = FALSE)[[1L]]
    if (length(ids) == 2L && all(ids %in% names(lens_index))) {
      add_pair(lens_index[[ids[[1L]]]], lens_index[[ids[[2L]]]], "human_reviewed_duplicate")
    }
  }
}

pair_keys <- ls(pair_env, all.names = TRUE)
pair_rows <- vector("list", length(pair_keys))

for (k in seq_along(pair_keys)) {
  z <- get(pair_keys[[k]], envir = pair_env, inherits = FALSE)
  a <- meta[z$i, , drop = FALSE]
  b <- meta[z$j, , drop = FALSE]
  title_sim <- if (!is.na(a$title_norm) && !is.na(b$title_norm)) as.numeric(stringsim(a$title_norm, b$title_norm, method = "jw")) else NA_real_
  same_doi <- !is.na(a$doi) && !is.na(b$doi) && identical(a$doi, b$doi)
  different_doi <- !is.na(a$doi) && !is.na(b$doi) && !identical(a$doi, b$doi)
  author_match <- !is.na(a$first_author) && !is.na(b$first_author) && identical(a$first_author, b$first_author)
  year_diff <- if (!is.na(a$year) && !is.na(b$year)) abs(a$year - b$year) else NA_integer_
  year_compatible <- is.na(year_diff) || year_diff <= 1L
  journal_match <- !is.na(a$journal_norm) && !is.na(b$journal_norm) && identical(a$journal_norm, b$journal_norm)
  pages_match <- !is.na(a$pages) && !is.na(b$pages) && identical(a$pages, b$pages)
  exact_title <- !is.na(a$title_norm) && !is.na(b$title_norm) && identical(a$title_norm, b$title_norm)

  classification <- "not_resolved"
  rule <- "candidate_only"

  human_dup <- FALSE
  human_not_dup <- FALSE
  if (!is.na(a$lens_id) && !is.na(b$lens_id)) {
    human_key <- paste(sort(c(a$lens_id, b$lens_id)), collapse = "|")
    human_dup <- exists(human_key, envir = reviewed_duplicate_keys, inherits = FALSE)
    human_not_dup <- pair_hash(a$lens_id, b$lens_id) %in% reviewed_not_duplicate_hashes
  }

  if (human_not_dup) {
    classification <- "not_duplicate_human"
    rule <- "human_reviewed_not_duplicate"
  } else if (human_dup) {
    classification <- "duplicate"
    rule <- "human_reviewed_duplicate"
  } else if (same_doi && !is.na(title_sim) && title_sim < 0.90) {
    classification <- "doi_conflict"
    rule <- "same_doi_incompatible_title"
  } else if (same_doi && !is.na(title_sim) && title_sim >= 0.90 && (author_match || year_compatible)) {
    classification <- "duplicate"
    rule <- "same_doi_title_compatible"
  } else if (same_doi && is.na(title_sim)) {
    classification <- "review"
    rule <- "same_doi_title_unavailable"
  } else if (!is.na(title_sim) && title_sim >= 0.985 && author_match && year_compatible) {
    classification <- "duplicate"
    rule <- "very_high_title_author_year"
  } else if (exact_title && year_compatible && (author_match || journal_match || pages_match)) {
    classification <- "duplicate"
    rule <- "exact_title_supporting_metadata"
  } else if (!is.na(title_sim) && title_sim >= 0.92 && author_match && year_compatible) {
    classification <- "review"
    rule <- if (different_doi) "strong_metadata_different_doi" else "strong_metadata"
  } else if (!is.na(title_sim) && title_sim >= 0.90 && journal_match && pages_match) {
    classification <- "review"
    rule <- "title_journal_pages"
  }

  pair_rows[[k]] <- data.frame(
    record_i = z$i, record_j = z$j,
    source_i = a$source, source_j = b$source,
    source_record_id_i = a$source_record_id, source_record_id_j = b$source_record_id,
    doi_i = a$doi, doi_j = b$doi,
    title_similarity = round(title_sim, 6),
    first_author_match = author_match,
    year_diff = year_diff,
    journal_match = journal_match,
    pages_match = pages_match,
    blocks = paste(sort(unique(z$blocks)), collapse = ";"),
    classification = classification,
    rule = rule,
    stringsAsFactors = FALSE
  )
}
pairs <- if (length(pair_rows)) do.call(rbind, pair_rows) else data.frame()

parent <- seq_len(nrow(meta))
rank <- integer(nrow(meta))
find_root <- function(x) {
  while (parent[[x]] != x) {
    parent[[x]] <<- parent[[parent[[x]]]]
    x <- parent[[x]]
  }
  x
}
union_nodes <- function(a, b) {
  ra <- find_root(a); rb <- find_root(b)
  if (ra == rb) return()
  if (rank[[ra]] < rank[[rb]]) parent[[ra]] <<- rb
  else if (rank[[ra]] > rank[[rb]]) parent[[rb]] <<- ra
  else {
    parent[[rb]] <<- ra
    rank[[ra]] <<- rank[[ra]] + 1L
  }
}

if (nrow(pairs)) {
  accepted <- pairs[pairs$classification == "duplicate", , drop = FALSE]
  if (nrow(accepted)) {
    for (i in seq_len(nrow(accepted))) union_nodes(accepted$record_i[[i]], accepted$record_j[[i]])
  }
}
roots <- vapply(seq_len(nrow(meta)), find_root, integer(1))
groups <- split(seq_len(nrow(meta)), roots)

cluster_rows <- list()
cluster_id_by_idx <- character(nrow(meta))
cluster_status_by_idx <- character(nrow(meta))
representative_by_idx <- integer(nrow(meta))

for (g in groups) {
  sub <- meta[g, , drop = FALSE]
  conflicts <- FALSE
  if (length(g) > 1L) {
    gp <- pairs[pairs$record_i %in% g & pairs$record_j %in% g, , drop = FALSE]
    conflicts <- nrow(gp) && any(gp$classification == "doi_conflict")
    years <- sub$year[!is.na(sub$year)]
    if (length(years) > 1L && diff(range(years)) > 2L) conflicts <- TRUE
  }

  cluster_key <- paste(sort(paste(sub$source, sub$source_record_id, sep = ":")), collapse = "|")
  cid <- paste0("work-", substr(digest(cluster_key, algo = "sha256", serialize = FALSE), 1L, 16L))
  cluster_status <- if (conflicts) "review_required" else if (length(g) > 1L) "reconciled" else "singleton"

  pub_type <- ifelse(is.na(sub$publication_type), "", sub$publication_type)
  score <- ifelse(!is.na(sub$lens_id) & sub$lens_id %in% preferred_canonical_ids, 5000, 0) +
    ifelse(sub$canonical_overlay_present, 1000, 0) +
    ifelse(sub$source == "lens", 100, 0) +
    ifelse(sub$has_abstract, 20, 0) +
    ifelse(grepl("preprint|conference abstract|proceedings", tolower(pub_type), perl = TRUE), -10, 0)
  rep_idx <- g[which.max(score)]

  cluster_id_by_idx[g] <- cid
  cluster_status_by_idx[g] <- cluster_status
  representative_by_idx[g] <- rep_idx

  cluster_rows[[length(cluster_rows) + 1L]] <- list(
    cluster_id = cid,
    status = cluster_status,
    representative = list(
      source = meta$source[[rep_idx]],
      source_record_id = meta$source_record_id[[rep_idx]],
      lens_id = if (is.na(meta$lens_id[[rep_idx]])) NULL else meta$lens_id[[rep_idx]]
    ),
    members = lapply(g, function(i) list(
      source = meta$source[[i]],
      source_record_id = meta$source_record_id[[i]],
      lens_id = if (is.na(meta$lens_id[[i]])) NULL else meta$lens_id[[i]],
      doi = if (is.na(meta$doi[[i]])) NULL else meta$doi[[i]]
    )),
    member_count = length(g),
    canonical_overlay_member_count = sum(sub$canonical_overlay_present),
    created_at = now_utc()
  )
}

meta$cluster_id <- cluster_id_by_idx
meta$cluster_status <- cluster_status_by_idx
meta$representative_idx <- representative_by_idx
meta$is_representative <- meta$idx == meta$representative_idx

merge_canonical_overlay <- function(incoming) {
  id <- lens_id(incoming)
  if (is.null(id) || !exists(id, envir = canonical_lines, inherits = FALSE)) return(incoming)
  base <- fromJSON(get(id, envir = canonical_lines, inherits = FALSE), simplifyVector = FALSE)

  status <- scalar(incoming$abstract_enrichment$status)
  if (!is.null(status) && status %in% c("abstract_enriched_europe_pmc", "abstract_repaired_europe_pmc")) {
    incoming_abs <- incoming$canonical$abstract
    if (!is.null(incoming_abs)) {
      if (is.null(base$canonical)) base$canonical <- list()
      base$canonical$abstract <- incoming_abs
    }
  }
  if (!is.null(incoming$abstract_enrichment)) base$abstract_enrichment <- incoming$abstract_enrichment
  base
}

annotation_flags <- function(r) {
  has_species_geography <- !is.null(r$annotations) && !is.null(r$annotations$species_geography)
  has_species <- has_species_geography && !is.null(r$annotations$species_geography$species)
  has_geography <- has_species_geography && !is.null(r$annotations$species_geography$geography)

  topic_status <- tolower(scalar((r$topics %||% list())$status) %||% "")
  has_topic <- !is.null(r$topics) && !topic_status %in% c("", "pending_llm")

  has_publication <- !is.null(r$publication_status) || !is.null(r$notices)

  list(
    species = has_species,
    geography = has_geography,
    topic = has_topic,
    publication_status = has_publication
  )
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
manifest_path <- file.path(output_dir, "multisource_manifestations.jsonl")
representative_path <- file.path(output_dir, "representative_records.jsonl")
inventory_path <- file.path(output_dir, "annotation_inventory.jsonl")
species_geo_queue <- file.path(output_dir, "needs_species_geography_annotation.jsonl")
topic_queue <- file.path(output_dir, "needs_topic_coding.jsonl")
publication_queue <- file.path(output_dir, "needs_publication_status_check.jsonl")

manifest_con <- file(manifest_path, "wt", encoding = "UTF-8")
rep_con <- file(representative_path, "wt", encoding = "UTF-8")
inv_con <- file(inventory_path, "wt", encoding = "UTF-8")
sg_con <- file(species_geo_queue, "wt", encoding = "UTF-8")
topic_con <- file(topic_queue, "wt", encoding = "UTF-8")
pub_con <- file(publication_queue, "wt", encoding = "UTF-8")

on.exit({
  for (con in list(manifest_con, rep_con, inv_con, sg_con, topic_con, pub_con)) {
    try(close(con), silent = TRUE)
  }
}, add = TRUE)

idx_counter <- 0L
rep_count <- 0L
annotation_counts <- c(species = 0L, geography = 0L, topic = 0L, publication_status = 0L)

for (src in names(paths)) {
  read_jsonl(paths[[src]], function(incoming, i, line) {
    idx_counter <<- idx_counter + 1L
    row <- meta[idx_counter, , drop = FALSE]
    out <- if (src == "lens") merge_canonical_overlay(incoming) else incoming

    existing_dedup_preserved <- !is.null(out$deduplication)
    out$reconciliation <- list(
      workflow = "02_multisource_reconciliation",
      cluster_id = row$cluster_id[[1L]],
      cluster_status = row$cluster_status[[1L]],
      is_representative = row$is_representative[[1L]],
      representative = list(
        source = meta$source[[row$representative_idx[[1L]]]],
        source_record_id = meta$source_record_id[[row$representative_idx[[1L]]]]
      ),
      source = src,
      source_record_id = row$source_record_id[[1L]],
      canonical_overlay_applied = row$canonical_overlay_present[[1L]],
      prior_deduplication_preserved = existing_dedup_preserved,
      canonical_ref = canonical_ref,
      canonical_commit = canonical_commit,
      reconciled_at = now_utc()
    )

    writeLines(toJSON(out, auto_unbox = TRUE, null = "null", na = "null"), manifest_con)

    if (isTRUE(row$is_representative[[1L]])) {
      rep_count <<- rep_count + 1L
      flags <- annotation_flags(out)
      has_species <- flags$species
      has_geography <- flags$geography
      has_topic <- flags$topic
      has_publication <- flags$publication_status

      annotation_counts[["species"]] <<- annotation_counts[["species"]] + as.integer(has_species)
      annotation_counts[["geography"]] <<- annotation_counts[["geography"]] + as.integer(has_geography)
      annotation_counts[["topic"]] <<- annotation_counts[["topic"]] + as.integer(has_topic)
      annotation_counts[["publication_status"]] <<- annotation_counts[["publication_status"]] + as.integer(has_publication)

      inventory <- list(
        cluster_id = row$cluster_id[[1L]],
        source = src,
        source_record_id = row$source_record_id[[1L]],
        lens_id = lens_id(out),
        has_species_annotation = has_species,
        has_geography_annotation = has_geography,
        has_topic_annotation = has_topic,
        has_publication_status_or_notice = has_publication,
        canonical_overlay_applied = row$canonical_overlay_present[[1L]]
      )
      writeLines(toJSON(inventory, auto_unbox = TRUE, null = "null", na = "null"), inv_con)
      writeLines(toJSON(out, auto_unbox = TRUE, null = "null", na = "null"), rep_con)

      queue_stub <- list(
        cluster_id = row$cluster_id[[1L]],
        source = src,
        source_record_id = row$source_record_id[[1L]],
        lens_id = lens_id(out),
        title = record_title(out),
        abstract = record_abstract(out),
        reason = NULL
      )
      if (!has_species || !has_geography) {
        queue_stub$reason <- c(if (!has_species) "missing_species" else NULL, if (!has_geography) "missing_geography" else NULL)
        writeLines(toJSON(queue_stub, auto_unbox = TRUE, null = "null", na = "null"), sg_con)
      }
      if (!has_topic) {
        queue_stub$reason <- "missing_topic"
        writeLines(toJSON(queue_stub, auto_unbox = TRUE, null = "null", na = "null"), topic_con)
      }
      if (!has_publication) {
        queue_stub$reason <- "missing_publication_status"
        writeLines(toJSON(queue_stub, auto_unbox = TRUE, null = "null", na = "null"), pub_con)
      }
    }
  })
}

for (con in list(manifest_con, rep_con, inv_con, sg_con, topic_con, pub_con)) close(con)

write_jsonl_objects <- function(path, objects) {
  con <- file(path, "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  for (x in objects) writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null"), con)
}
write_jsonl_objects(file.path(output_dir, "clusters.jsonl"), cluster_rows)

if (nrow(pairs)) {
  con <- file(file.path(output_dir, "candidate_pairs.jsonl"), "wt", encoding = "UTF-8")
  for (i in seq_len(nrow(pairs))) {
    writeLines(toJSON(as.list(pairs[i, ]), auto_unbox = TRUE, null = "null", na = "null"), con)
  }
  close(con)
} else file.create(file.path(output_dir, "candidate_pairs.jsonl"))

queue_count <- function(path) {
  if (!file.exists(path)) return(0L)
  con <- file(path, "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  sum(nzchar(trimws(readLines(con, warn = FALSE))))
}

report <- list(
  workflow = "02_multisource_reconciliation",
  implementation_language = "R",
  status = "success",
  created_at = now_utc(),
  provenance = list(
    workflow_commit = workflow_commit,
    workflow01_run_id = workflow01_run_id
  ),
  inputs = as.list(n_by_source),
  total_source_manifestations = nrow(meta),
  canonical_overlay = list(
    ref = canonical_ref,
    commit = canonical_commit,
    canonical_records_scanned = canonical_records,
    lens_records_matched = canonical_matched,
    top_level_fields_observed = sort(canonical_top_level_fields),
    policy = "Entire current canonical record is retained for matching Lens IDs; existing annotations, screening, deduplication and publication-status metadata are preserved. Workflow 01 abstract enrichment may update only canonical.abstract."
  ),
  human_adjudication = list(
    reviewed_duplicate_pairs_loaded = reviewed_duplicate_count,
    reviewed_not_duplicate_hashes_loaded = length(reviewed_not_duplicate_hashes),
    preferred_canonical_lens_ids_loaded = length(preferred_canonical_ids),
    policy = "Human-reviewed decisions override automatic rules before clustering."
  ),
  candidate_generation = list(
    pair_count = length(pair_keys),
    block_stats = block_stats,
    all_pairs_comparison_performed = FALSE
  ),
  pair_classification = if (nrow(pairs)) as.list(table(pairs$classification)) else list(),
  clusters = list(
    total = length(cluster_rows),
    reconciled = sum(vapply(cluster_rows, function(x) identical(x$status, "reconciled"), logical(1))),
    singletons = sum(vapply(cluster_rows, function(x) identical(x$status, "singleton"), logical(1))),
    review_required = sum(vapply(cluster_rows, function(x) identical(x$status, "review_required"), logical(1))),
    representatives = rep_count
  ),
  annotation_preservation = list(
    representative_records_with_existing_species = unname(annotation_counts[["species"]]),
    representative_records_with_existing_geography = unname(annotation_counts[["geography"]]),
    representative_records_with_existing_topics = unname(annotation_counts[["topic"]]),
    representative_records_with_existing_publication_status_or_notice = unname(annotation_counts[["publication_status"]]),
    species_geography_rerun_queue = queue_count(species_geo_queue),
    topic_rerun_queue = queue_count(topic_queue),
    publication_status_check_queue = queue_count(publication_queue),
    rerun_policy = "Only representative records lacking the relevant existing annotation are queued."
  ),
  safeguards = list(
    canonical_json_modified = FALSE,
    existing_deduplication_overwritten = FALSE,
    source_payloads_modified = FALSE,
    external_api_calls = FALSE,
    model_calls = FALSE,
    unresolved_clusters_promoted = FALSE
  ),
  outputs = list(
    manifestations = basename(manifest_path),
    representatives = basename(representative_path),
    candidate_pairs = "candidate_pairs.jsonl",
    clusters = "clusters.jsonl",
    annotation_inventory = basename(inventory_path),
    species_geography_queue = basename(species_geo_queue),
    topic_queue = basename(topic_queue),
    publication_status_queue = basename(publication_queue)
  )
)
writeLines(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
           file.path(output_dir, "report.json"))
cat(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), "\n")
