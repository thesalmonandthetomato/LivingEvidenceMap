#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s', flag))
  args[[i + 1L]]
}

input_dir <- arg('--input-dir', 'inputs/openalex_ingestion')
output_dir <- arg('--output-dir', 'outputs/updater/openalex_sidecar_adapter')
if (!dir.exists(input_dir)) stop(sprintf('Input directory does not exist: %s', input_dir))
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(), tz = 'UTC', format = '%Y-%m-%dT%H:%M:%SZ')
trim_null <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}

openalex_short_id <- function(x) {
  y <- trim_null(x)
  if (is.null(y)) return(NULL)
  sub('^https://openalex.org/', '', y)
}

reconstruct_abstract <- function(inv) {
  if (is.null(inv) || !is.list(inv) || length(inv) == 0L) return(NULL)
  positions <- list()
  for (term in names(inv)) {
    idxs <- inv[[term]]
    if (is.null(idxs)) next
    for (idx in idxs) {
      positions[[as.character(as.integer(idx))]] <- term
    }
  }
  if (!length(positions)) return(NULL)
  ord <- order(as.integer(names(positions)))
  paste(unlist(positions[ord], use.names = FALSE), collapse = ' ')
}

extract_authors <- function(authorships) {
  if (is.null(authorships) || !length(authorships)) return(NULL)
  lapply(authorships, function(a) {
    au <- a$author %||% list()
    list(
      openalex_author_id = openalex_short_id(au$id),
      display_name = au$display_name %||% NULL,
      orcid = au$orcid %||% NULL,
      author_position = a$author_position %||% NULL,
      is_corresponding = a$is_corresponding %||% NULL
    )
  })
}

extract_keywords <- function(keywords) {
  if (is.null(keywords) || !length(keywords)) return(NULL)
  vals <- vapply(keywords, function(k) trim_null(k$display_name), character(1))
  vals <- vals[!is.na(vals) & nzchar(vals)]
  if (!length(vals)) NULL else unname(vals)
}

extract_primary_location <- function(work) {
  loc <- work$primary_location %||% list()
  src <- loc$source %||% list()
  list(
    source_id = openalex_short_id(src$id),
    source_display_name = src$display_name %||% NULL,
    issn_l = src$issn_l %||% NULL,
    issn = src$issn %||% NULL,
    landing_page_url = loc$landing_page_url %||% NULL,
    pdf_url = loc$pdf_url %||% NULL,
    is_oa = loc$is_oa %||% NULL,
    version = loc$version %||% NULL
  )
}

extract_institutions <- function(authorships) {
  if (is.null(authorships) || !length(authorships)) return(NULL)
  seen <- new.env(hash = TRUE, parent = emptyenv())
  out <- list()
  for (a in authorships) {
    insts <- a$institutions %||% list()
    for (inst in insts) {
      iid <- openalex_short_id(inst$id)
      key <- iid %||% paste(inst$display_name %||% '', inst$country_code %||% '', sep='|')
      if (!nzchar(key) || exists(key, envir = seen, inherits = FALSE)) next
      assign(key, TRUE, envir = seen)
      out[[length(out)+1L]] <- list(
        openalex_institution_id = iid,
        display_name = inst$display_name %||% NULL,
        country_code = inst$country_code %||% NULL,
        type = inst$type %||% NULL
      )
    }
  }
  if (!length(out)) NULL else out
}

raw_files <- sort(list.files(file.path(input_dir, 'raw'), pattern = '\\.json$', full.names = TRUE))
if (!length(raw_files)) stop(sprintf('No raw OpenAlex JSON files found under %s/raw', input_dir))

works <- list()
for (f in raw_files) {
  x <- fromJSON(f, simplifyVector = FALSE)
  rs <- x[['results']] %||% list()
  if (!is.list(rs)) stop(sprintf('Unexpected results structure in %s', f))
  works <- c(works, rs)
}
if (!length(works)) stop('OpenAlex sidecar adapter received zero works')

retrieved_at <- now_utc()
records <- vector('list', length(works))
coverage_rows <- vector('list', length(works))

