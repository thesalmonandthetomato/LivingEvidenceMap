suppressPackageStartupMessages({
  library(jsonlite)
  library(stringdist)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[[i + 1L]]
}

input <- get_arg('--input')
scopus_ris <- get_arg('--scopus-ris')
output <- get_arg('--output')
audit_path <- get_arg('--audit')
conflict_path <- get_arg('--conflicts')
report_path <- get_arg('--report')
manifest_path <- get_arg('--manifest')
source_name <- get_arg('--source-name', basename(scopus_ris))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L || (length(x) == 1L && is.na(x))) y else x

required <- c(input, scopus_ris, output, audit_path, conflict_path, report_path)
if (any(vapply(required, is.null, logical(1)))) stop('Missing required argument.', call. = FALSE)
if (!file.exists(input)) stop('Canonical input does not exist: ', input, call. = FALSE)
if (!file.exists(scopus_ris)) stop('Scopus RIS does not exist: ', scopus_ris, call. = FALSE)

dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)

norm_text <- function(x) {
  if (is.null(x) || length(x) == 0L || (length(x) == 1L && is.na(x))) return('')
  x <- as.character(x)
  x <- iconv(x, from = '', to = 'ASCII//TRANSLIT', sub = '')
  x <- tolower(x)
  x <- gsub('&[a-z]+;', ' ', x)
  x <- gsub('[^a-z0-9]+', ' ', x)
  trimws(gsub('\\s+', ' ', x))
}

norm_doi <- function(x) {
  if (is.null(x) || length(x) == 0L || (length(x) == 1L && is.na(x))) return('')
  x <- as.character(x)
  x <- tolower(trimws(x))
  x <- sub('^https?://(dx\\.)?doi\\.org/', '', x)
  x <- sub('^doi:\\s*', '', x)
  sub('[ .;,]+$', '', x)
}

parse_ris <- function(path) {
  lines <- readLines(path, encoding = 'UTF-8', warn = FALSE)
  records <- list()
  current <- list()
  n <- 0L
  for (line in lines) {
    m <- regexec('^([A-Z0-9]{2})  - ?(.*)$', line)
    z <- regmatches(line, m)[[1L]]
    if (!length(z)) next
    tag <- z[[2L]]
    value <- z[[3L]]
    if (tag == 'ER') {
      if (length(current)) {
        n <- n + 1L
        records[[n]] <- current
      }
      current <- list()
    } else {
      current[[tag]] <- c(current[[tag]], value)
    }
  }
  records
}

first_value <- function(x, tag) {
  v <- x[[tag]]
  if (is.null(v) || !length(v)) '' else v[[1L]]
}

ris <- parse_ris(scopus_ris)
scopus <- lapply(seq_along(ris), function(i) {
  r <- ris[[i]]
  title <- first_value(r, 'TI')
  if (!nzchar(title)) title <- first_value(r, 'T1')
  py <- first_value(r, 'PY')
  ym <- regexpr('(18|19|20)[0-9]{2}', py, perl = TRUE)
  year <- if (ym[[1L]] < 0L) NA_integer_ else as.integer(regmatches(py, ym))
  journal <- first_value(r, 'T2')
  if (!nzchar(journal)) journal <- first_value(r, 'J2')
  abstract <- paste(r[['AB']], collapse = ' ')
  abstract <- trimws(gsub('\\s+', ' ', abstract))
  eid <- ''
  if (!is.null(r[['N1']])) {
    hits <- regmatches(r[['N1']], regexpr('EID:\\s*[^;]+', r[['N1']], perl = TRUE))
    hits <- hits[nzchar(hits)]
    if (length(hits)) eid <- trimws(sub('^EID:\\s*', '', hits[[1L]]))
  }
  list(
    sequence = i,
    title = title,
    title_key = norm_text(title),
    abstract = abstract,
    doi = norm_doi(first_value(r, 'DO')),
    year = year,
    journal = journal,
    journal_key = norm_text(journal),
    eid = eid
  )
})

has_doi_abstract <- vapply(scopus, function(x) nzchar(x$abstract) && nzchar(x$doi), logical(1))
doi_values <- vapply(scopus, function(x) x$doi, character(1))
doi_index <- split(which(has_doi_abstract), doi_values[has_doi_abstract])

tyj_keys <- vapply(scopus, function(x) {
  if (!nzchar(x$abstract) || !nzchar(x$title_key) || is.na(x$year) || !nzchar(x$journal_key)) return('')
  paste(x$title_key, x$year, x$journal_key, sep = '\u241f')
}, character(1))
tyj_index <- split(which(nzchar(tyj_keys)), tyj_keys[nzchar(tyj_keys)])

in_con <- file(input, open = 'r', encoding = 'UTF-8')
out_con <- file(output, open = 'w', encoding = 'UTF-8')
on.exit({close(in_con); close(out_con)}, add = TRUE)

audit <- list()
conflicts <- list()
counts <- c(
  exact_doi_exact_normalised_title = 0L,
  exact_doi_compatible_title = 0L,
  exact_title_year_journal = 0L
)
total <- 0L
missing_before <- 0L
recovered <- 0L
now <- format(Sys.time(), tz = 'UTC', usetz = TRUE)

