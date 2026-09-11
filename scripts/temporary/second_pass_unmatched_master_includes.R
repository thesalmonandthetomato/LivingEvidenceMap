#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", name, "="), "", hit[[1]])
}
or_else <- function(x, y) if (is.null(x) || length(x) == 0) y else x

canonical_path <- arg("canonical")
unmatched_path <- arg("unmatched")
matched_path <- arg("matched")
out_dir <- arg("outdir", "outputs/second_pass_unmatched_includes")
if (is.null(canonical_path) || is.null(unmatched_path) || is.null(matched_path)) {
  stop("ERROR: --canonical, --unmatched and --matched are required", call. = FALSE)
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

norm_text <- function(x) {
  x <- tolower(trimws(as.character(or_else(x, ""))))
  x <- gsub("<[^>]+>", " ", x)
  x <- gsub("[^[:alnum:] ]+", " ", x)
  gsub("[[:space:]]+", " ", trimws(x))
}
norm_doi <- function(x) {
  x <- tolower(trimws(as.character(or_else(x, ""))))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:[[:space:]]*", "", x)
  m <- regexpr("10\\.[0-9]{4,9}/[^[:space:]\"<>]+", x, perl = TRUE)
  if (m[1] > 0) x <- regmatches(x, m)
  sub("[\\.,;:\\)\\]\\}]+$", "", x)
}
token_jaccard <- function(a, b) {
  A <- unique(strsplit(norm_text(a), " ", fixed = TRUE)[[1]])
  B <- unique(strsplit(norm_text(b), " ", fixed = TRUE)[[1]])
  A <- A[nzchar(A)]; B <- B[nzchar(B)]
  if (!length(A) || !length(B)) return(0)
  length(intersect(A, B)) / length(union(A, B))
}
seq_sim <- function(a, b) {
  aa <- norm_text(a); bb <- norm_text(b)
  1 - stringdist(aa, bb, method = "lv") / max(nchar(aa), nchar(bb), 1)
}
read_jsonl <- function(path) {
  con <- file(path, "rt", encoding = "UTF-8"); on.exit(close(con))
  out <- list(); i <- 0L
  repeat {
    line <- readLines(con, n = 1L, warn = FALSE)
    if (!length(line)) break
    if (!nzchar(trimws(line))) next
    i <- i + 1L
    out[[i]] <- fromJSON(line, simplifyVector = FALSE)
  }
  out
}
write_jsonl <- function(path, rows) {
  con <- file(path, "wt", encoding = "UTF-8"); on.exit(close(con))
  for (x in rows) writeLines(toJSON(x, auto_unbox = TRUE, null = "null"), con)
}

message("Loading unmatched historical rows")
u <- read_jsonl(unmatched_path)
targets <- Filter(function(x) identical(x$historical_source, "production_master") &&
                            identical(x$decision, "include"), u)
if (length(targets) != 690L) {
  stop(sprintf("ERROR: expected 690 unmatched master includes; found %d", length(targets)), call. = FALSE)
}
message("Targets: 690 unmatched master includes")

message("Loading canonical JSONL")
canon <- list()
con <- file(canonical_path, "rt", encoding = "UTF-8")
i <- 0L
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next
  i <- i + 1L
  rec <- fromJSON(line, simplifyVector = FALSE)
  can <- or_else(rec$canonical, list())
  ident <- or_else(rec$identity, list())
  authors <- or_else(can$authors, "")
  if (is.list(authors)) {
    authors <- paste(unlist(lapply(authors, function(a) {
      if (is.list(a)) paste(unlist(a), collapse = " ") else as.character(a)
    })), collapse = " ")
  }
  canon[[i]] <- list(
    row = i,
    lens_id = as.character(or_else(ident$lens_id, or_else(rec$record_id, ""))),
    doi = norm_doi(or_else(can$doi, "")),
    title = as.character(or_else(can$title, "")),
    title_norm = norm_text(or_else(can$title, "")),
    year = as.character(or_else(can$year, "")),
    abstract = as.character(or_else(can$abstract, "")),
    abstract_norm = norm_text(or_else(can$abstract, "")),
    authors = as.character(authors),
    source = as.character(or_else(can$source, or_else(can$source_title, or_else(can$journal, ""))))
  )
  if (i %% 2000L == 0L) message(sprintf("Canonical index: %d", i))
}
close(con)
message(sprintf("Canonical index complete: %d", length(canon)))

