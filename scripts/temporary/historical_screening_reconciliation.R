suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
  library(stringdist)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("ERROR: missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

master_path <- arg("--master")
canonical_path <- arg("--canonical")
includes_ris_path <- arg("--includes-ris")
excludes_ris_path <- arg("--excludes-ris")
out_dir <- arg("--out-dir", "outputs/historical_reconciliation")
checkpoint_every <- as.integer(arg("--checkpoint-every", "500"))

required <- c(master_path, canonical_path, includes_ris_path, excludes_ris_path)
if (any(vapply(required, is.null, logical(1)))) {
  stop("ERROR: --master, --canonical, --includes-ris and --excludes-ris are required", call. = FALSE)
}
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop("ERROR: --checkpoint-every must be a positive integer", call. = FALSE)
for (p in required) if (!file.exists(p)) stop(sprintf("ERROR: required input file not found: %s", p), call. = FALSE)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
checkpoint_dir <- file.path(out_dir, "checkpoints")
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

normalise_unicode <- function(x) {
  x <- as.character(x %||% "")
  x[is.na(x)] <- ""
  x <- iconv(x, from = "", to = "UTF-8", sub = "")
  x <- gsub("[\u2018\u2019\u02BC]", "'", x, perl = TRUE)
  x <- gsub("[\u201C\u201D]", "\"", x, perl = TRUE)
  x <- gsub("[\u2010\u2011\u2012\u2013\u2014\u2212]", "-", x, perl = TRUE)
  x <- gsub("&amp;", "&", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;|&apos;", "'", x, perl = TRUE)
  x
}

norm_text <- function(x) {
  x <- tolower(normalise_unicode(x))
  x <- gsub("<[^>]+>", " ", x, perl = TRUE)
  x <- gsub("[^[:alnum:] ]+", " ", x, perl = TRUE)
  x <- gsub("\\s+", " ", x, perl = TRUE)
  trimws(x)
}

norm_abstract <- function(x) {
  x <- tolower(normalise_unicode(x))
  x <- gsub("<[^>]+>", " ", x, perl = TRUE)
  x <- gsub("\\s+", " ", x, perl = TRUE)
  trimws(x)
}

normalise_doi <- function(x) {
  if (is.null(x) || !length(x)) return("")
  x <- as.character(x)[1]
  if (is.na(x)) return("")
  x <- tolower(trimws(x))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, perl = TRUE)
  x <- sub("^doi:\\s*", "", x, perl = TRUE)
  x <- sub("[[:space:].,;:]+$", "", x, perl = TRUE)
  x
}

normalise_year <- function(x) {
  x <- as.character(x %||% "")
  m <- regmatches(x, regexpr("(18|19|20|21)[0-9]{2}", x, perl = TRUE))
  ifelse(length(m) && nzchar(m), m, "")
}

index_key <- function(x) {
  x <- as.character(x %||% "")
  if (!length(x) || !nzchar(x[1])) return("")
  paste0("sha256:", digest(x[1], algo = "sha256", serialize = FALSE))
}

extract_lens_id <- function(x) {
  if (is.null(x) || !length(x)) return("")
  x <- paste(as.character(x), collapse = " ")
  m <- regexpr("[0-9]{3}-[0-9]{3}-[0-9]{3}-[0-9]{3}-[0-9]{3}", x, perl = TRUE)
  if (m[1] < 0) return("")
  regmatches(x, m)[1]
}

seq_similarity <- function(a, b) {
  if (!nzchar(a) || !nzchar(b)) return(NA_real_)
  d <- stringdist(a, b, method = "lv")
  1 - d / max(nchar(a), nchar(b), 1L)
}

token_jaccard <- function(a, b) {
  if (!nzchar(a) || !nzchar(b)) return(NA_real_)
  aa <- unique(strsplit(norm_text(a), " ", fixed = TRUE)[[1]])
  bb <- unique(strsplit(norm_text(b), " ", fixed = TRUE)[[1]])
  aa <- aa[nzchar(aa)]; bb <- bb[nzchar(bb)]
  if (!length(aa) || !length(bb)) return(NA_real_)
  length(intersect(aa, bb)) / length(union(aa, bb))
}

safe_write_json <- function(obj, path, pretty = TRUE) {
  tmp <- paste0(path, ".tmp")
  writeLines(toJSON(obj, auto_unbox = TRUE, null = "null", na = "null", pretty = pretty), tmp, useBytes = TRUE)
  if (!file.rename(tmp, path)) stop(sprintf("ERROR: failed to atomically write %s", path), call. = FALSE)
}

write_json_line <- function(x, con) {
  writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con, useBytes = TRUE)
}

