#!/usr/bin/env Rscript
# One-off rerun trigger for DOI repair validation

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
  library(httr2)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag))
  args[[i + 1L]]
}
has_flag <- function(flag) flag %in% args

lens_path <- arg("--lens")
scopus_path <- arg("--scopus")
openalex_path <- arg("--openalex")
agricola_path <- arg("--agricola")
output_dir <- arg("--output-dir")
no_external <- has_flag("--no-external")
delay <- as.numeric(arg("--delay", "0.08"))

if (any(vapply(list(lens_path, scopus_path, openalex_path, agricola_path, output_dir), is.null, logical(1)))) {
  stop("Required arguments: --lens --scopus --openalex --agricola --output-dir")
}

EPMC <- "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
TITLE_THRESHOLD <- 0.90
SHORT_ABSTRACT_CHARS <- 300L
MAX_CHARS <- 12000L

now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  y <- as.character(x[[1L]])
  if (!nzchar(trimws(y))) NULL else y
}

clean_abstract <- function(value) {
  if (is.null(value) || length(value) == 0L) return(NULL)
  s <- enc2utf8(as.character(value[[1L]]))
  s <- gsub("<!\\[CDATA\\[(.*?)\\]\\]>", "\\1", s, perl = TRUE)
  s <- gsub("<!--.*?-->", " ", s, perl = TRUE)
  s <- gsub("</?(abstract|abstract-text|body|br|div|p|sec|section|title)(\\s[^>]*)?>", " ", s, perl = TRUE, ignore.case = TRUE)
  s <- gsub("<[^>]+>", " ", s, perl = TRUE)
  decode_entities <- function(x) {
    tryCatch(
      xml2::xml_text(xml2::read_html(paste0("<div>", x, "</div>"))),
      error = function(e) x
    )
  }
  s <- decode_entities(decode_entities(s))
  s <- gsub("\\s+", " ", s, perl = TRUE)
  s <- trimws(s)
  s <- sub("^abstract\\s*[:.\\-–—]?\\s*", "", s, ignore.case = TRUE, perl = TRUE)
  if (!nzchar(s)) return(NULL)
  if (nchar(s, type = "chars") > MAX_CHARS) s <- substr(s, 1L, MAX_CHARS)
  s
}

norm_doi <- function(value) {
  s <- scalar(value)
  if (is.null(s)) return(NULL)
  s <- tolower(trimws(s))
  s <- sub("^https?://(dx\\.)?doi\\.org/", "", s, perl = TRUE)
  s <- sub("^doi:\\s*", "", s, perl = TRUE)

  # Deterministically remove obvious publisher/web-view suffix contamination.
  # These patterns are not legitimate parts of the DOI and occur when a page
  # URL has been stored in a DOI field.
  s <- sub("(?:\\.html|/full/html)(?:\\?.*)?$", "", s, perl = TRUE, ignore.case = TRUE)

  # Strip only clearly web-tracking query strings. Do not remove arbitrary '?'
  # because punctuation can legitimately occur inside DOI suffixes.
  s <- sub("\\?(?:utm_[a-z0-9_]+|fbclid|gclid)=[^[:space:]]*$", "", s, perl = TRUE, ignore.case = TRUE)

  # Remove ordinary trailing bibliographic punctuation only.
  s <- sub("[\\.,;:]+$", "", s, perl = TRUE)

  if (!nzchar(s)) NULL else s
}

stopifnot(identical(
  norm_doi("10.1108/s0731-9053(2009)0000025010.html?utm_source=test"),
  "10.1108/s0731-9053(2009)0000025010"
))
stopifnot(identical(
  norm_doi("https://doi.org/10.1108/s0731-9053(2009)0000025010/full/html?utm_medium=referral"),
  "10.1108/s0731-9053(2009)0000025010"
))

norm_title <- function(value) {
  s <- scalar(value)
  if (is.null(s)) return(NULL)
  s <- iconv(s, to = "ASCII//TRANSLIT")
  if (is.na(s)) s <- scalar(value)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", " ", s, perl = TRUE)
  s <- trimws(gsub("\\s+", " ", s, perl = TRUE))
  if (!nzchar(s)) NULL else s
}

