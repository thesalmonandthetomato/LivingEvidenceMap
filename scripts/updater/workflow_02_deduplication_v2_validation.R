#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
  library(digest)
  library(xml2)
  library(stringi)
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
output_dir <- arg("--output-dir")
sample_n <- as.integer(arg("--sample-n", "2000"))
sample_key <- arg("--sample-key", "workflow02-v2-validation-2000-v1")
workflow01_run_id <- arg("--workflow01-run-id", "unknown")

if (any(vapply(list(lens_path, scopus_path, openalex_path, agricola_path, output_dir), is.null, logical(1)))) {
  stop("Required: --lens --scopus --openalex --agricola --output-dir", call. = FALSE)
}
if (is.na(sample_n) || sample_n < 1L) stop("--sample-n must be a positive integer", call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

timestamp_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
progress <- function(stage, completed = NULL, total = NULL, extra = NULL) {
  msg <- paste0("[", timestamp_utc(), "] ", stage)
  if (!is.null(completed)) {
    msg <- paste0(msg, ": ", completed)
    if (!is.null(total)) msg <- paste0(msg, " / ", total)
  }
  if (!is.null(extra) && nzchar(extra)) msg <- paste0(msg, " | ", extra)
  cat(msg, "\n")
  flush.console()
}
write_checkpoint <- function(stage, completed = NULL, total = NULL, extra = list()) {
  chk <- c(list(
    workflow = "02_deduplication_v2_validation",
    updated_at = timestamp_utc(),
    stage = stage,
    completed = completed,
    total = total
  ), extra)
  writeLines(
    toJSON(chk, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
    file.path(output_dir, "checkpoint_progress.json")
  )
}
progress("validation started")
write_checkpoint("validation_started")

scalar <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  y <- as.character(x[[1L]])
  if (!nzchar(trimws(y))) NULL else y
}

strip_markup_text <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  wrapped <- paste0("<div>", x, "</div>")
  doc <- tryCatch(
    suppressWarnings(read_html(wrapped, options = c("RECOVER", "NOERROR", "NOWARNING"))),
    error = function(e) NULL
  )
  if (!is.null(doc)) {
    node <- xml_find_first(doc, ".//div")
    if (!inherits(node, "xml_missing")) x <- xml_text(node)
  }
  x <- stri_replace_all_fixed(x, c("&nbsp;", "&#160;"), " ", vectorize_all = FALSE)
  x
}

unicode_nfkc_lower <- function(x) {
  x <- strip_markup_text(x)
  if (is.null(x)) return(NULL)
  x <- stri_trans_nfkc(x)
  x <- stri_trans_tolower(x)
  x
}

norm_title <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  # Ignore punctuation and whitespace, but preserve native-script letters/numbers.
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{Z}\\s]+", "")
  x <- trimws(x)
  if (!nzchar(x)) NULL else x
}

norm_words <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  # Abstract/journal comparison retains token boundaries.
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{S}\\p{Z}\\s]+", " ")
  x <- trimws(stri_replace_all_regex(x, "\\s+", " "))
  if (!nzchar(x)) NULL else x
}

norm_field_compact <- function(x) {
  x <- unicode_nfkc_lower(x)
  if (is.null(x)) return(NULL)
  x <- stri_replace_all_regex(x, "[\\p{P}\\p{S}\\p{Z}\\s]+", "")
  if (!nzchar(x)) NULL else x
}

norm_doi <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, perl = TRUE)
  x <- sub("^doi:\\s*", "", x, perl = TRUE)
  x <- sub("[?#].*$", "", x, perl = TRUE)
  x <- sub("/full/html?$", "", x, perl = TRUE, ignore.case = TRUE)
  x <- sub("\\.(html?|pdf|xml)$", "", x, perl = TRUE, ignore.case = TRUE)
  x <- sub("[.,;:]+$", "", x, perl = TRUE)
  if (!nzchar(x)) NULL else x
}