write_checkpoint <- function(phase, processed, total, extra = list()) {
  payload <- c(list(
    workflow = "temporary_historical_screening_reconciliation",
    implementation_language = "R",
    phase = phase,
    processed = processed,
    total = total,
    updated_at = now_utc()
  ), extra)
  safe_write_json(payload, file.path(checkpoint_dir, "checkpoint_manifest.json"))
}

parse_ris <- function(path, decision, source_name) {
  message(sprintf("Parsing %s", path))
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  records <- list()
  current <- list()
  add_field <- function(tag, value) {
    if (is.null(current[[tag]])) current[[tag]] <<- value else current[[tag]] <<- c(current[[tag]], value)
  }
  flush_record <- function() {
    if (!length(current)) return()
    getv <- function(tags) {
      vals <- unlist(current[intersect(tags, names(current))], use.names = FALSE)
      vals <- vals[!is.na(vals) & nzchar(trimws(vals))]
      if (!length(vals)) "" else paste(vals, collapse = " ")
    }
    ur <- getv(c("UR", "L1", "L2"))
    rec <- list(
      source = source_name,
      decision = decision,
      lens_id = extract_lens_id(c(ur, getv(c("ID", "AN")))),
      doi = normalise_doi(getv(c("DO", "DI"))),
      title = getv(c("TI", "T1", "CT")),
      abstract = getv(c("AB", "N2")),
      year = normalise_year(getv(c("PY", "Y1", "DA"))),
      journal = getv(c("JO", "JF", "T2", "JA")),
      ris_note = getv(c("N1", "N3"))
    )
    rec$title_norm <- norm_text(rec$title)
    rec$abstract_norm <- norm_abstract(rec$abstract)
    rec$journal_norm <- norm_text(rec$journal)
    records[[length(records) + 1L]] <<- rec
    current <<- list()
  }
  for (i in seq_along(lines)) {
    line <- lines[[i]]
    if (grepl("^ER  -", line)) {
      flush_record()
    } else if (grepl("^[A-Z0-9]{2}  - ", line)) {
      tag <- substr(line, 1, 2)
      value <- sub("^[A-Z0-9]{2}  - ", "", line)
      add_field(tag, value)
    } else if (length(current) && nzchar(trimws(line))) {
      tags <- names(current)
      if (length(tags)) {
        tag <- tail(tags, 1)
        vals <- current[[tag]]
        vals[length(vals)] <- paste(vals[length(vals)], trimws(line))
        current[[tag]] <- vals
      }
    }
    if (i %% 10000L == 0L || i == length(lines)) message(sprintf("RIS parse %s: %d/%d lines", basename(path), i, length(lines)))
  }
  flush_record()
  records
}

message("Loading historical production master header")
header <- names(fread(master_path, nrows = 0L, check.names = FALSE))
norm_names <- norm_text(header)
find_col <- function(exact = character(), regex = NULL, required = FALSE, label = "field") {
  exact_norm <- norm_text(exact)
  idx <- match(exact_norm, norm_names, nomatch = 0L)
  idx <- idx[idx > 0L]
  if (length(idx)) return(header[idx[1]])
  if (!is.null(regex)) {
    hits <- grep(regex, norm_names, perl = TRUE)
    if (length(hits)) return(header[hits[1]])
  }
  if (required) stop(sprintf("ERROR: could not identify required master %s column. Available columns: %s", label, paste(header, collapse = " | ")), call. = FALSE)
  NA_character_
}

