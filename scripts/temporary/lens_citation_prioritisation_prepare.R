#!/usr/bin/env Rscript

suppressPackageStartupMessages({
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

canonical_path <- arg("--canonical")
seed_root <- arg("--seed-root")
metadata_root <- arg("--metadata-root")
output_dir <- arg("--output-dir", "outputs/lens_citation_prioritisation")

for (p in c(canonical_path, seed_root, metadata_root)) {
  if (is.null(p) || !file.exists(p) && !dir.exists(p)) {
    stop("Required input missing: ", p, call. = FALSE)
  }
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines, function(x) fromJSON(x, simplifyVector = FALSE))
}
write_jsonl <- function(rows, path) {
  con <- file(path, "wt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  for (x in rows) {
    writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
  }
}
scalar <- function(x) {
  if (is.null(x) || !length(x)) return("")
  z <- as.character(x[[1L]])
  if (is.na(z)) "" else trimws(z)
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
    if (is.list(ref)) scalar(ref$lens_id) else scalar(ref)
  }, character(1))
  unique(vals[nzchar(vals)])
}
doi_from <- function(rec) {
  ids <- rec$external_ids
  if (is.list(ids) && length(ids)) {
    for (x in ids) {
      if (is.list(x) && identical(tolower(scalar(x$type)), "doi")) return(scalar(x$value))
    }
  }
  ""
}
source_title <- function(rec) {
  src <- rec$source
  if (is.list(src)) {
    z <- scalar(src$title)
    if (nzchar(z)) return(z)
    return(scalar(src$name))
  }
  scalar(src)
}
authors_text <- function(rec) {
  a <- rec$authors
  if (is.null(a) || !length(a)) return("")
  vals <- vapply(a, function(x) {
    if (is.list(x)) {
      nm <- scalar(x$display_name)
      if (nzchar(nm)) return(nm)
      paste(Filter(nzchar, c(scalar(x$first_name), scalar(x$last_name))), collapse = " ")
    } else scalar(x)
  }, character(1))
  paste(vals[nzchar(vals)], collapse = "; ")
}
keywords_text <- function(rec) {
  k <- rec$keywords
  if (is.null(k)) return("")
  paste(as.character(unlist(k, recursive = TRUE, use.names = FALSE)), collapse = "; ")
}

# Build manifestation -> canonical mapping from the authoritative included corpus.
canonical_lines <- readLines(canonical_path, warn = FALSE, encoding = "UTF-8")
canonical_lines <- canonical_lines[nzchar(trimws(canonical_lines))]
lens_to_canonical <- new.env(hash = TRUE, parent = emptyenv())
canonical_ids <- character()
for (line in canonical_lines) {
  rec <- fromJSON(line, simplifyVector = FALSE)
  cid <- scalar((rec$identity %||% list())$record_id)
  if (!nzchar(cid)) next
  canonical_ids <- c(canonical_ids, cid)
  refs <- rec$manifestation_refs
  if (!is.null(refs) && length(refs)) {
    vals <- as.character(unlist(refs, recursive = TRUE, use.names = FALSE))
    lids <- sub("^lens:", "", vals[startsWith(vals, "lens:")])
    if (length(lids)) {
      for (lid in lids) assign(lid, cid, envir = lens_to_canonical)
    }
  }
}
canonical_ids <- unique(canonical_ids)

# Reconstruct manifestation-level edges from saved seed records.
seed_files <- list.files(seed_root, pattern = "seed_records\\.jsonl$", recursive = TRUE, full.names = TRUE)
if (!length(seed_files)) stop("No seed_records.jsonl checkpoints found", call. = FALSE)

edge_rows <- list()
for (f in seed_files) {
  recs <- read_jsonl(f)
  for (rec in recs) {
    seed_lens <- scalar(rec$lens_id)
    seed_canonical <- if (exists(seed_lens, envir = lens_to_canonical, inherits = FALSE)) get(seed_lens, envir = lens_to_canonical, inherits = FALSE) else ""
    if (!nzchar(seed_lens) || !nzchar(seed_canonical)) next

    forward <- as_ids(rec$scholarly_citations)
    backward <- reference_lens_ids(rec$references)

    if (length(forward)) {
      for (cand in forward) {
        edge_rows[[length(edge_rows) + 1L]] <- data.frame(
          seed_canonical_id = seed_canonical,
          seed_lens_id = seed_lens,
          candidate_lens_id = cand,
          direction = "candidate_cites_seed",
          stringsAsFactors = FALSE
        )
      }
    }
    if (length(backward)) {
      for (cand in backward) {
        edge_rows[[length(edge_rows) + 1L]] <- data.frame(
          seed_canonical_id = seed_canonical,
          seed_lens_id = seed_lens,
          candidate_lens_id = cand,
          direction = "seed_cites_candidate",
          stringsAsFactors = FALSE
        )
      }
    }
  }
}
edges <- if (length(edge_rows)) do.call(rbind, edge_rows) else data.frame()
if (!nrow(edges)) stop("No citation edges reconstructed", call. = FALSE)
edges <- unique(edges)