doi_family <- function(x) {
  x <- norm_doi(x)
  if (is.null(x)) return(NULL)
  sub("(/v[0-9]+|\\.v[0-9]+)$", "", x, perl = TRUE, ignore.case = TRUE)
}

norm_pages <- function(x) norm_field_compact(x)

normalise_author_piece <- function(a) {
  if (is.null(a)) return(NULL)
  if (is.character(a)) return(norm_field_compact(a[[1L]]))
  if (is.list(a)) {
    surname <- scalar(a$surname %||% a$last_name %||% a$family)
    given <- scalar(a$given_name %||% a$first_name %||% a$given)
    display <- scalar(a$display_name %||% a$name %||% a$full_name)
    if (!is.null(surname) || !is.null(given)) return(norm_field_compact(paste(surname %||% "", given %||% "")))
    return(norm_field_compact(display))
  }
  NULL
}

author_norm <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  if (is.character(x) && length(x) == 1L) {
    parts <- unlist(strsplit(x, "\\||;", perl = TRUE))
    vals <- vapply(parts, function(z) norm_field_compact(z) %||% "", character(1))
  } else if (is.character(x)) {
    vals <- vapply(as.list(x), function(z) norm_field_compact(z) %||% "", character(1))
  } else if (is.list(x)) {
    vals <- vapply(x, function(z) normalise_author_piece(z) %||% "", character(1))
  } else return(NULL)
  vals <- vals[nzchar(vals)]
  if (!length(vals)) NULL else paste(vals, collapse = "|")
}

first_author_norm <- function(x) {
  a <- author_norm(x)
  if (is.null(a)) return(NULL)
  strsplit(a, "\\|", perl = TRUE)[[1L]][1L]
}

source_kind <- function(r) {
  if (is.list(r$lens)) return("lens")
  p <- scalar((r$source %||% list())$provider)
  if (identical(p, "scopus")) return("scopus")
  if (identical(p, "openalex")) return("openalex")
  if (identical(p, "agricola_via_europe_pmc")) return("agricola")
  stop(sprintf("Unknown source provider: %s", p %||% "<missing>"), call. = FALSE)
}

source_record_id <- function(r) {
  if (source_kind(r) == "lens") return(as.character((r$identity %||% list())$lens_id %||% (r$identity %||% list())$record_id %||% ""))
  as.character((r$sidecar_identity %||% list())$sidecar_record_id %||% "")
}

record_doi_raw <- function(r) {
  if (source_kind(r) == "lens") {
    d <- scalar((r$canonical %||% list())$doi)
    if (!is.null(d)) return(d)
    ids <- ((r$lens %||% list())$raw_payload %||% list())$external_ids %||% list()
    for (z in ids) {
      if (is.list(z) && identical(tolower(as.character(z$type %||% "")), "doi")) {
        d <- scalar(z$value)
        if (!is.null(d)) return(d)
      }
    }
    return(NULL)
  }
  scalar((r$mapped_fields %||% list())$doi %||% (r$sidecar_identity %||% list())$doi)
}

record_title <- function(r) {
  if (source_kind(r) == "lens") return(scalar((r$canonical %||% list())$title %||% ((r$lens %||% list())$raw_payload %||% list())$title))
  scalar((r$mapped_fields %||% list())$title)
}

record_authors <- function(r) {
  if (source_kind(r) == "lens") return((r$canonical %||% list())$authors %||% ((r$lens %||% list())$raw_payload %||% list())$authors)
  (r$mapped_fields %||% list())$authors %||% (r$mapped_fields %||% list())$first_author
}

record_year <- function(r) {
  z <- if (source_kind(r) == "lens") {
    (r$canonical %||% list())$year %||% ((r$lens %||% list())$raw_payload %||% list())$year_published %||% ((r$lens %||% list())$raw_payload %||% list())$date_published
  } else (r$mapped_fields %||% list())$year %||% (r$mapped_fields %||% list())$publication_date
  m <- regexpr("(19|20)[0-9]{2}", as.character(z %||% ""), perl = TRUE)
  if (m[[1L]] < 0L) NA_integer_ else as.integer(regmatches(as.character(z), m)[[1L]])
}