master_cols <- list(
  lens = find_col(c("lens_id", "lens id", "record_id", "record id"), "(^| )lens( |$)|^record id$", FALSE, "Lens ID"),
  doi = find_col(c("doi", "DOI"), "(^| )doi( |$)", FALSE, "DOI"),
  title = find_col(c("title", "Title"), "(^| )title( |$)", TRUE, "title"),
  abstract = find_col(c("abstract", "Abstract"), "(^| )abstract( |$)", FALSE, "abstract"),
  year = find_col(c("year", "publication_year", "publication year", "date"), "(^| )(year|publication year)( |$)", FALSE, "year"),
  journal = find_col(c("journal", "journal title", "source title", "publication"), "(^| )(journal|source title|publication)( |$)", FALSE, "journal")
)
select_cols <- unique(na.omit(unlist(master_cols, use.names = FALSE)))
message(sprintf("Master columns selected: %s", paste(select_cols, collapse = " | ")))
master <- fread(master_path, select = select_cols, encoding = "UTF-8", showProgress = TRUE, check.names = FALSE)
master_n <- nrow(master)
if (!master_n) stop("ERROR: historical master contains zero records", call. = FALSE)
get_master <- function(col) {
  if (is.na(col)) return(rep("", master_n))
  x <- as.character(master[[col]])
  x[is.na(x)] <- ""
  x
}
master_rows <- vector("list", master_n)
for (i in seq_len(master_n)) {
  lens_raw <- get_master(master_cols$lens)[i]
  master_rows[[i]] <- list(
    source = "production_master",
    source_row = i,
    decision = "include",
    lens_id = extract_lens_id(lens_raw),
    doi = normalise_doi(get_master(master_cols$doi)[i]),
    title = get_master(master_cols$title)[i] %||% "",
    abstract = get_master(master_cols$abstract)[i] %||% "",
    year = normalise_year(get_master(master_cols$year)[i]),
    journal = get_master(master_cols$journal)[i] %||% ""
  )
  master_rows[[i]]$title_norm <- norm_text(master_rows[[i]]$title)
  master_rows[[i]]$abstract_norm <- norm_abstract(master_rows[[i]]$abstract)
  master_rows[[i]]$journal_norm <- norm_text(master_rows[[i]]$journal)
}
message(sprintf("Loaded %d production-master rows; all treated as historical include/retain decisions", master_n))
write_checkpoint("master_loaded", master_n, master_n, list(master_columns = master_cols))

includes <- parse_ris(includes_ris_path, "include", "includes_ris")
excludes <- parse_ris(excludes_ris_path, "exclude", "excludes_ris")
message(sprintf("RIS counts: includes=%d excludes=%d", length(includes), length(excludes)))
write_checkpoint("ris_loaded", length(includes) + length(excludes), length(includes) + length(excludes), list(includes = length(includes), excludes = length(excludes)))

make_index <- function(records, field) {
  env <- new.env(hash = TRUE, parent = emptyenv())
  for (i in seq_along(records)) {
    raw_key <- as.character(records[[i]][[field]] %||% "")
    if (!nzchar(raw_key)) next
    key <- index_key(raw_key)
    old <- if (exists(key, env, inherits = FALSE)) get(key, env) else integer()
    assign(key, c(old, i), env)
  }
  env
}
inc_lens <- make_index(includes, "lens_id")
inc_doi <- make_index(includes, "doi")
inc_title_year <- new.env(hash = TRUE, parent = emptyenv())
for (i in seq_along(includes)) {
  r <- includes[[i]]
  if (!nzchar(r$title_norm) || !nzchar(r$year)) next
  key <- index_key(paste(r$title_norm, r$year, sep = "\u241F"))
  old <- if (exists(key, inc_title_year, inherits = FALSE)) get(key, inc_title_year) else integer()
  assign(key, c(old, i), inc_title_year)
}