repeat {
  line <- readLines(in_con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next

  rec <- fromJSON(line, simplifyVector = FALSE)
  total <- total + 1L
  canonical <- rec$canonical
  existing_abstract <- canonical$abstract %||% ''

  if (!nzchar(trimws(existing_abstract))) {
    missing_before <- missing_before + 1L
    cdoi <- norm_doi(canonical$doi)
    ctitle <- norm_text(canonical$title)
    cyear <- suppressWarnings(as.integer(canonical$year))
    cjournal <- norm_text(canonical$source)
    chosen <- NULL
    method <- NULL
    similarity <- NA_real_

    if (nzchar(cdoi) && !is.null(doi_index[[cdoi]])) {
      inds <- doi_index[[cdoi]]
      sims <- vapply(inds, function(i) {
        st <- scopus[[i]]$title_key
        if (!nzchar(ctitle) || !nzchar(st)) return(0)
        1 - stringdist(ctitle, st, method = 'jw', p = 0.1)
      }, numeric(1))
      best <- inds[[which.max(sims)]]
      similarity <- max(sims)
      s <- scopus[[best]]

      if (identical(ctitle, s$title_key)) {
        chosen <- s
        method <- 'exact_doi_exact_normalised_title'
      } else if (similarity >= 0.90) {
        chosen <- s
        method <- 'exact_doi_compatible_title'
      } else {
        conflicts[[length(conflicts) + 1L]] <- data.frame(
          lens_id = rec$identity$lens_id %||% '',
          canonical_doi = cdoi,
          canonical_title = canonical$title %||% '',
          scopus_record_sequence = s$sequence,
          scopus_eid = s$eid,
          scopus_title = s$title,
          title_similarity_jw = similarity,
          reason = 'exact DOI but incompatible title; quarantined',
          stringsAsFactors = FALSE
        )
      }
    }

    if (is.null(chosen) && nzchar(ctitle) && !is.na(cyear) && nzchar(cjournal)) {
      key <- paste(ctitle, cyear, cjournal, sep = '\u241f')
      inds <- tyj_index[[key]]
      if (!is.null(inds) && length(inds) == 1L) {
        chosen <- scopus[[inds[[1L]]]]
        method <- 'exact_title_year_journal'
        similarity <- 1
      }
    }

    if (!is.null(chosen)) {
      canonical$abstract <- chosen$abstract
      rec$canonical <- canonical
      rec$scopus_abstract_enrichment <- list(
        workflow = 'workflow_01b_scopus_abstract_enrichment',
        implementation_language = 'R',
        provider = 'Scopus RIS export',
        status = 'abstract_recovered',
        match_method = method,
        title_similarity_jw = similarity,
        canonical_doi = if (nzchar(cdoi)) cdoi else NULL,
        scopus_doi = if (nzchar(chosen$doi)) chosen$doi else NULL,
        scopus_record_sequence = chosen$sequence,
        scopus_eid = if (nzchar(chosen$eid)) chosen$eid else NULL,
        source_file = source_name,
        applied_at = now,
        overwrite_existing_abstract = FALSE
      )
      recovered <- recovered + 1L
      counts[[method]] <- counts[[method]] + 1L

      audit[[length(audit) + 1L]] <- data.frame(
        lens_id = rec$identity$lens_id %||% '',
        canonical_doi = cdoi,
        canonical_title = canonical$title %||% '',
        canonical_year = cyear,
        canonical_journal = canonical$source %||% '',
        scopus_record_sequence = chosen$sequence,
        scopus_eid = chosen$eid,
        scopus_doi = chosen$doi,
        scopus_title = chosen$title,
        scopus_year = chosen$year,
        scopus_journal = chosen$journal,
        match_method = method,
        title_similarity_jw = similarity,
        stringsAsFactors = FALSE
      )
    }
  }

  writeLines(toJSON(rec, auto_unbox = TRUE, null = 'null', na = 'null'), out_con)
}

audit_df <- if (length(audit)) do.call(rbind, audit) else data.frame()
conflict_df <- if (length(conflicts)) do.call(rbind, conflicts) else data.frame()
write.csv(audit_df, audit_path, row.names = FALSE, na = '')
write.csv(conflict_df, conflict_path, row.names = FALSE, na = '')

report <- list(
  workflow = 'workflow_01b_scopus_abstract_enrichment',
  implementation_language = 'R',
  provider = 'Scopus RIS export',
  source_file = source_name,
  scopus_records = length(scopus),
  scopus_records_with_abstract = sum(vapply(scopus, function(x) nzchar(x$abstract), logical(1))),
  canonical_records = total,
  canonical_missing_abstract_before = missing_before,
  abstracts_recovered = recovered,
  match_counts = as.list(counts),
  doi_title_conflicts_quarantined = nrow(conflict_df),
  canonical_missing_abstract_after = missing_before - recovered,
  existing_abstracts_overwritten = 0L,
  matching_rules = list(
    doi = 'exact normalised DOI; exact normalised title or Jaro-Winkler title similarity >= 0.90',
    fallback = 'exact normalised title + exact year + exact normalised journal',
    conflict_policy = 'exact DOI with title similarity < 0.90 quarantined and not applied'
  )
)
write_json(report, report_path, pretty = TRUE, auto_unbox = TRUE)

if (!is.null(manifest_path) && file.exists(manifest_path)) {
  manifest <- fromJSON(manifest_path, simplifyVector = FALSE)
  manifest$pipeline_stage <- 'scopus_abstract_enrichment_complete'
  manifest$scopus_abstract_enrichment <- report
  write_json(manifest, manifest_path, pretty = TRUE, auto_unbox = TRUE, null = 'null')
}

message(
  'PASS: Scopus abstract enrichment complete; recovered ', recovered,
  ' abstracts; quarantined ', nrow(conflict_df), ' DOI/title conflicts.'
)