matched <- read_jsonl(matched_path)
already <- unique(vapply(matched, function(x) as.character(or_else(x$canonical_lens_id, "")), character(1)))
already <- already[nzchar(already)]

idx_lens <- new.env(hash = TRUE, parent = emptyenv())
idx_doi <- new.env(hash = TRUE, parent = emptyenv())
idx_title <- new.env(hash = TRUE, parent = emptyenv())
idx_abs <- new.env(hash = TRUE, parent = emptyenv())
by_year <- new.env(hash = TRUE, parent = emptyenv())
add_idx <- function(env, key, value) {
  if (!nzchar(key)) return()
  old <- if (exists(key, env, inherits = FALSE)) get(key, env) else integer()
  assign(key, c(old, value), env)
}
for (j in seq_along(canon)) {
  cc <- canon[[j]]
  add_idx(idx_lens, cc$lens_id, j)
  add_idx(idx_doi, cc$doi, j)
  add_idx(idx_title, cc$title_norm, j)
  if (nchar(cc$abstract_norm) >= 200) add_idx(idx_abs, cc$abstract_norm, j)
  add_idx(by_year, cc$year, j)
}

author_overlap <- function(a, b) {
  A <- unique(strsplit(norm_text(a), " ", fixed = TRUE)[[1]])
  B <- unique(strsplit(norm_text(b), " ", fixed = TRUE)[[1]])
  A <- A[nchar(A) > 2]; B <- B[nchar(B) > 2]
  if (!length(A) || !length(B)) return(0)
  length(intersect(A, B)) / length(A)
}
entry <- function(h, candidates, method, metrics = NULL) {
  list(
    historical_source = h$historical_source,
    historical_row = h$historical_row,
    decision = h$decision,
    historical = h$historical,
    match_method = method,
    candidate_lens_ids = vapply(canon[candidates], function(x) x$lens_id, character(1)),
    candidate_rows = vapply(canon[candidates], function(x) x$row, integer(1)),
    candidate_titles = vapply(canon[candidates], function(x) x$title, character(1)),
    candidate_years = vapply(canon[candidates], function(x) x$year, character(1)),
    candidate_dois = vapply(canon[candidates], function(x) x$doi, character(1)),
    candidate_already_decisioned_first_pass = vapply(canon[candidates], function(x) x$lens_id %in% already, logical(1)),
    metrics = metrics
  )
}

resolved <- list(); ambiguous <- list(); still <- list(); counts <- list()
bump <- function(k) counts[[k]] <<- as.integer(or_else(counts[[k]], 0L)) + 1L