enrichment_path <- file.path(out_dir, "master_ris_enrichment_audit.jsonl")
enrich_con <- file(enrichment_path, "wt", encoding = "UTF-8")
on.exit(try(close(enrich_con), silent = TRUE), add = TRUE)
enriched_count <- 0L
ambiguous_enrichment <- 0L
for (i in seq_along(master_rows)) {
  m <- master_rows[[i]]
  candidates <- integer()
  method <- NULL
  if (nzchar(m$lens_id) && exists(index_key(m$lens_id), inc_lens, inherits = FALSE)) {
    candidates <- get(index_key(m$lens_id), inc_lens)
    candidates <- candidates[vapply(includes[candidates], function(x) identical(x$lens_id, m$lens_id), logical(1))]
    if (length(candidates)) method <- "lens_id"
  } else if (nzchar(m$doi) && exists(index_key(m$doi), inc_doi, inherits = FALSE)) {
    candidates <- get(index_key(m$doi), inc_doi)
    candidates <- candidates[vapply(includes[candidates], function(x) identical(x$doi, m$doi), logical(1))]
    if (length(candidates)) method <- "doi"
  } else if (nzchar(m$title_norm) && nzchar(m$year)) {
    key <- index_key(paste(m$title_norm, m$year, sep = "\u241F"))
    if (exists(key, inc_title_year, inherits = FALSE)) {
      candidates <- get(key, inc_title_year)
      candidates <- candidates[vapply(includes[candidates], function(x) identical(x$title_norm, m$title_norm) && identical(x$year, m$year), logical(1))]
      if (length(candidates)) method <- "title_year"
    }
  }
  if (length(candidates) == 1L) {
    r <- includes[[candidates]]
    original <- m
    for (field in c("lens_id", "doi", "title", "abstract", "year", "journal")) {
      if (!nzchar(as.character(m[[field]] %||% "")) && nzchar(as.character(r[[field]] %||% ""))) m[[field]] <- r[[field]]
    }
    m$title_norm <- norm_text(m$title); m$abstract_norm <- norm_abstract(m$abstract); m$journal_norm <- norm_text(m$journal)
    m$ris_bridge <- list(source = "includes_ris", ris_row = candidates, method = method)
    master_rows[[i]] <- m
    enriched_count <- enriched_count + 1L
    write_json_line(list(master_row = i, status = "enriched", method = method, ris_row = candidates,
                         fields_added = c(
                           if (!nzchar(original$lens_id) && nzchar(m$lens_id)) "lens_id" else NULL,
                           if (!nzchar(original$doi) && nzchar(m$doi)) "doi" else NULL,
                           if (!nzchar(original$abstract) && nzchar(m$abstract)) "abstract" else NULL,
                           if (!nzchar(original$year) && nzchar(m$year)) "year" else NULL,
                           if (!nzchar(original$journal) && nzchar(m$journal)) "journal" else NULL
                         )), enrich_con)
  } else if (length(candidates) > 1L) {
    ambiguous_enrichment <- ambiguous_enrichment + 1L
    write_json_line(list(master_row = i, status = "ambiguous", method = method, ris_rows = candidates), enrich_con)
  }
  if (i %% checkpoint_every == 0L || i == length(master_rows)) {
    flush(enrich_con)
    message(sprintf("INCLUDES RIS enrichment: %d/%d master rows; enriched=%d ambiguous=%d", i, length(master_rows), enriched_count, ambiguous_enrichment))
    write_checkpoint("master_ris_enrichment", i, length(master_rows), list(enriched = enriched_count, ambiguous = ambiguous_enrichment))
  }
}
close(enrich_con)

message("Loading canonical JSONL into a minimal matching index")
canonical <- list()
con <- file(canonical_path, "rt", encoding = "UTF-8")
on.exit(try(close(con), silent = TRUE), add = TRUE)
i <- 0L
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next
  i <- i + 1L
  rec <- tryCatch(fromJSON(line, simplifyVector = FALSE), error = function(e) stop(sprintf("ERROR: invalid canonical JSON at record %d: %s", i, conditionMessage(e)), call. = FALSE))
  can <- rec$canonical %||% list()
  lens <- as.character((rec$identity %||% list())$lens_id %||% rec$record_id %||% "")
  if (!nzchar(lens)) stop(sprintf("ERROR: canonical record %d lacks Lens ID", i), call. = FALSE)
  r <- list(
    canonical_row = i,
    lens_id = lens,
    doi = normalise_doi(can$doi %||% ""),
    title = as.character(can$title %||% ""),
    abstract = as.character(can$abstract %||% ""),
    year = normalise_year(can$year %||% can$publication_year %||% ""),
    journal = as.character(can$journal %||% can$source_title %||% ""),
    dedup_downstream_eligible = identical((rec$deduplication %||% list())$downstream_eligible, TRUE),
    notice_type = as.character((rec$notices %||% list())$type %||% "")
  )
  r$title_norm <- norm_text(r$title); r$abstract_norm <- norm_abstract(r$abstract); r$journal_norm <- norm_text(r$journal)
  canonical[[i]] <- r
  if (i %% 1000L == 0L) message(sprintf("Canonical index: %d records", i))
}
close(con)
canonical_n <- length(canonical)
if (!canonical_n) stop("ERROR: canonical JSON contains zero records", call. = FALSE)
canon_ids <- vapply(canonical, `[[`, character(1), "lens_id")
if (anyDuplicated(canon_ids)) stop(sprintf("ERROR: duplicate Lens ID in canonical: %s", canon_ids[duplicated(canon_ids)][1]), call. = FALSE)
message(sprintf("Canonical index complete: %d records", canonical_n))
write_checkpoint("canonical_loaded", canonical_n, canonical_n)

