#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

ris_path <- arg("--ris")
registry_path <- arg("--registry")
output_dir <- arg("--output-dir", "outputs/updater/workflow00_ris")
if (is.null(ris_path) || is.null(registry_path)) {
  stop("Required: --ris <file.ris> --registry <registry.json>", call. = FALSE)
}
if (!file.exists(ris_path)) stop(sprintf("RIS file not found: %s", ris_path), call. = FALSE)
if (!file.exists(registry_path)) stop(sprintf("Registry file not found: %s", registry_path), call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x
scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
clean_text <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  x <- gsub("[[:space:]]+", " ", x)
  x <- trimws(x)
  if (!nzchar(x)) NULL else x
}
as_values <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- trimws(as.character(unlist(x, use.names = FALSE)))
  y <- y[!is.na(y) & nzchar(y)]
  if (!length(y)) NULL else unname(y)
}
norm_doi <- function(x) {
  x <- clean_text(x)
  if (is.null(x)) return(NULL)
  x <- tolower(x)
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, perl = TRUE)
  x <- sub("^doi:\\s*", "", x, perl = TRUE)
  x <- sub("[?#].*$", "", x, perl = TRUE)
  x <- sub("[.,;:]+$", "", x, perl = TRUE)
  if (!nzchar(x)) NULL else x
}
first_present <- function(r, tags) {
  for (tag in tags) {
    x <- r[[tag]]
    if (!is.null(x) && length(x)) return(x)
  }
  NULL
}
year_from <- function(x) {
  x <- scalar(x)
  if (is.null(x)) return(NULL)
  m <- regexpr("(19|20)[0-9]{2}", x, perl = TRUE)
  if (m[[1L]] < 0L) return(NULL)
  as.integer(regmatches(x, m))
}

registry <- fromJSON(registry_path, simplifyVector = FALSE)
required_top <- c("schema_version", "source_ID", "acquisition", "database", "search", "input")
missing_top <- required_top[!vapply(required_top, function(nm) !is.null(registry[[nm]]), logical(1))]
if (length(missing_top)) stop(sprintf("Registry missing required field(s): %s", paste(missing_top, collapse = ", ")), call. = FALSE)
if (!identical(registry$schema_version, "workflow00-source-registry-v1")) stop("Unsupported registry schema_version", call. = FALSE)
source_ID <- scalar(registry$source_ID)
if (is.null(source_ID) || !grepl("^[A-Za-z0-9][A-Za-z0-9._:-]*$", source_ID)) stop("Invalid source_ID", call. = FALSE)
if (!identical(scalar(registry$acquisition$method), "ris_upload")) stop("Registry acquisition.method must be ris_upload", call. = FALSE)
if (!identical(scalar(registry$acquisition$source_format), "RIS")) stop("Registry acquisition.source_format must be RIS", call. = FALSE)
database_name <- scalar(registry$database$name)
if (is.null(database_name)) stop("Registry database.name is required", call. = FALSE)
expected_filename <- scalar(registry$input$filename)
if (is.null(expected_filename)) stop("Registry input.filename is required", call. = FALSE)
if (!identical(basename(ris_path), basename(expected_filename))) {
  stop(sprintf("RIS filename does not match registry input.filename: %s != %s", basename(ris_path), basename(expected_filename)), call. = FALSE)
}