title_similarity <- function(a, b) {
  a <- norm_title(a)
  b <- norm_title(b)
  if (is.null(a) || is.null(b)) return(NA_real_)
  as.numeric(stringsim(a, b, method = "jw"))
}

norm_abstract_match <- function(value) {
  s <- clean_abstract(value)
  if (is.null(s)) return(NULL)
  s <- tolower(s)
  s <- gsub("\\s+", " ", s, perl = TRUE)
  s <- trimws(s)
  if (!nzchar(s)) NULL else s
}

title_display_score <- function(value) {
  s <- scalar(value)
  if (is.null(s)) return(c(nontruncated = 0, length = 0))
  truncated <- grepl("(\\.{3,}|…)\\s*$", s, perl = TRUE)
  c(nontruncated = if (truncated) 0 else 1, length = nchar(s, type = "chars"))
}

choose_group_title <- function(entries) {
  titles <- lapply(entries, function(x) scalar(x$title))
  keep <- !vapply(titles, is.null, logical(1))
  if (!any(keep)) return(NULL)
  titles <- titles[keep]
  norms <- vapply(titles, function(x) norm_title(x) %||% "", character(1))
  counts <- table(norms[nzchar(norms)])
  if (!length(counts)) return(NULL)
  max_count <- max(counts)
  winning_norms <- names(counts)[counts == max_count]

  candidates <- titles[norms %in% winning_norms]
  scores <- t(vapply(candidates, title_display_score, numeric(2)))
  ord <- order(scores[, "nontruncated"], scores[, "length"], candidates, decreasing = TRUE)
  candidates[[ord[[1L]]]]
}

stopifnot(identical(
  norm_abstract_match("<p>This is an ABSTRACT.</p>"),
  "this is an abstract."
))
stopifnot(identical(
  choose_group_title(list(
    list(title = "A complete aquaculture title"),
    list(title = "A complete aquaculture title"),
    list(title = "A complete aquaculture title...")
  )),
  "A complete aquaculture title"
))

kind <- function(r) {
  if (is.list(r$lens)) return("lens")
  provider <- r$source$provider
  if (identical(provider, "scopus")) return("scopus")
  if (identical(provider, "openalex")) return("openalex")
  if (identical(provider, "agricola_via_europe_pmc")) return("agricola")
  stop(sprintf("Unknown source record shape: provider=%s", scalar(provider) %||% "<missing>"))
}
`%||%` <- function(x, y) if (is.null(x)) y else x

record_id <- function(r) {
  if (kind(r) == "lens") {
    return(as.character(r$identity$lens_id %||% r$identity$record_id %||% ""))
  }
  as.character(r$sidecar_identity$sidecar_record_id %||% "")
}

record_doi <- function(r) {
  if (kind(r) == "lens") {
    d <- norm_doi(r$canonical$doi)
    if (!is.null(d)) return(d)
    ids <- r$lens$raw_payload$external_ids %||% list()
    for (x in ids) {
      if (is.list(x) && identical(tolower(as.character(x$type %||% "")), "doi")) {
        d <- norm_doi(x$value)
        if (!is.null(d)) return(d)
      }
    }
    return(NULL)
  }
  norm_doi(r$mapped_fields$doi %||% r$sidecar_identity$doi)
}

repair_record_doi <- function(r) {
  source_value <- if (kind(r) == "lens") {
    scalar(r$canonical$doi)
  } else {
    scalar(r$mapped_fields$doi %||% r$sidecar_identity$doi)
  }

  repaired <- record_doi(r)
  if (is.null(repaired)) return(r)

  original_norm <- if (is.null(source_value)) NULL else tolower(trimws(source_value))
  changed <- is.null(original_norm) || !identical(original_norm, repaired)

  if (kind(r) == "lens") {
    canonical <- r$canonical %||% list()
    canonical$doi <- repaired
    r$canonical <- canonical
  } else {
    mapped <- r$mapped_fields %||% list()
    mapped$doi <- repaired
    r$mapped_fields <- mapped
  }

  if (changed) {
    r$doi_repair <- list(
      workflow = "01",
      status = "doi_repaired",
      original_value = source_value,
      repaired_value = repaired,
      method = "deterministic_doi_normalisation",
      raw_source_payload_modified = FALSE
    )
  }
  r
}