record_journal <- function(r) {
  if (source_kind(r) == "lens") {
    s <- (r$canonical %||% list())$source %||% ((r$lens %||% list())$raw_payload %||% list())$source
    if (is.list(s)) return(scalar(s$title))
    return(scalar(s))
  }
  scalar((r$mapped_fields %||% list())$source %||% (r$mapped_fields %||% list())$journal)
}
record_volume <- function(r) {
  if (source_kind(r) == "lens") return(scalar((r$canonical %||% list())$volume %||% ((r$lens %||% list())$raw_payload %||% list())$volume))
  scalar((r$mapped_fields %||% list())$volume)
}
record_issue <- function(r) {
  if (source_kind(r) == "lens") return(scalar((r$canonical %||% list())$issue %||% ((r$lens %||% list())$raw_payload %||% list())$issue))
  scalar((r$mapped_fields %||% list())$issue)
}
record_pages <- function(r) {
  if (source_kind(r) == "lens") return(scalar((r$canonical %||% list())$pages %||% ((r$lens %||% list())$raw_payload %||% list())$pages))
  scalar((r$mapped_fields %||% list())$pages %||% (r$mapped_fields %||% list())$article_number)
}
record_abstract <- function(r) {
  if (source_kind(r) == "lens") return(scalar((r$canonical %||% list())$abstract %||% ((r$lens %||% list())$raw_payload %||% list())$abstract))
  scalar((r$mapped_fields %||% list())$abstract)
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
      fun(fromJSON(line, simplifyVector = FALSE), i)
    }
  }
  i
}

paths <- c(lens = lens_path, scopus = scopus_path, openalex = openalex_path, agricola = agricola_path)
rows <- list()
n_by_source <- integer()

for (src in names(paths)) {
  n_by_source[[src]] <- read_jsonl(paths[[src]], function(r, i) {
    rid <- source_record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s record %d lacks a source record ID", src, i), call. = FALSE)
    ttl <- record_title(r)
    abs <- record_abstract(r)
    auth <- record_authors(r)
    doi_raw <- record_doi_raw(r)
    rows[[length(rows) + 1L]] <<- data.frame(
      idx = length(rows) + 1L,
      source = src,
      source_record_id = rid,
      title = ttl %||% NA_character_,
      title_norm = norm_title(ttl) %||% NA_character_,
      doi_raw = doi_raw %||% NA_character_,
      doi_norm = norm_doi(doi_raw) %||% NA_character_,
      doi_family = doi_family(doi_raw) %||% NA_character_,
      abstract = abs %||% NA_character_,
      abstract_norm = norm_words(abs) %||% NA_character_,
      abstract_hash = if (is.null(norm_words(abs))) NA_character_ else digest(norm_words(abs), algo = "sha256", serialize = FALSE),
      author_norm = author_norm(auth) %||% NA_character_,
      first_author_norm = first_author_norm(auth) %||% NA_character_,
      year = record_year(r),
      journal_norm = norm_field_compact(record_journal(r)) %||% NA_character_,
      volume_norm = norm_field_compact(record_volume(r)) %||% NA_character_,
      issue_norm = norm_field_compact(record_issue(r)) %||% NA_character_,
      pages_norm = norm_pages(record_pages(r)) %||% NA_character_,
      stringsAsFactors = FALSE
    )
  })
}

meta <- do.call(rbind, rows)
if (anyDuplicated(paste(meta$source, meta$source_record_id, sep = "::"))) stop("Duplicate source namespace + record IDs", call. = FALSE)
progress("input inventory complete", nrow(meta), nrow(meta), paste("sources:", paste(names(n_by_source), unname(n_by_source), collapse = "; ")))
write_checkpoint("input_inventory_complete", nrow(meta), nrow(meta), list(source_counts = as.list(n_by_source)))