write.csv(edges, file.path(output_dir, "citation_edges_manifestation_level.csv"), row.names = FALSE)

# Collapse duplicate seed manifestations so ranking uses unique canonical included works.
canonical_edges <- unique(edges[c("seed_canonical_id", "candidate_lens_id", "direction")])
write.csv(canonical_edges, file.path(output_dir, "citation_edges_canonical_level.csv"), row.names = FALSE)

# Read rich/available metadata checkpoints. Prefer all_metadata_records when present.
metadata_files <- list.files(metadata_root, pattern = "all_metadata_records\\.jsonl$",
                             recursive = TRUE, full.names = TRUE)
if (!length(metadata_files)) {
  metadata_files <- list.files(metadata_root, pattern = "candidate_lens_metadata_full\\.jsonl$",
                               recursive = TRUE, full.names = TRUE)
}
if (!length(metadata_files)) {
  metadata_files <- list.files(metadata_root, pattern = "candidate_records\\.jsonl$",
                               recursive = TRUE, full.names = TRUE)
}
if (!length(metadata_files)) stop("No metadata checkpoint JSONL files found", call. = FALSE)

metadata_by_id <- new.env(hash = TRUE, parent = emptyenv())
for (f in metadata_files) {
  for (rec in read_jsonl(f)) {
    lid <- scalar(rec$lens_id)
    if (nzchar(lid) && !exists(lid, envir = metadata_by_id, inherits = FALSE)) {
      assign(lid, rec, envir = metadata_by_id)
    }
  }
}

candidate_id_files <- list.files(metadata_root, pattern = "candidate_ids\\.txt$",
                                 recursive = TRUE, full.names = TRUE)
if (!length(candidate_id_files)) stop("No candidate_ids.txt filter outputs found", call. = FALSE)
candidate_ids <- sort(unique(unlist(lapply(candidate_id_files, function(f) {
  z <- readLines(f, warn = FALSE, encoding = "UTF-8")
  trimws(z[nzchar(trimws(z))])
}), use.names = FALSE)))
candidate_ids <- intersect(candidate_ids, canonical_edges$candidate_lens_id)
rank_rows <- vector("list", length(candidate_ids))
candidate_records <- list()