record_title <- function(r) {
  if (kind(r) == "lens") return(r$canonical$title %||% r$lens$raw_payload$title)
  r$mapped_fields$title
}

set_title_repair <- function(r, repaired_title, match_doi, abstract_match_sha256, supporting_records) {
  original <- scalar(record_title(r))
  repaired <- scalar(repaired_title)
  if (is.null(repaired) || identical(norm_title(original), norm_title(repaired))) return(r)

  if (kind(r) == "lens") {
    canonical <- r$canonical %||% list()
    canonical$title <- repaired
    r$canonical <- canonical
  } else {
    mapped <- r$mapped_fields %||% list()
    mapped$title <- repaired
    r$mapped_fields <- mapped
  }

  r$title_repair <- list(
    workflow = "01",
    status = "title_repaired",
    original_value = original,
    repaired_value = repaired,
    method = "exact_normalised_doi_plus_exact_normalised_abstract_cross_source_title_consensus",
    matched_doi = match_doi,
    abstract_match_sha256 = abstract_match_sha256,
    supporting_records = supporting_records,
    raw_source_payload_modified = FALSE
  )
  r
}

existing_abstract <- function(r) {
  if (kind(r) == "lens") return(r$canonical$abstract %||% r$lens$raw_payload$abstract)
  r$mapped_fields$abstract
}

abstract_query_reason <- function(value) {
  cleaned <- clean_abstract(value)
  if (is.null(cleaned)) return("missing")
  if (grepl("(\\.{3,}|…)\\s*[\\]\\)\\}\"']*$", cleaned, perl = TRUE)) return("ellipsis_truncated")
  if (nchar(cleaned, type = "chars") < SHORT_ABSTRACT_CHARS) return("very_short")
  NULL
}

replacement_is_more_complete <- function(existing, candidate, reason) {
  old <- clean_abstract(existing) %||% ""
  new <- clean_abstract(candidate) %||% ""
  if (!nzchar(new)) return(FALSE)
  if (identical(reason, "missing")) return(TRUE)
  if (identical(reason, "ellipsis_truncated")) return(nchar(new) > nchar(old) + 20L)
  if (identical(reason, "very_short")) {
    return(nchar(new) >= SHORT_ABSTRACT_CHARS &&
             nchar(new) >= max(nchar(old) + 100L, ceiling(nchar(old) * 1.5)))
  }
  FALSE
}

annotate_record <- function(r, meta) {
  r$abstract_enrichment <- meta
  r
}

set_abstract <- function(r, text, meta) {
  cleaned <- clean_abstract(text)
  if (kind(r) == "lens") {
    c <- r$canonical %||% list()
    p <- r$lens$raw_payload %||% list()
    src <- p$source
    src_title <- if (is.list(src)) src$title else src
    defaults <- list(
      record_id = r$identity$record_id %||% record_id(r),
      lens_id = r$identity$lens_id %||% record_id(r),
      title = p$title,
      authors = p$authors,
      year = p$year_published %||% p$date_published,
      source = src_title,
      doi = record_doi(r)
    )
    for (nm in names(defaults)) {
      if (is.null(c[[nm]]) || identical(c[[nm]], "")) {
        if (!is.null(defaults[[nm]]) && !identical(defaults[[nm]], "")) c[[nm]] <- defaults[[nm]]
      }
    }
    c$abstract <- cleaned
    r$canonical <- c
  } else {
    mf <- r$mapped_fields %||% list()
    mf$abstract <- cleaned
    r$mapped_fields <- mf
  }
  r$abstract_enrichment <- meta
  r
}