sample_hash <- vapply(seq_len(nrow(meta)), function(i) {
  digest(paste(sample_key, meta$source[[i]], meta$source_record_id[[i]], sep = "|"), algo = "sha256", serialize = FALSE)
}, character(1))
anchor_idx <- order(sample_hash)[seq_len(min(sample_n, nrow(meta)))]
anchor_flag <- seq_len(nrow(meta)) %in% anchor_idx
progress("deterministic sample selected", length(anchor_idx), sample_n)
write_checkpoint("sample_selected", length(anchor_idx), sample_n, list(sample_key = sample_key))

pair_env <- new.env(hash = TRUE, parent = emptyenv())
add_pair <- function(i, j, block) {
  if (i == j) return(invisible(NULL))
  if (!anchor_flag[[i]] && !anchor_flag[[j]]) return(invisible(NULL))
  a <- min(i,j); b <- max(i,j); key <- paste(a,b,sep="::")
  if (!exists(key, pair_env, inherits = FALSE)) {
    assign(key, list(i=a,j=b,blocks=block), pair_env)
  } else {
    z <- get(key,pair_env,inherits=FALSE)
    z$blocks <- unique(c(z$blocks,block))
    assign(key,z,pair_env)
  }
}

add_anchor_block <- function(values, block_name) {
  ok <- which(!is.na(values) & nzchar(values))
  if (!length(ok)) return(list(groups=0L,pairs=0L))
  groups <- split(ok, values[ok])
  groups <- groups[lengths(groups)>1L]
  np <- 0L
  for (g in groups) {
    anchors <- g[anchor_flag[g]]
    if (!length(anchors)) next
    for (a in anchors) for (b in g[g != a]) { add_pair(a,b,block_name); np <- np + 1L }
  }
  list(groups=length(groups),pairs=np)
}

key_if_complete <- function(...) {
  xs <- list(...)
  n <- length(xs[[1L]])
  out <- rep(NA_character_, n)
  ok <- rep(TRUE,n)
  for (x in xs) ok <- ok & !is.na(x) & nzchar(as.character(x))
  if (any(ok)) out[ok] <- do.call(paste, c(lapply(xs, function(x) x[ok]), sep="::"))
  out
}

# Bramer A-G and exact-field candidate blocks, checkpointed after each block.
block_stats <- list()
run_block <- function(name, values) {
  progress(paste("candidate block", name, "started"))
  res <- add_anchor_block(values, name)
  block_stats[[name]] <<- res
  pair_count_now <- length(ls(pair_env, all.names = TRUE))
  progress(paste("candidate block", name, "complete"), res$pairs, NULL, paste("candidate pairs:", pair_count_now))
  write_checkpoint(
    paste0("candidate_block_", name, "_complete"),
    completed = pair_count_now,
    total = NULL,
    extra = list(block = name, block_result = res)
  )
}
run_block("bramer_A", key_if_complete(meta$author_norm, meta$year, meta$title_norm, meta$journal_norm))
run_block("bramer_B", key_if_complete(meta$author_norm, meta$year, meta$title_norm, meta$pages_norm))
run_block("bramer_C", key_if_complete(meta$title_norm, meta$volume_norm, meta$pages_norm))
run_block("bramer_D", key_if_complete(meta$author_norm, meta$volume_norm, meta$pages_norm))
run_block("bramer_E", key_if_complete(meta$year, meta$volume_norm, meta$issue_norm, meta$pages_norm))
run_block("bramer_F", meta$title_norm)
run_block("bramer_G", key_if_complete(meta$author_norm, meta$year))
run_block("exact_doi", meta$doi_norm)
run_block("doi_family", meta$doi_family)
run_block("exact_abstract", meta$abstract_hash)

# Near-title candidate discovery: shared Unicode-normalised 3-character shingles.
title_shingles <- function(x) {
  if (is.na(x) || !nzchar(x) || nchar(x, type="chars") < 3L) return(character())
  n <- nchar(x, type="chars")
  unique(vapply(seq_len(n-2L), function(i) substr(x,i,i+2L), character(1)))
}