c_lens <- make_index(canonical, "lens_id")
c_doi <- make_index(canonical, "doi")
c_abs <- make_index(canonical, "abstract_norm")
c_title <- make_index(canonical, "title_norm")
c_title_year_journal <- new.env(hash = TRUE, parent = emptyenv())
for (j in seq_along(canonical)) {
  r <- canonical[[j]]
  if (!nzchar(r$title_norm) || !nzchar(r$year) || !nzchar(r$journal_norm)) next
  key <- index_key(paste(r$title_norm, r$year, r$journal_norm, sep = "\u241F"))
  old <- if (exists(key, c_title_year_journal, inherits = FALSE)) get(key, c_title_year_journal) else integer()
  assign(key, c(old, j), c_title_year_journal)
}

for (k in seq_along(excludes)) excludes[[k]]$source_row <- k
historical <- c(master_rows, excludes)
historical_n <- length(historical)
message(sprintf("Historical decision universe: %d include/retain master rows + %d exclude RIS rows = %d", length(master_rows), length(excludes), historical_n))

matches_path <- file.path(out_dir, "matched_records.jsonl")
unmatched_path <- file.path(out_dir, "unmatched_historical_records.jsonl")
ambiguous_path <- file.path(out_dir, "ambiguous_matches.jsonl")
conflicts_path <- file.path(out_dir, "conflicts.jsonl")
for (p in c(matches_path, unmatched_path, ambiguous_path, conflicts_path)) if (file.exists(p)) file.remove(p)
match_con <- file(matches_path, "wt", encoding = "UTF-8")
unmatched_con <- file(unmatched_path, "wt", encoding = "UTF-8")
ambig_con <- file(ambiguous_path, "wt", encoding = "UTF-8")
conflict_con <- file(conflicts_path, "wt", encoding = "UTF-8")
on.exit({ try(close(match_con), silent=TRUE); try(close(unmatched_con), silent=TRUE); try(close(ambig_con), silent=TRUE); try(close(conflict_con), silent=TRUE) }, add = TRUE)

method_counts <- integer(); names(method_counts) <- character()
status_counts <- c(matched = 0L, unmatched = 0L, ambiguous = 0L, conflict = 0L)
accepted <- vector("list", historical_n)

emit_conflict <- function(h, method, candidates, reason, metrics = NULL) {
  status_counts[["conflict"]] <<- status_counts[["conflict"]] + 1L
  write_json_line(list(historical_source = h$source, historical_row = h$source_row %||% NA_integer_, decision = h$decision,
                       method = method, reason = reason, historical = h,
                       candidate_lens_ids = vapply(canonical[candidates], `[[`, character(1), "lens_id"), metrics = metrics), conflict_con)
}