for (i in seq_along(candidate_ids)) {
  lid <- candidate_ids[[i]]
  ce <- canonical_edges[canonical_edges$candidate_lens_id == lid, , drop = FALSE]

  n_forward <- length(unique(ce$seed_canonical_id[ce$direction == "candidate_cites_seed"]))
  n_backward <- length(unique(ce$seed_canonical_id[ce$direction == "seed_cites_candidate"]))
  n_any <- length(unique(ce$seed_canonical_id))
  direction_class <- if (n_forward > 0L && n_backward > 0L) "both" else if (n_forward > 0L) "forward_only" else "backward_only"

  rec <- if (exists(lid, envir = metadata_by_id, inherits = FALSE)) get(lid, envir = metadata_by_id) else list(lens_id = lid)

  yr <- scalar(rec$year_published)
  if (!nzchar(yr)) yr <- scalar(rec$date_published)
  rank_rows[[i]] <- data.frame(
    candidate_lens_id = lid,
    n_unique_included_connections = n_any,
    n_included_records_cited_by_candidate = n_forward,
    n_included_records_citing_candidate = n_backward,
    direction_class = direction_class,
    title = scalar(rec$title),
    year = yr,
    source_title = source_title(rec),
    doi = doi_from(rec),
    authors = authors_text(rec),
    keywords = keywords_text(rec),
    publication_type = scalar(rec$publication_type),
    references_count = suppressWarnings(as.integer(scalar(rec$references_count))),
    scholarly_citations_count = suppressWarnings(as.integer(scalar(rec$scholarly_citations_count))),
    metadata_available = length(rec) > 1L,
    stringsAsFactors = FALSE
  )

  candidate_records[[length(candidate_records) + 1L]] <- list(
    identity = list(
      lens_id = lid,
      record_id = lid,
      record_id_type = "lens_id"
    ),
    source = list(
      provider = "lens",
      source_format = "lens_api_json",
      discovery_route = "citation_gap_search"
    ),
    lens = list(raw_payload = rec),
    canonical = list(
      record_id = lid,
      lens_id = lid,
      title = rec$title %||% NULL,
      abstract = rec$abstract %||% NULL,
      authors = rec$authors %||% NULL,
      year = rec$year_published %||% rec$date_published %||% NULL,
      source = rec$source %||% NULL,
      doi = doi_from(rec),
      keywords = rec$keywords %||% NULL,
      publication_type = rec$publication_type %||% NULL
    ),
    citation_prioritisation = list(
      n_unique_included_connections = n_any,
      n_included_records_cited_by_candidate = n_forward,
      n_included_records_citing_candidate = n_backward,
      direction_class = direction_class,
      connected_included_record_ids = as.list(sort(unique(ce$seed_canonical_id)))
    ),
    provenance = list(
      discovery_method = "Lens citation chasing from included corpus",
      screening_status = "NOT_SCREENED",
      workflow04_api_called = FALSE
    )
  )
}

ranking <- do.call(rbind, rank_rows)
ranking$n_unique_included_connections[is.na(ranking$n_unique_included_connections)] <- 0L
ranking <- ranking[order(-ranking$n_unique_included_connections,
                         -ranking$n_included_records_citing_candidate,
                         -ranking$n_included_records_cited_by_candidate,
                         ranking$candidate_lens_id), ]

# Deterministic rank and strata, but no screening cutoff is encoded.
ranking$priority_rank <- seq_len(nrow(ranking))
ranking$connectivity_stratum <- ifelse(
  ranking$n_unique_included_connections >= 20, "20+",
  ifelse(ranking$n_unique_included_connections >= 10, "10-19",
  ifelse(ranking$n_unique_included_connections >= 5, "5-9",
  as.character(ranking$n_unique_included_connections)))
)

write.csv(ranking, file.path(output_dir, "candidate_ranking.csv"), row.names = FALSE)
write_jsonl(candidate_records, file.path(output_dir, "candidate_ingestion_ready.jsonl"))

# Stratum summary for later W04 yield tracking.
strata <- sort(unique(ranking$connectivity_stratum))
stratum_rows <- lapply(strata, function(s) {
  z <- ranking[ranking$connectivity_stratum == s, , drop = FALSE]
  data.frame(
    connectivity_stratum = s,
    candidates = nrow(z),
    screened_w04 = 0L,
    retained_w04 = 0L,
    excluded_w04 = 0L,
    unresolved_w04 = 0L,
    inclusion_rate = NA_real_,
    cumulative_screened = 0L,
    cumulative_retained = 0L,
    api_cost_usd = 0,
    stringsAsFactors = FALSE
  )
})
write.csv(do.call(rbind, stratum_rows),
          file.path(output_dir, "screening_yield_tracker_template.csv"), row.names = FALSE)

manifest <- list(
  schema = "living-evidence-map-citation-prioritisation-bundle-v1",
  created_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  canonical_included_records = length(canonical_ids),
  manifestation_level_edges = nrow(edges),
  canonical_level_edges = nrow(canonical_edges),
  unique_candidate_lens_ids = nrow(ranking),
  ranking_primary = "n_unique_included_connections",
  ranking_secondary = c("n_included_records_citing_candidate", "n_included_records_cited_by_candidate"),
  screening_status = "NOT_SCREENED",
  workflow04_api_called = FALSE,
  cutoff_defined = FALSE,
  files = list(
    candidate_ranking = "candidate_ranking.csv",
    manifestation_edges = "citation_edges_manifestation_level.csv",
    canonical_edges = "citation_edges_canonical_level.csv",
    ingestion_ready = "candidate_ingestion_ready.jsonl",
    yield_tracker = "screening_yield_tracker_template.csv"
  )
)
write_json(manifest, file.path(output_dir, "manifest.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")
cat(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, na = "null"), "\n")