shingle_index <- new.env(hash=TRUE,parent=emptyenv())
for (i in seq_len(nrow(meta))) {
  ss <- title_shingles(meta$title_norm[[i]])
  if (!length(ss)) next
  # deterministic sparse signature: at most 12 lexicographically hash-smallest shingles
  if (length(ss)>12L) {
    hs <- vapply(ss, function(s) digest(s,algo="xxhash64",serialize=FALSE), character(1))
    ss <- ss[order(hs)[seq_len(12L)]]
  }
  for (s in ss) {
    if (!exists(s,shingle_index,inherits=FALSE)) assign(s,i,shingle_index)
    else assign(s,unique(c(get(s,shingle_index,inherits=FALSE),i)),shingle_index)
  }
}
for (a in anchor_idx) {
  ss <- title_shingles(meta$title_norm[[a]])
  if (!length(ss)) next
  if (length(ss)>12L) {
    hs <- vapply(ss, function(s) digest(s,algo="xxhash64",serialize=FALSE), character(1))
    ss <- ss[order(hs)[seq_len(12L)]]
  }
  cand <- unique(unlist(lapply(ss, function(s) if (exists(s,shingle_index,inherits=FALSE)) get(s,shingle_index,inherits=FALSE) else integer()), use.names=FALSE))
  cand <- cand[cand != a]
  for (b in cand) add_pair(a,b,"title_shingle_signature")
}
progress("near-title candidate generation complete", length(anchor_idx), length(anchor_idx), paste("candidate pairs:", length(ls(pair_env, all.names = TRUE))))
write_checkpoint("near_title_candidate_generation_complete", length(ls(pair_env, all.names = TRUE)), NULL)

tokens <- function(x) {
  if (is.na(x) || !nzchar(x)) return(character())
  strsplit(x, " ", fixed=TRUE)[[1L]]
}
shingles5 <- function(t) {
  if (length(t)<5L) return(character())
  unique(vapply(seq_len(length(t)-4L), function(i) paste(t[i:(i+4L)],collapse=" "), character(1)))
}
lcs_len <- function(a,b) {
  if (!length(a) || !length(b)) return(0L)
  if (length(a)>length(b)) {tmp<-a;a<-b;b<-tmp}
  prev <- integer(length(b)+1L)
  cur <- integer(length(b)+1L)
  for (i in seq_along(a)) {
    cur[] <- 0L
    for (j in seq_along(b)) {
      if (identical(a[[i]],b[[j]])) cur[[j+1L]] <- prev[[j]]+1L
      else cur[[j+1L]] <- max(prev[[j+1L]],cur[[j]])
    }
    tmp<-prev;prev<-cur;cur<-tmp
  }
  prev[[length(b)+1L]]
}

abstract_metrics <- function(a,b) {
  ta <- tokens(a); tb <- tokens(b)
  shorter <- min(length(ta),length(tb))
  if (shorter==0L) return(list(shorter_tokens=0L,lcs_tokens=0L,ordered_coverage=NA_real_,shingle_containment=NA_real_,strong=FALSE))
  sa <- shingles5(ta); sb <- shingles5(tb)
  shc <- if (!length(sa) || !length(sb)) NA_real_ else length(intersect(sa,sb))/min(length(sa),length(sb))
  lcs <- lcs_len(ta,tb)
  oc <- lcs/shorter
  strong <- (lcs>=80L && oc>=0.90 && !is.na(shc) && shc>=0.60) ||
            (lcs>=60L && lcs<=79L && oc>=0.95 && !is.na(shc) && shc>=0.75)
  list(shorter_tokens=shorter,lcs_tokens=lcs,ordered_coverage=oc,shingle_containment=shc,strong=strong)
}