for (hi in seq_along(historical)) {
  h <- historical[[hi]]
  if (is.null(h$source_row)) h$source_row <- hi
  candidates <- integer(); method <- NULL; metrics <- NULL

  if (nzchar(h$lens_id) && exists(index_key(h$lens_id), c_lens, inherits = FALSE)) {
    candidates <- get(index_key(h$lens_id), c_lens)
    candidates <- candidates[vapply(canonical[candidates], function(x) identical(x$lens_id, h$lens_id), logical(1))]
    if (length(candidates)) method <- "lens_id"
  }

  if (!length(candidates) && nzchar(h$doi) && nzchar(h$title_norm) && exists(index_key(h$doi), c_doi, inherits = FALSE)) {
    doi_candidates <- get(index_key(h$doi), c_doi)
    doi_candidates <- doi_candidates[vapply(canonical[doi_candidates], function(x) identical(x$doi, h$doi), logical(1))]
    exact_title <- doi_candidates[vapply(canonical[doi_candidates], function(x) identical(x$title_norm, h$title_norm), logical(1))]
    if (length(exact_title)) { candidates <- exact_title; method <- "doi_title" }
    else {
      sims <- vapply(canonical[doi_candidates], function(x) seq_similarity(h$title_norm, x$title_norm), numeric(1))
      if (any(sims >= 0.97, na.rm = TRUE)) {
        near <- doi_candidates[which(sims >= 0.97)]
        emit_conflict(h, "doi_title", near, "DOI matched but title was not exact; manual review required", list(title_similarity = sims[sims >= 0.97]))
        accepted[[hi]] <- list(status = "conflict")
        next
      }
    }
  }

  if (!length(candidates) && nzchar(h$abstract_norm) && exists(index_key(h$abstract_norm), c_abs, inherits = FALSE)) {
    abs_candidates <- get(index_key(h$abstract_norm), c_abs)
    abs_candidates <- abs_candidates[vapply(canonical[abs_candidates], function(x) identical(x$abstract_norm, h$abstract_norm), logical(1))]
    contradictions <- abs_candidates[vapply(canonical[abs_candidates], function(x) nzchar(h$doi) && nzchar(x$doi) && !identical(h$doi, x$doi), logical(1))]
    clean <- setdiff(abs_candidates, contradictions)
    if (length(contradictions) && !length(clean)) {
      emit_conflict(h, "exact_abstract", contradictions, "Exact abstract matched but non-empty DOI contradicted")
      accepted[[hi]] <- list(status = "conflict")
      next
    }
    if (length(clean)) { candidates <- clean; method <- "exact_abstract" }
  }

  if (!length(candidates) && nzchar(h$title_norm) && nzchar(h$year) && nzchar(h$journal_norm)) {
    key <- index_key(paste(h$title_norm, h$year, h$journal_norm, sep = "\u241F"))
    if (exists(key, c_title_year_journal, inherits = FALSE)) {
      tyj_candidates <- get(key, c_title_year_journal)
      tyj_candidates <- tyj_candidates[vapply(canonical[tyj_candidates], function(x)
        identical(x$title_norm, h$title_norm) && identical(x$year, h$year) && identical(x$journal_norm, h$journal_norm), logical(1))]
      contradictions <- tyj_candidates[vapply(canonical[tyj_candidates], function(x) nzchar(h$doi) && nzchar(x$doi) && !identical(h$doi, x$doi), logical(1))]
      clean <- setdiff(tyj_candidates, contradictions)
      if (length(contradictions) && !length(clean)) {
        emit_conflict(h, "title_year_journal", contradictions, "Title/year/journal matched but non-empty DOI contradicted")
        accepted[[hi]] <- list(status = "conflict")
        next
      }
      if (length(clean)) { candidates <- clean; method <- "title_year_journal" }
    }
  }

  if (!length(candidates) && nzchar(h$title_norm) && nzchar(h$abstract_norm) && exists(index_key(h$title_norm), c_title, inherits = FALSE)) {
    title_candidates <- get(index_key(h$title_norm), c_title)
    title_candidates <- title_candidates[vapply(canonical[title_candidates], function(x) identical(x$title_norm, h$title_norm), logical(1))]
    contradiction_mask <- vapply(canonical[title_candidates], function(x) nzchar(h$doi) && nzchar(x$doi) && !identical(h$doi, x$doi), logical(1))
    clean <- title_candidates[!contradiction_mask]
    contradicted <- title_candidates[contradiction_mask]
    if (length(clean)) {
      seqs <- vapply(canonical[clean], function(x) seq_similarity(h$abstract_norm, x$abstract_norm), numeric(1))
      jacs <- vapply(canonical[clean], function(x) token_jaccard(h$abstract_norm, x$abstract_norm), numeric(1))
      strong <- which(!is.na(seqs) & !is.na(jacs) & seqs >= 0.92 & jacs >= 0.87)
      if (length(strong)) {
        candidates <- clean[strong]; method <- "title_strong_abstract_similarity"
        metrics <- list(sequence_similarity = seqs[strong], token_jaccard = jacs[strong])
      }
    }
    if (!length(candidates) && length(contradicted)) {
      cseq <- vapply(canonical[contradicted], function(x) seq_similarity(h$abstract_norm, x$abstract_norm), numeric(1))
      cjac <- vapply(canonical[contradicted], function(x) token_jaccard(h$abstract_norm, x$abstract_norm), numeric(1))
      strong_bad <- which(!is.na(cseq) & !is.na(cjac) & cseq >= 0.92 & cjac >= 0.87)
      if (length(strong_bad)) {
        emit_conflict(h, "title_strong_abstract_similarity", contradicted[strong_bad], "Title and abstract strongly matched but non-empty DOI contradicted", list(sequence_similarity = cseq[strong_bad], token_jaccard = cjac[strong_bad]))
        accepted[[hi]] <- list(status = "conflict")
        next
      }
    }
  }

  if (!length(candidates)) {
    status_counts[["unmatched"]] <- status_counts[["unmatched"]] + 1L
    write_json_line(list(status = "unmatched", historical_source = h$source, historical_row = h$source_row, decision = h$decision, historical = h), unmatched_con)
    accepted[[hi]] <- list(status = "unmatched")
  } else if (length(candidates) > 1L) {
    status_counts[["ambiguous"]] <- status_counts[["ambiguous"]] + 1L
    write_json_line(list(status = "ambiguous", historical_source = h$source, historical_row = h$source_row, decision = h$decision,
                         method = method, historical = h, candidate_lens_ids = vapply(canonical[candidates], `[[`, character(1), "lens_id"), metrics = metrics), ambig_con)
    accepted[[hi]] <- list(status = "ambiguous")
  } else {
    cj <- candidates[[1]]; c <- canonical[[cj]]
    status_counts[["matched"]] <- status_counts[["matched"]] + 1L
    if (!method %in% names(method_counts)) method_counts[[method]] <- 0L
    method_counts[[method]] <- method_counts[[method]] + 1L
    evidence <- list(
      lens_id_match = nzchar(h$lens_id) && identical(h$lens_id, c$lens_id),
      doi_match = nzchar(h$doi) && nzchar(c$doi) && identical(h$doi, c$doi),
      title_exact = nzchar(h$title_norm) && identical(h$title_norm, c$title_norm),
      abstract_exact = nzchar(h$abstract_norm) && identical(h$abstract_norm, c$abstract_norm),
      year_match = nzchar(h$year) && nzchar(c$year) && identical(h$year, c$year),
      journal_match = nzchar(h$journal_norm) && nzchar(c$journal_norm) && identical(h$journal_norm, c$journal_norm)
    )
    row <- list(status = "matched", historical_source = h$source, historical_row = h$source_row, decision = h$decision,
                canonical_lens_id = c$lens_id, canonical_row = c$canonical_row, method = method,
                confidence = if (method %in% c("lens_id", "doi_title", "exact_abstract", "title_year_journal")) "exact" else "strong_similarity",
                evidence = evidence, metrics = metrics, ris_bridge = h$ris_bridge %||% NULL,
                canonical_dedup_downstream_eligible = c$dedup_downstream_eligible, canonical_notice_type = c$notice_type)
    write_json_line(row, match_con)
    accepted[[hi]] <- row
  }

  if (hi %% checkpoint_every == 0L || hi == historical_n) {
    for (cc in list(match_con, unmatched_con, ambig_con, conflict_con)) flush(cc)
    message(sprintf("Historical reconciliation: %d/%d | matched=%d unmatched=%d ambiguous=%d conflicts=%d",
                    hi, historical_n, status_counts[["matched"]], status_counts[["unmatched"]], status_counts[["ambiguous"]], status_counts[["conflict"]]))
    write_checkpoint("historical_matching", hi, historical_n, as.list(status_counts))
  }
}
close(match_con); close(unmatched_con); close(ambig_con); close(conflict_con)