parse_ris <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- sub("^\\ufeff", "", lines)
  tag_re <- "^([A-Z0-9]{2})[[:space:]]*-[[:space:]]?(.*)$"
  records <- list()
  current <- NULL
  last_tag <- NULL

  append_tag <- function(rec, tag, value) {
    if (is.null(rec[[tag]])) rec[[tag]] <- list(value)
    else rec[[tag]][[length(rec[[tag]]) + 1L]] <- value
    rec
  }

  for (line in lines) {
    m <- regexec(tag_re, line, perl = TRUE)
    hit <- regmatches(line, m)[[1L]]
    if (length(hit)) {
      tag <- hit[[2L]]
      value <- hit[[3L]]
      if (tag == "TY") {
        if (!is.null(current)) stop("Encountered TY before previous RIS record ended with ER", call. = FALSE)
        current <- list()
        current <- append_tag(current, tag, value)
      } else if (tag == "ER") {
        if (is.null(current)) stop("Encountered ER outside an RIS record", call. = FALSE)
        records[[length(records) + 1L]] <- current
        current <- NULL
      } else if (!is.null(current)) {
        current <- append_tag(current, tag, value)
      }
      last_tag <- tag
    } else if (!is.null(current) && !is.null(last_tag) && grepl("^[[:space:]]+", line)) {
      cont <- trimws(line)
      if (nzchar(cont)) {
        vals <- current[[last_tag]]
        if (is.null(vals) || !length(vals)) current <- append_tag(current, last_tag, cont)
        else current[[last_tag]][[length(vals)]] <- paste(vals[[length(vals)]], cont)
      }
    } else if (nzchar(trimws(line)) && !is.null(current)) {
      stop(sprintf("Unparseable non-empty RIS line: %s", line), call. = FALSE)
    }
  }
  if (!is.null(current)) stop("RIS file ended before ER terminator", call. = FALSE)
  records
}

raw_records <- parse_ris(ris_path)
if (!length(raw_records)) stop("RIS file contains zero complete records", call. = FALSE)

provider_slug <- scalar(registry$database$short_name)
if (is.null(provider_slug)) {
  provider_slug <- tolower(gsub("[^A-Za-z0-9]+", "_", database_name))
  provider_slug <- gsub("^_+|_+$", "", provider_slug)
}
if (!nzchar(provider_slug)) provider_slug <- "ris"

make_source_record_id <- function(r, i) {
  candidates <- c(
    scalar(first_present(r, c("AN", "ID", "UT", "M3"))),
    norm_doi(first_present(r, c("DO"))),
    scalar(first_present(r, c("UR")))
  )
  candidates <- candidates[!vapply(candidates, is.null, logical(1))]
  if (length(candidates)) return(paste0(provider_slug, ":", candidates[[1L]]))
  payload <- paste(
    clean_text(first_present(r, c("TI", "T1", "CT"))),
    clean_text(first_present(r, c("PY", "Y1", "DA"))),
    paste(as_values(first_present(r, c("AU", "A1"))) %||% character(), collapse = ";"),
    sep = "|"
  )
  paste0(provider_slug, ":ris_sha256:", substr(digest(payload, algo = "sha256", serialize = FALSE), 1L, 24L))
}

normalise_record <- function(r, i) {
  title <- clean_text(first_present(r, c("TI", "T1", "CT", "BT")))
  abstract <- clean_text(first_present(r, c("AB", "N2")))
  authors <- as_values(c(r$AU %||% list(), r$A1 %||% list()))
  doi <- norm_doi(first_present(r, c("DO")))
  journal <- clean_text(first_present(r, c("JO", "JF", "JA", "T2")))
  pub_date <- clean_text(first_present(r, c("DA", "Y1", "PY")))
  year <- year_from(first_present(r, c("PY", "Y1", "DA")))
  author_keywords <- as_values(r$KW)
  publication_type <- as_values(r$TY)
  language <- as_values(r$LA)
  issn <- as_values(r$SN)
  volume <- clean_text(r$VL)
  issue <- clean_text(r$IS)
  pages <- clean_text(first_present(r, c("SP", "EP")))
  source_record_id <- make_source_record_id(r, i)

  list(
    source = list(
      provider = provider_slug,
      source_format = "ris",
      source_collection = database_name,
      source_ID = source_ID
    ),
    sidecar_identity = list(
      sidecar_record_id = source_record_id,
      source_record_id = source_record_id,
      doi = doi
    ),
    mapped_fields = list(
      title = title,
      abstract = abstract,
      authors = authors,
      structured_authors = NULL,
      year = year,
      publication_date = pub_date,
      source = journal,
      doi = doi,
      author_keywords = author_keywords,
      publication_type = publication_type,
      volume = volume,
      issue = issue,
      pages = pages,
      issn = issn,
      eissn = NULL,
      issn_l = NULL,
      language = language,
      affiliations = NULL,
      institutions = NULL
    ),
    source_specific = list(
      ris_tags = r
    ),
    provenance = list(
      source_ID = source_ID,
      acquisition_method = "ris_upload",
      database = registry$database,
      search = registry$search,
      raw_payload_location = "Workflow 00 restricted Zenodo search archive",
      raw_payload_duplicated_in_canonical_jsonl = FALSE
    )
  )
}