for (i in seq_along(works)) {
  w <- works[[i]]
  oid <- openalex_short_id(w$id)
  doi <- trim_null(w$doi)
  if (!is.null(doi)) doi <- sub('^https://doi.org/', '', doi)
  title <- trim_null(w$title)
  year <- trim_null(w$publication_year)
  pub_date <- trim_null(w$publication_date)
  work_type <- trim_null(w$type)
  abstract <- reconstruct_abstract(w$abstract_inverted_index)
  authors <- extract_authors(w$authorships)
  keywords <- extract_keywords(w$keywords)
  institutions <- extract_institutions(w$authorships)
  loc <- extract_primary_location(w)

  if (is.null(oid)) stop(sprintf('Record %d has no OpenAlex work ID', i))
  sidecar_id <- paste0('openalex:', oid)

  records[[i]] <- list(
    sidecar_identity = list(
      sidecar_record_id = sidecar_id,
      openalex_id = oid,
      doi = doi
    ),
    source = list(
      provider = 'openalex',
      source_format = 'openalex_works_api_oql_json',
      search_scope = c('title','abstract')
    ),
    openalex = list(raw_payload = w),
    mapped_fields = list(
      title = title,
      abstract = abstract,
      authors = authors,
      year = year,
      publication_date = pub_date,
      source = loc$source_display_name,
      doi = doi,
      keywords = keywords,
      publication_type = work_type,
      institutions = institutions,
      open_access = w$open_access %||% NULL,
      primary_location = loc
    ),
    provenance = list(
      adapter_workflow = 'workflow_01u_openalex_sidecar_adapter',
      implementation_language = 'R',
      adapted_at = retrieved_at,
      source_stage = 'openalex_oql_title_abstract_search',
      canonical_json_modified = FALSE,
      downstream_workflows_modified = FALSE
    )
  )

  coverage_rows[[i]] <- data.frame(
    sidecar_record_id = sidecar_id,
    openalex_id = oid,
    doi = doi %||% NA_character_,
    title = title %||% NA_character_,
    year = year %||% NA_character_,
    publication_date = pub_date %||% NA_character_,
    source = loc$source_display_name %||% NA_character_,
    publication_type = work_type %||% NA_character_,
    abstract_present = !is.null(abstract) && nzchar(abstract),
    authors_present = !is.null(authors) && length(authors) > 0L,
    keywords_present = !is.null(keywords) && length(keywords) > 0L,
    institutions_present = !is.null(institutions) && length(institutions) > 0L,
    stringsAsFactors = FALSE
  )
}

sidecar_ids <- vapply(records, function(r) r$sidecar_identity$sidecar_record_id, character(1))
if (anyDuplicated(sidecar_ids)) stop('Duplicate OpenAlex sidecar_record_id values found in sample')

jsonl_path <- file.path(output_dir, 'openalex_sidecar_records.jsonl')
con <- file(jsonl_path, open = 'wt', encoding = 'UTF-8')
for (r in records) writeLines(toJSON(r, auto_unbox = TRUE, null = 'null', na = 'null', digits = NA), con)
close(con)

coverage <- do.call(rbind, coverage_rows)
write.csv(coverage, file.path(output_dir, 'field_coverage_records.csv'), row.names = FALSE, na = '')

present_pct <- function(x) round(100 * mean(!is.na(x) & nzchar(as.character(x))), 1)
manifest <- list(
  workflow = 'workflow_01u_openalex_sidecar_adapter',
  implementation_language = 'R',
  status = 'success',
  created_at = retrieved_at,
  input = list(
    source = 'OpenAlex Works API OQL title/abstract artefact',
    raw_files = basename(raw_files),
    records_read = length(works)
  ),
  output = list(
    sidecar_jsonl = 'openalex_sidecar_records.jsonl',
    field_coverage_csv = 'field_coverage_records.csv',
    canonical_json_modified = FALSE,
    canonical_branch_written = FALSE,
    downstream_workflows_modified = FALSE
  ),
  identifier_checks = list(
    unique_sidecar_ids = length(unique(sidecar_ids)),
    duplicate_sidecar_ids = anyDuplicated(sidecar_ids),
    openalex_id_present_n = sum(!is.na(coverage$openalex_id) & nzchar(coverage$openalex_id)),
    doi_present_n = sum(!is.na(coverage$doi) & nzchar(coverage$doi)),
    doi_missing_n = sum(is.na(coverage$doi) | !nzchar(coverage$doi))
  ),
  mapped_field_coverage_percent = list(
    title = present_pct(coverage$title),
    year = present_pct(coverage$year),
    publication_date = present_pct(coverage$publication_date),
    source = present_pct(coverage$source),
    doi = present_pct(coverage$doi),
    publication_type = present_pct(coverage$publication_type),
    abstract = round(100 * mean(coverage$abstract_present), 1),
    authors = round(100 * mean(coverage$authors_present), 1),
    keywords = round(100 * mean(coverage$keywords_present), 1),
    institutions = round(100 * mean(coverage$institutions_present), 1)
  ),
  lens_canonical_schema_compatibility = list(
    current_lens_identity_fields = c('lens_id', 'record_id', 'record_id_type'),
    current_lens_canonical_fields = c('record_id', 'lens_id', 'title', 'abstract', 'authors', 'year', 'source', 'doi', 'keywords', 'publication_type'),
    safely_mappable_now = c('title','abstract','authors','year','source','doi','keywords','publication_type'),
    additional_openalex_fields_retained_sidecar_only = c('openalex_id','publication_date','institutions','open_access','primary_location'),
    deliberately_not_written = c('identity.lens_id','identity.record_id','identity.record_id_type','canonical.*'),
    note = 'Diagnostic sidecar only. This does not propose or require any change to the Lens canonical JSON schema.'
  )
)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null'), file.path(output_dir, 'compatibility_audit.json'))

message(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null'))
message(sprintf('PASS: wrote %d OpenAlex sidecar records; Lens canonical JSON untouched.', length(records)))