by_canonical <- new.env(hash = TRUE, parent = emptyenv())
for (x in accepted) {
  if (is.null(x) || !identical(x$status, "matched")) next
  key <- x$canonical_lens_id
  old <- if (exists(key, by_canonical, inherits = FALSE)) get(key, by_canonical) else list()
  assign(key, c(old, list(x)), by_canonical)
}

candidate_history_path <- file.path(out_dir, "candidate_screening_history.jsonl")
canonical_conflicts_path <- file.path(out_dir, "canonical_decision_conflicts.jsonl")
hist_con <- file(candidate_history_path, "wt", encoding = "UTF-8")
cc_con <- file(canonical_conflicts_path, "wt", encoding = "UTF-8")
canonical_decision_records <- 0L
canonical_conflicts <- 0L
for (lens in sort(ls(by_canonical))) {
  rows <- get(lens, by_canonical)
  decisions <- unique(vapply(rows, `[[`, character(1), "decision"))
  if (length(decisions) > 1L) {
    canonical_conflicts <- canonical_conflicts + 1L
    write_json_line(list(canonical_lens_id = lens, status = "decision_conflict", decisions = decisions, supporting_matches = rows), cc_con)
  } else {
    canonical_decision_records <- canonical_decision_records + 1L
    history <- lapply(rows, function(x) list(
      decision = x$decision,
      decided_at = NULL,
      decider_type = NULL,
      source = x$historical_source,
      match_method = x$method,
      match_confidence = x$confidence,
      match_evidence = x$evidence,
      historical_row = x$historical_row,
      ris_bridge = x$ris_bridge %||% NULL
    ))
    write_json_line(list(canonical_lens_id = lens, proposed_screening_history = history), hist_con)
  }
}
close(hist_con); close(cc_con)