for (k in seq_along(targets)) {
  h <- targets[[k]]
  hh <- or_else(h$historical, list())
  lens <- as.character(or_else(hh$lens_id, ""))
  doi <- norm_doi(or_else(hh$doi, ""))
  title <- norm_text(or_else(hh$title, ""))
  year <- as.character(or_else(hh$year, ""))
  absn <- norm_text(or_else(hh$abstract, ""))
  authors <- as.character(or_else(hh$authors, ""))
  source <- as.character(or_else(hh$journal, or_else(hh$source, "")))

  candidates <- integer(); method <- NULL
  if (nzchar(lens) && exists(lens, idx_lens, inherits = FALSE)) {
    candidates <- get(lens, idx_lens); method <- "lens_id"
  } else if (nzchar(doi) && exists(doi, idx_doi, inherits = FALSE)) {
    candidates <- get(doi, idx_doi); method <- "doi"
  } else if (nzchar(title) && exists(title, idx_title, inherits = FALSE)) {
    candidates <- get(title, idx_title); method <- "exact_title"
  } else if (nchar(absn) >= 200 && exists(absn, idx_abs, inherits = FALSE)) {
    candidates <- get(absn, idx_abs); method <- "exact_abstract"
  }

  if (length(candidates) == 1L) {
    resolved[[length(resolved)+1L]] <- entry(h, candidates, method); bump(method); next
  }
  if (length(candidates) > 1L) {
    ambiguous[[length(ambiguous)+1L]] <- entry(h, candidates, paste0("ambiguous_", method)); next
  }

  pool <- if (nzchar(year) && exists(year, by_year, inherits = FALSE)) get(year, by_year) else seq_along(canon)
  if (!nzchar(title) || nchar(title) < 20 || !length(pool)) {
    still[[length(still)+1L]] <- c(h, list(second_pass_reason = "insufficient_safe_metadata")); next
  }

  scored <- list()
  for (j in pool) {
    cc <- canon[[j]]
    if (!nzchar(cc$title_norm)) next
    s <- seq_sim(title, cc$title_norm)
    jac <- token_jaccard(title, cc$title_norm)
    if (s < 0.90 && jac < 0.80) next
    ao <- author_overlap(authors, cc$authors)
    se <- nzchar(norm_text(source)) && identical(norm_text(source), norm_text(cc$source))
    abs_s <- if (nchar(absn) >= 200 && nchar(cc$abstract_norm) >= 200) seq_sim(absn, cc$abstract_norm) else NA_real_
    abs_j <- if (nchar(absn) >= 200 && nchar(cc$abstract_norm) >= 200) token_jaccard(absn, cc$abstract_norm) else NA_real_
    score <- 0.58*s + 0.17*jac + 0.10*ao + 0.03*as.numeric(se)
    if (!is.na(abs_s)) score <- score + 0.08*abs_s + 0.04*abs_j
    scored[[length(scored)+1L]] <- list(j=j, score=score, s=s, jac=jac, ao=ao, se=se, abs_s=abs_s, abs_j=abs_j)
  }
  if (!length(scored)) {
    still[[length(still)+1L]] <- c(h, list(second_pass_reason = "no_candidate")); next
  }

  ord <- order(vapply(scored, function(x) x$score, numeric(1)), decreasing = TRUE)
  scored <- scored[ord]
  best <- scored[[1]]
  margin <- best$score - if (length(scored) > 1) scored[[2]]$score else 1
  accept <- (best$s >= 0.975 && best$jac >= 0.92 && margin >= 0.02) ||
            (!is.na(best$abs_s) && best$s >= 0.94 && best$jac >= 0.87 &&
             best$abs_s >= 0.94 && best$abs_j >= 0.87 && margin >= 0.015) ||
            (best$s >= 0.95 && best$jac >= 0.89 && best$ao >= 0.5 && margin >= 0.025)
  review <- best$s >= 0.92 && best$jac >= 0.84
  metrics <- list(
    title_sequence_similarity = best$s,
    title_token_jaccard = best$jac,
    author_overlap = best$ao,
    source_exact = best$se,
    abstract_sequence_similarity = if (is.na(best$abs_s)) NULL else best$abs_s,
    abstract_token_jaccard = if (is.na(best$abs_j)) NULL else best$abs_j,
    margin_to_second = margin
  )

  if (accept) {
    resolved[[length(resolved)+1L]] <- entry(h, best$j, "strong_bibliographic_similarity", metrics)
    bump("strong_bibliographic_similarity")
  } else if (review) {
    top <- vapply(scored[seq_len(min(3, length(scored)))], function(x) x$j, integer(1))
    ambiguous[[length(ambiguous)+1L]] <- entry(h, top, "review_bibliographic_similarity", metrics)
  } else {
    still[[length(still)+1L]] <- c(h, list(second_pass_reason = "below_safe_threshold", best_candidate_lens_id = canon[[best$j]]$lens_id, metrics = metrics))
  }
  if (k %% 100L == 0L) message(sprintf("Second pass: %d/690", k))
}

write_jsonl(file.path(out_dir, "high_confidence_matches.jsonl"), resolved)
write_jsonl(file.path(out_dir, "ambiguous_matches.jsonl"), ambiguous)
write_jsonl(file.path(out_dir, "still_unmatched.jsonl"), still)

summary <- list(
  workflow = "second_pass_unmatched_master_includes",
  audit_only = TRUE,
  canonical_modified = FALSE,
  targets = length(targets),
  high_confidence_matches = length(resolved),
  match_method_counts = counts,
  ambiguous_for_review = length(ambiguous),
  still_unmatched = length(still)
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE), file.path(out_dir, "summary.json"))
message(toJSON(summary, auto_unbox = TRUE, pretty = TRUE))
message("PASS: audit-only second-pass matching complete; canonical JSON was not modified.")