read_jsonl_stream <- function(path, callback) {
  con <- file(path, open = "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  i <- 0L
  repeat {
    lines <- readLines(con, n = 500L, warn = FALSE)
    if (!length(lines)) break
    for (line in lines) {
      if (!nzchar(trimws(line))) next
      i <- i + 1L
      callback(fromJSON(line, simplifyVector = FALSE), i)
    }
  }
  i
}

epmc_lookup <- function(doi) {
  req <- request(EPMC) |>
    req_url_query(
      query = sprintf('DOI:"%s"', doi),
      format = "json",
      resultType = "core",
      pageSize = 5
    ) |>
    req_headers(`User-Agent` = "LivingEvidenceMap Workflow 01 abstract enrichment") |>
    req_timeout(30)

  errors <- character()
  for (attempt in 1:4) {
    out <- tryCatch({
      resp <- req_perform(req)
      body <- resp_body_json(resp, simplifyVector = FALSE)
      hits <- body$resultList$result %||% list()
      exact <- Filter(function(h) identical(norm_doi(h$doi), doi), hits)
      candidates <- lapply(exact, function(h) {
        a <- clean_abstract(h$abstractText)
        if (is.null(a)) return(NULL)
        list(title = h$title, abstract = a, pmid = h$pmid, pmcid = h$pmcid)
      })
      candidates <- Filter(Negate(is.null), candidates)
      list(
        candidates = candidates,
        attempt = list(
          method = "europe_pmc_exact_doi_title_compatible",
          http_status = resp_status(resp),
          url = resp_url(resp),
          hit_count = body$hitCount,
          exact_doi_hits = length(exact),
          outcome = if (length(candidates)) "candidate_abstracts_found" else if (length(exact)) "matched_no_abstract" else "no_exact_match",
          request_attempts = attempt,
          retry_errors = errors
        )
      )
    }, error = function(e) e)

    if (!inherits(out, "error")) return(out)
    errors <- c(errors, sprintf("%s: %s", class(out)[1L], conditionMessage(out)))
    if (attempt < 4L) Sys.sleep(c(1, 2, 4)[attempt])
  }

  list(
    candidates = list(),
    attempt = list(
      method = "europe_pmc_exact_doi_title_compatible",
      outcome = "technical_error",
      errors = errors,
      request_attempts = 4L
    )
  )
}

paths <- c(lens = lens_path, scopus = scopus_path, openalex = openalex_path, agricola = agricola_path)
targets <- list()
per_source <- list()

for (source in names(paths)) {
  stats <- list(
    input_records = 0L,
    existing_complete_abstracts_not_queried = 0L,
    missing_abstract_targets = 0L,
    ellipsis_truncated_targets = 0L,
    very_short_targets = 0L,
    targets_without_doi = 0L,
    targets_without_title = 0L,
    external_enrichment_targets = 0L,
    abstracts_recovered_from_europe_pmc = 0L,
    truncated_or_short_abstracts_replaced = 0L,
    compatible_result_not_more_complete = 0L,
    no_compatible_abstract_recovered = 0L,
    external_technical_errors = 0L,
    doi_values_repaired = 0L,
    title_values_repaired = 0L
  )

  read_jsonl_stream(paths[[source]], function(r, i) {
    stats$input_records <<- stats$input_records + 1L
    reason <- abstract_query_reason(existing_abstract(r))
    if (is.null(reason)) {
      stats$existing_complete_abstracts_not_queried <<- stats$existing_complete_abstracts_not_queried + 1L
      return(invisible(NULL))
    }

    key <- switch(
      reason,
      missing = "missing_abstract_targets",
      ellipsis_truncated = "ellipsis_truncated_targets",
      very_short = "very_short_targets"
    )
    stats[[key]] <<- stats[[key]] + 1L

    doi <- record_doi(r)
    title <- record_title(r)
    if (is.null(doi)) {
      stats$targets_without_doi <<- stats$targets_without_doi + 1L
      return(invisible(NULL))
    }
    if (is.null(norm_title(title))) {
      stats$targets_without_title <<- stats$targets_without_title + 1L
      return(invisible(NULL))
    }

    stats$external_enrichment_targets <<- stats$external_enrichment_targets + 1L
    targets[[length(targets) + 1L]] <<- list(
      source = source,
      record_id = record_id(r),
      doi = doi,
      title = scalar(title),
      reason = reason,
      existing_abstract = scalar(existing_abstract(r))
    )
  })
  per_source[[source]] <- stats
}

# Build a deterministic cross-source title-repair index. This is the only
# cross-source repair in Workflow 01: exact normalised DOI plus exact normalised
# existing abstract. No abstract is transferred between providers.
title_match_groups <- list()
for (source in names(paths)) {
  read_jsonl_stream(paths[[source]], function(r, i) {
    doi <- record_doi(r)
    abs_norm <- norm_abstract_match(existing_abstract(r))
    if (is.null(doi) || is.null(abs_norm)) return(invisible(NULL))
    abs_hash <- digest::digest(abs_norm, algo = "sha256", serialize = FALSE)
    key <- paste(doi, abs_hash, sep = "::")
    entry <- list(source = source, record_id = record_id(r), title = scalar(record_title(r)))
    title_match_groups[[key]] <<- c(title_match_groups[[key]] %||% list(), list(entry))
  })
}

title_repair_index <- new.env(hash = TRUE, parent = emptyenv())
for (key in names(title_match_groups)) {
  entries <- title_match_groups[[key]]
  sources <- unique(vapply(entries, function(x) x$source, character(1)))
  if (length(entries) < 2L || length(sources) < 2L) next
  chosen <- choose_group_title(entries)
  if (is.null(chosen)) next
  parts <- strsplit(key, "::", fixed = TRUE)[[1L]]
  info <- list(
    doi = parts[[1L]],
    abstract_match_sha256 = parts[[2L]],
    repaired_title = chosen,
    supporting_records = lapply(entries, function(x) list(source = x$source, record_id = x$record_id, title = x$title))
  )
  for (entry in entries) {
    assign(paste(entry$source, entry$record_id, sep = "::"), info, envir = title_repair_index)
  }
}

target_dois <- sort(unique(vapply(targets, function(x) x$doi, character(1))))
lookup_cache <- list()

if (!no_external && length(target_dois)) {
  for (i in seq_along(target_dois)) {
    doi <- target_dois[[i]]
    lookup_cache[[doi]] <- epmc_lookup(doi)
    if (i == 1L || i %% 250L == 0L || i == length(target_dois)) {
      message(sprintf("Europe PMC progress: %d/%d unique DOI lookups", i, length(target_dois)))
    }
    if (delay > 0 && i < length(target_dois)) Sys.sleep(delay)
  }
}

target_by_record <- new.env(hash = TRUE, parent = emptyenv())
for (t in targets) {
  assign(paste(t$source, t$record_id, sep = "::"), t, envir = target_by_record)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

for (source in names(paths)) {
  out_path <- file.path(output_dir, sprintf("%s_records_for_deduplication.jsonl", source))
  out_con <- file(out_path, open = "wt", encoding = "UTF-8")
  seen <- new.env(hash = TRUE, parent = emptyenv())
  n_written <- 0L

  read_jsonl_stream(paths[[source]], function(r, i) {
    rid <- record_id(r)
    if (!nzchar(rid)) stop(sprintf("%s: blank record ID", source))
    if (exists(rid, envir = seen, inherits = FALSE)) stop(sprintf("%s: duplicate record ID %s", source, rid))
    assign(rid, TRUE, envir = seen)
    n_written <<- n_written + 1L

    r <- repair_record_doi(r)
    if (!is.null(r$doi_repair) && identical(r$doi_repair$status, "doi_repaired")) {
      per_source[[source]]$doi_values_repaired <<- per_source[[source]]$doi_values_repaired + 1L
    }

    title_key <- paste(source, rid, sep = "::")
    if (exists(title_key, envir = title_repair_index, inherits = FALSE)) {
      ti <- get(title_key, envir = title_repair_index, inherits = FALSE)
      r <- set_title_repair(
        r,
        ti$repaired_title,
        ti$doi,
        ti$abstract_match_sha256,
        ti$supporting_records
      )
      if (!is.null(r$title_repair) && identical(r$title_repair$status, "title_repaired")) {
        per_source[[source]]$title_values_repaired <<- per_source[[source]]$title_values_repaired + 1L
      }
    }

    reason <- abstract_query_reason(existing_abstract(r))
    doi <- record_doi(r)
    title <- record_title(r)

    if (is.null(reason)) {
      meta <- list(
        workflow = "01", provider = source, status = "existing_complete_abstract_not_queried",
        doi = doi, enriched_at = NULL, method = NULL, canonical_store_modified = FALSE
      )
      out <- annotate_record(r, meta)
    } else if (is.null(doi)) {
      meta <- list(
        workflow = "01", provider = source, status = sprintf("%s_no_doi", reason),
        doi = NULL, query_reason = reason, enriched_at = NULL, method = NULL,
        canonical_store_modified = FALSE
      )
      out <- annotate_record(r, meta)
    } else if (is.null(norm_title(title))) {
      meta <- list(
        workflow = "01", provider = source, status = sprintf("%s_no_title", reason),
        doi = doi, query_reason = reason, enriched_at = NULL, method = NULL,
        canonical_store_modified = FALSE
      )
      out <- annotate_record(r, meta)
    } else if (no_external) {
      meta <- list(
        workflow = "01", provider = source, status = "external_enrichment_not_run",
        doi = doi, query_reason = reason,
        existing_abstract_chars = nchar(clean_abstract(existing_abstract(r)) %||% ""),
        enriched_at = NULL, method = NULL, canonical_store_modified = FALSE
      )
      out <- annotate_record(r, meta)
    } else {
      lookup <- lookup_cache[[doi]]
      attempt <- lookup$attempt

      if (identical(attempt$outcome, "technical_error")) {
        per_source[[source]]$external_technical_errors <<- per_source[[source]]$external_technical_errors + 1L
        meta <- list(
          workflow = "01", provider = source, status = "external_technical_error",
          doi = doi, query_reason = reason, enriched_at = NULL,
          method = "europe_pmc_exact_doi_title_compatible",
          attempt = attempt, canonical_store_modified = FALSE
        )
        out <- annotate_record(r, meta)
      } else {
        compatible <- list()
        for (candidate in lookup$candidates) {
          sim <- title_similarity(title, candidate$title)
          if (!is.na(sim) && sim >= TITLE_THRESHOLD) {
            compatible[[length(compatible) + 1L]] <- list(similarity = sim, candidate = candidate)
          }
        }
        if (length(compatible)) {
          sims <- vapply(compatible, function(x) x$similarity, numeric(1))
          best <- compatible[[which.max(sims)]]
          candidate <- best$candidate
          similarity <- best$similarity

          if (replacement_is_more_complete(existing_abstract(r), candidate$abstract, reason)) {
            per_source[[source]]$abstracts_recovered_from_europe_pmc <<- per_source[[source]]$abstracts_recovered_from_europe_pmc + 1L
            if (reason %in% c("ellipsis_truncated", "very_short")) {
              per_source[[source]]$truncated_or_short_abstracts_replaced <<- per_source[[source]]$truncated_or_short_abstracts_replaced + 1L
            }
            meta <- list(
              workflow = "01", provider = source,
              status = if (identical(reason, "missing")) "abstract_enriched_europe_pmc" else "abstract_repaired_europe_pmc",
              doi = doi, query_reason = reason,
              existing_abstract_chars = nchar(clean_abstract(existing_abstract(r)) %||% ""),
              replacement_abstract_chars = nchar(clean_abstract(candidate$abstract) %||% ""),
              enriched_at = now_utc(),
              method = "europe_pmc_exact_doi_title_compatible",
              title_similarity = round(similarity, 6),
              europe_pmc_id = list(pmid = candidate$pmid, pmcid = candidate$pmcid),
              attempt = attempt, canonical_store_modified = FALSE
            )
            out <- set_abstract(r, candidate$abstract, meta)
          } else {
            per_source[[source]]$compatible_result_not_more_complete <<- per_source[[source]]$compatible_result_not_more_complete + 1L
            meta <- list(
              workflow = "01", provider = source,
              status = "compatible_europe_pmc_abstract_not_more_complete",
              doi = doi, query_reason = reason,
              existing_abstract_chars = nchar(clean_abstract(existing_abstract(r)) %||% ""),
              candidate_abstract_chars = nchar(clean_abstract(candidate$abstract) %||% ""),
              enriched_at = NULL,
              method = "europe_pmc_exact_doi_title_compatible",
              title_similarity = round(similarity, 6),
              attempt = attempt, canonical_store_modified = FALSE
            )
            out <- annotate_record(r, meta)
          }
        } else {
          per_source[[source]]$no_compatible_abstract_recovered <<- per_source[[source]]$no_compatible_abstract_recovered + 1L
          meta <- list(
            workflow = "01", provider = source, status = "no_compatible_abstract_recovered",
            doi = doi, query_reason = reason, enriched_at = NULL,
            method = "europe_pmc_exact_doi_title_compatible",
            attempt = attempt, canonical_store_modified = FALSE
          )
          out <- annotate_record(r, meta)
        }
      }
    }

    writeLines(toJSON(out, auto_unbox = TRUE, null = "null", na = "null"), out_con)
  })

  close(out_con)
  if (n_written != per_source[[source]]$input_records) {
    stop(sprintf("%s cardinality changed: wrote %d of %d", source, n_written, per_source[[source]]$input_records))
  }
}

cache_path <- file.path(output_dir, "europe_pmc_lookup_cache.jsonl")
cache_con <- file(cache_path, open = "wt", encoding = "UTF-8")
for (doi in names(lookup_cache)) {
  writeLines(toJSON(c(list(doi = doi), lookup_cache[[doi]]), auto_unbox = TRUE, null = "null", na = "null"), cache_con)
}
close(cache_con)

report <- list(
  workflow = "01_abstract_enrichment",
  implementation_language = "R",
  status = "success",
  created_at = now_utc(),
  methodology = list(
    source_processing = "independent",
    complete_existing_abstracts = "retained unchanged and not queried",
    missing_abstracts = "queried against Europe PMC when DOI and title are available",
    ellipsis_truncated_abstracts = "queried against Europe PMC and replaced only by a longer title-compatible abstract",
    very_short_abstracts = sprintf(
      "existing abstracts under %d cleaned characters are queried and replaced only by a substantially fuller title-compatible abstract",
      SHORT_ABSTRACT_CHARS
    ),
    cross_source_matching_performed = "title repair only: exact normalised DOI plus exact normalised existing abstract across at least two source providers",
    cross_source_title_repair = "repair mapped/canonical title deterministically from matching manifestations; raw source titles remain unchanged",
    cross_source_abstract_transfer_performed = FALSE,
    deduplication_performed = FALSE,
    external_provider = "Europe PMC",
    external_match_rule = "exact normalised DOI plus Jaro-Winkler title similarity >= 0.90",
    shared_doi_lookup_cache = "efficiency only; every target record is title-matched independently"
  ),
  inputs = lapply(per_source, function(x) x$input_records),
  per_source = per_source,
  unique_doi_targets_for_external_enrichment = length(target_dois),
  unique_external_doi_queries = if (no_external) 0L else length(lookup_cache),
  external_lookup_skipped = no_external,
  outputs = setNames(
    lapply(names(paths), function(source) sprintf("%s_records_for_deduplication.jsonl", source)),
    names(paths)
  ),
  canonical_store_modified = FALSE,
  source_payloads_modified = FALSE
)

writeLines(
  toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
  file.path(output_dir, "report.json")
)
cat(toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), "\n")