pair_keys <- ls(pair_env,all.names=TRUE)
out <- vector("list",length(pair_keys))
for (k in seq_along(pair_keys)) {
  if (k == 1L || k %% 1000L == 0L || k == length(pair_keys)) {
    progress("candidate pairs scored", k, length(pair_keys))
    write_checkpoint("candidate_pair_scoring", k, length(pair_keys))
  }
  z <- get(pair_keys[[k]],pair_env,inherits=FALSE)
  a <- meta[z$i,,drop=FALSE]; b <- meta[z$j,,drop=FALSE]
  same_doi <- !is.na(a$doi_norm) && !is.na(b$doi_norm) && identical(a$doi_norm,b$doi_norm)
  same_family <- !is.na(a$doi_family) && !is.na(b$doi_family) && identical(a$doi_family,b$doi_family)
  different_doi <- !is.na(a$doi_norm) && !is.na(b$doi_norm) && !identical(a$doi_norm,b$doi_norm)
  exact_title <- !is.na(a$title_norm) && !is.na(b$title_norm) && identical(a$title_norm,b$title_norm)
  title_sim <- if (!is.na(a$title_norm) && !is.na(b$title_norm)) as.numeric(stringsim(a$title_norm,b$title_norm,method="jw",p=0.1)) else NA_real_
  title_containment <- FALSE
  if (!is.na(a$title_norm) && !is.na(b$title_norm)) {
    short <- if (nchar(a$title_norm)<=nchar(b$title_norm)) a$title_norm else b$title_norm
    long <- if (nchar(a$title_norm)<=nchar(b$title_norm)) b$title_norm else a$title_norm
    title_containment <- nchar(short)>=30L && grepl(short,long,fixed=TRUE)
  }
  exact_abs <- !is.na(a$abstract_hash) && !is.na(b$abstract_hash) && identical(a$abstract_hash,b$abstract_hash)
  exact_author <- !is.na(a$author_norm) && !is.na(b$author_norm) && identical(a$author_norm,b$author_norm)
  exact_year <- !is.na(a$year) && !is.na(b$year) && identical(a$year,b$year)
  year_diff <- if (!is.na(a$year) && !is.na(b$year)) abs(a$year-b$year) else NA_integer_
  bramerA <- "bramer_A" %in% z$blocks
  bramerB <- "bramer_B" %in% z$blocks

  need_abs_metrics <- !exact_abs && !is.na(title_sim) && (title_sim>=0.90 || title_containment || exact_title)
  am <- if (need_abs_metrics && !is.na(a$abstract_norm) && !is.na(b$abstract_norm)) abstract_metrics(a$abstract_norm,b$abstract_norm)
        else list(shorter_tokens=NA_integer_,lcs_tokens=NA_integer_,ordered_coverage=NA_real_,shingle_containment=NA_real_,strong=FALSE)
  strong_abs <- isTRUE(am$strong)

  potential_auto <- NULL
  if (bramerA) potential_auto <- "bramer_A"
  else if (bramerB) potential_auto <- "bramer_B"
  else if (same_doi && exact_title) potential_auto <- "exact_doi_exact_title"
  else if (exact_title && exact_abs) potential_auto <- "exact_title_exact_abstract"
  else if (same_doi && title_containment) potential_auto <- "exact_doi_title_containment"
  else if (same_doi && !is.na(title_sim) && title_sim>=0.985) potential_auto <- "exact_doi_title_similarity_0.985"
  else if (same_doi && exact_abs) potential_auto <- "exact_doi_exact_abstract"
  else if (exact_title && strong_abs) potential_auto <- "exact_title_strong_abstract"
  else if (title_containment && strong_abs) potential_auto <- "title_containment_strong_abstract"
  else if (!is.na(title_sim) && title_sim>=0.97 && strong_abs) potential_auto <- "title_similarity_0.97_strong_abstract"
  else if (!is.na(title_sim) && title_sim>=0.95 && exact_author && exact_year) potential_auto <- "title_similarity_0.95_exact_author_year"

  classification <- "unresolved"
  rule <- "candidate_only"

  # A genuinely different populated DOI is a material conflict for content/bibliographic
  # rules unless the exact DOI rule itself fired or the DOI-family relationship is known.
  if (!is.null(potential_auto)) {
    exact_doi_rule <- grepl("^exact_doi_",potential_auto)
    if (different_doi && !same_family && !exact_doi_rule) {
      classification <- "review"
      rule <- "material_conflict_different_doi"
    } else {
      classification <- "duplicate"
      rule <- potential_auto
    }
  } else if (exact_abs) {
    classification <- "review"
    rule <- "exact_abstract_insufficient_metadata"
  } else if (same_family && different_doi && !is.na(title_sim) && title_sim>=0.97) {
    classification <- "review"
    rule <- "doi_family_title_similarity_0.97"
  } else if (exact_title && !is.na(year_diff) && year_diff<=1L) {
    classification <- "review"
    rule <- "exact_title_year_within_1"
  } else if (strong_abs && different_doi && !same_family) {
    classification <- "review"
    rule <- "strong_content_material_doi_conflict"
  }

  out[[k]] <- data.frame(
    record_i=z$i,record_j=z$j,
    anchor_i=anchor_flag[[z$i]],anchor_j=anchor_flag[[z$j]],
    source_i=a$source,source_j=b$source,
    source_record_id_i=a$source_record_id,source_record_id_j=b$source_record_id,
    title_i=a$title,title_j=b$title,
    doi_i=a$doi_norm,doi_j=b$doi_norm,
    year_i=a$year,year_j=b$year,
    blocks=paste(sort(unique(z$blocks)),collapse=";"),
    title_similarity=round(title_sim,6),
    exact_title=exact_title,
    title_containment=title_containment,
    exact_abstract=exact_abs,
    ordered_coverage=round(am$ordered_coverage,6),
    shingle_containment=round(am$shingle_containment,6),
    lcs_tokens=am$lcs_tokens,
    strong_abstract=strong_abs,
    different_populated_doi=different_doi,
    same_doi_family=same_family,
    classification=classification,
    rule=rule,
    stringsAsFactors=FALSE
  )
}
pairs <- if (length(out)) do.call(rbind,out) else data.frame()