records <- lapply(seq_along(raw_records), function(i) normalise_record(raw_records[[i]], i))
ids <- vapply(records, function(x) x$sidecar_identity$source_record_id, character(1))
if (any(!nzchar(ids))) stop("One or more normalised records lack source_record_id", call. = FALSE)
if (anyDuplicated(ids)) {
  dup <- unique(ids[duplicated(ids)])
  stop(sprintf("Duplicate source_record_id values within RIS import: %s", paste(head(dup, 10L), collapse = ", ")), call. = FALSE)
}

raw_dir <- file.path(output_dir, "raw")
registry_dir <- file.path(output_dir, "registry")
handoff_dir <- file.path(output_dir, "handoff")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(registry_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(handoff_dir, recursive = TRUE, showWarnings = FALSE)

raw_copy <- file.path(raw_dir, basename(ris_path))
registry_copy <- file.path(registry_dir, "source_registry.json")
if (!file.copy(ris_path, raw_copy, overwrite = TRUE)) stop("Failed to stage raw RIS", call. = FALSE)
if (!file.copy(registry_path, registry_copy, overwrite = TRUE)) stop("Failed to stage source registry", call. = FALSE)

handoff_path <- file.path(handoff_dir, "records.jsonl")
con <- file(handoff_path, "wt", encoding = "UTF-8")
for (r in records) writeLines(toJSON(r, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con, useBytes = TRUE)
close(con)

sha <- function(path) digest(file = path, algo = "sha256", serialize = FALSE)
manifest <- list(
  schema = "living-evidence-map-workflow00-ris-harvest-v1",
  status = "success",
  source_ID = source_ID,
  source = provider_slug,
  database = registry$database,
  search = registry$search,
  acquisition = registry$acquisition,
  records_retrieved = length(records),
  reported_results = registry$search$reported_results %||% NULL,
  complete_download = if (is.null(registry$search$reported_results)) NULL else identical(as.integer(registry$search$reported_results), length(records)),
  handoff_contract = "Workflow 00 -> Workflow 01 common normalised manifestation structure",
  files = list(
    raw_ris = list(path = file.path("raw", basename(ris_path)), bytes = unname(file.info(raw_copy)$size), sha256 = sha(raw_copy)),
    registry = list(path = file.path("registry", "source_registry.json"), bytes = unname(file.info(registry_copy)$size), sha256 = sha(registry_copy)),
    handoff_jsonl = list(path = file.path("handoff", "records.jsonl"), bytes = unname(file.info(handoff_path)$size), sha256 = sha(handoff_path))
  ),
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
           file.path(output_dir, "manifest.json"))

checksum_lines <- c(
  sprintf("%s  %s", manifest$files$raw_ris$sha256, manifest$files$raw_ris$path),
  sprintf("%s  %s", manifest$files$registry$sha256, manifest$files$registry$path),
  sprintf("%s  %s", manifest$files$handoff_jsonl$sha256, manifest$files$handoff_jsonl$path)
)
writeLines(checksum_lines, file.path(output_dir, "SHA256SUMS"))

message(sprintf("PASS: normalised %d RIS records for source_ID=%s", length(records), source_ID))
message(sprintf("W00 handover: %s", handoff_path))