method_table <- data.table(method = names(method_counts), count = as.integer(method_counts))
setorder(method_table, -count, method)
fwrite(method_table, file.path(out_dir, "match_method_counts.csv"))

summary <- list(
  workflow = "temporary_historical_screening_reconciliation",
  implementation_language = "R",
  audit_only = TRUE,
  completed_at = now_utc(),
  source_counts = list(
    production_master_includes = length(master_rows),
    includes_ris_records = length(includes),
    excludes_ris_records = length(excludes),
    historical_decision_rows = historical_n,
    canonical_records = canonical_n
  ),
  master_ris_enrichment = list(enriched = enriched_count, ambiguous = ambiguous_enrichment),
  reconciliation = as.list(status_counts),
  match_methods = as.list(method_counts),
  canonical_decision_records = canonical_decision_records,
  canonical_decision_conflicts = canonical_conflicts,
  thresholds = list(
    doi_title = "exact normalised title with exact DOI",
    exact_abstract = "exact conservative-normalised abstract; contradictory non-empty DOI blocks",
    title_year_journal = "exact conservative-normalised title, year and journal; contradictory non-empty DOI blocks",
    title_strong_abstract_similarity = list(title = "exact conservative-normalised title", sequence_similarity_min = 0.92, token_jaccard_min = 0.87, contradictory_nonempty_doi = "blocked")
  ),
  invariants = list(
    canonical_records_removed = 0,
    canonical_records_modified = 0,
    input_decision_rows_classified = sum(status_counts),
    classification_total_matches_input = sum(status_counts) == historical_n
  )
)
safe_write_json(summary, file.path(out_dir, "match_summary.json"))
write_checkpoint("complete", historical_n, historical_n, list(summary = summary))

if (sum(status_counts) != historical_n) stop("ERROR: historical reconciliation status counts do not sum to historical input", call. = FALSE)
if (canonical_conflicts > 0L) message(sprintf("REVIEW REQUIRED: %d canonical record(s) have conflicting historical include/exclude evidence", canonical_conflicts))
message(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null"))
message("PASS: audit-only historical screening reconciliation completed. Canonical JSON was not modified.")