write.csv(meta[anchor_idx,c("idx","source","source_record_id","title","doi_norm","year")],
          file.path(output_dir,"sampled_anchors.csv"),row.names=FALSE,na="")
write.csv(pairs,file.path(output_dir,"candidate_pairs.csv"),row.names=FALSE,na="")
write.csv(pairs[pairs$classification=="duplicate",,drop=FALSE],
          file.path(output_dir,"automatic_duplicates.csv"),row.names=FALSE,na="")
write.csv(pairs[pairs$classification=="review",,drop=FALSE],
          file.path(output_dir,"manual_review_candidates.csv"),row.names=FALSE,na="")
progress(
  "classification outputs written",
  nrow(pairs),
  nrow(pairs),
  paste("duplicates:", sum(pairs$classification=="duplicate"), "review:", sum(pairs$classification=="review"), "unresolved:", sum(pairs$classification=="unresolved"))
)
write_checkpoint(
  "classification_outputs_written",
  nrow(pairs),
  nrow(pairs),
  list(
    duplicate_pairs = sum(pairs$classification=="duplicate"),
    review_pairs = sum(pairs$classification=="review"),
    unresolved_pairs = sum(pairs$classification=="unresolved")
  )
)

rule_counts <- if (nrow(pairs)) as.list(table(pairs$rule)) else list()
class_counts <- if (nrow(pairs)) as.list(table(pairs$classification)) else list()
summary <- list(
  workflow="02_deduplication_v2_validation",
  status="success",
  workflow01_run_id=workflow01_run_id,
  sample_key=sample_key,
  requested_sample_n=sample_n,
  sampled_anchor_count=length(anchor_idx),
  total_source_manifestations=nrow(meta),
  source_counts=as.list(n_by_source),
  historic_human_adjudications_loaded=FALSE,
  candidate_pair_count=nrow(pairs),
  classification_counts=class_counts,
  rule_counts=rule_counts,
  block_stats=block_stats,
  safeguards=list(
    source_payloads_modified=FALSE,
    canonical_modified=FALSE,
    clustering_performed=FALSE,
    human_decisions_applied=FALSE
  )
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")
progress("validation complete", nrow(pairs), nrow(pairs))
write_checkpoint("complete", nrow(pairs), nrow(pairs), list(status = "success"))
