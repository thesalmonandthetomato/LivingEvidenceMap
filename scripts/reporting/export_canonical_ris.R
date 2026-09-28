#!/usr/bin/env Rscript

# Export the final included canonical JSONL to a portable RIS library.
#
# The RIS export contains every canonical included record, core bibliographic
# fields, abstract text, stable record ID, species/geography annotations and
# retained topic pathways. Workflow/provenance internals remain authoritative
# in the JSONL and are intentionally not duplicated into RIS notes.

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[[i + 1L]]
}

input <- arg("--input")
output <- arg("--output")
manifest <- arg("--manifest", paste0(output, ".manifest.json"))

if (is.null(input) || !file.exists(input)) stop("Canonical JSONL not found: ", input, call. = FALSE)
if (is.null(output) || !nzchar(output)) stop("--output is required", call. = FALSE)

dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)

clean <- function(x) {
  if (is.null(x) || length(x) == 0L) return(character())
  x <- as.character(unlist(x, recursive = TRUE, use.names = FALSE))
  x <- gsub("[\\r\\n\\t]+", " ", x)
  x <- gsub("[[:space:]]+", " ", x)
  x <- trimws(x)
  x[nzchar(x) & !is.na(x)]
}

first <- function(x) {
  x <- clean(x)
  if (length(x)) x[[1L]] else ""
}

emit <- function(con, tag, values) {
  values <- clean(values)
  if (!length(values)) return(invisible(NULL))
  writeLines(paste0(tag, "  - ", values), con = con, sep = "\n", useBytes = TRUE)
}

normalise_doi <- function(x) {
  x <- first(x)
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, ignore.case = TRUE)
  x <- sub("^doi:\\s*", "", x, ignore.case = TRUE)
  trimws(x)
}

split_pages <- function(x) {
  x <- first(x)
  if (!nzchar(x)) return(list(sp = "", ep = "", pg = ""))
  m <- regexec("^\\s*([^–—-]+)\\s*[–—-]\\s*([^–—-]+)\\s*$", x, perl = TRUE)
  z <- regmatches(x, m)[[1L]]
  if (length(z) == 3L) return(list(sp = trimws(z[[2L]]), ep = trimws(z[[3L]]), pg = ""))
  list(sp = "", ep = "", pg = x)
}

topic_keywords <- function(rec) {
  aa <- rec$topics$assignments
  if (is.null(aa) || !length(aa)) return(character())
  vapply(aa, function(a) {
    path <- first(a$hierarchy_path)
    stars <- first(a$workflow07_score$stars)
    if (nzchar(stars)) paste0("Topic: ", path, " ", stars) else paste0("Topic: ", path)
  }, character(1))
}

con_in <- file(input, open = "r", encoding = "UTF-8")
on.exit(close(con_in), add = TRUE)
con_out <- file(output, open = "w", encoding = "UTF-8")
on.exit(close(con_out), add = TRUE)

n <- 0L
repeat {
  lines <- readLines(con_in, n = 1000L, warn = FALSE, encoding = "UTF-8")
  if (!length(lines)) break
  lines <- lines[nzchar(trimws(lines))]
  for (line in lines) {
    rec <- fromJSON(line, simplifyVector = FALSE)
    can <- rec$canonical
    rid <- first(rec$identity$record_id)

    emit(con_out, "TY", if (nzchar(first(can$journal))) "JOUR" else "GEN")
    emit(con_out, "ID", rid)
    emit(con_out, "TI", can$title)

    authors <- can$authors
    if (!is.null(authors)) {
      if (is.list(authors)) {
        emit(con_out, "AU", unlist(authors, recursive = TRUE, use.names = FALSE))
      } else {
        emit(con_out, "AU", authors)
      }
    }

    emit(con_out, "PY", can$year)
    emit(con_out, "JO", can$journal)
    emit(con_out, "VL", can$volume)
    emit(con_out, "IS", can$issue)

    pp <- split_pages(can$pages)
    emit(con_out, "SP", pp$sp)
    emit(con_out, "EP", pp$ep)
    emit(con_out, "PG", pp$pg)

    doi <- normalise_doi(can$doi)
    emit(con_out, "DO", doi)
    if (nzchar(doi)) emit(con_out, "UR", paste0("https://doi.org/", doi))
    emit(con_out, "AB", can$abstract)

    emit(con_out, "KW", paste0("Species: ", clean(rec$species$labels)))
    emit(con_out, "KW", paste0("Country: ", clean(rec$geography$country_names)))
    emit(con_out, "KW", topic_keywords(rec))

    emit(con_out, "N1", paste0("LivingEvidenceMap canonical record ID: ", rid))
    emit(con_out, "ER", "")
    writeLines("", con_out, useBytes = TRUE)
    n <- n + 1L
  }
}

close(con_out)
con_out <- NULL

sha <- digest(output, algo = "sha256", file = TRUE, serialize = FALSE)
info <- file.info(output)
meta <- list(
  schema = "living-evidence-map-ris-export-v1",
  source_jsonl = basename(input),
  source_jsonl_sha256 = digest(input, algo = "sha256", file = TRUE, serialize = FALSE),
  records = n,
  ris_file = basename(output),
  ris_bytes = unname(info$size),
  ris_sha256 = sha,
  contents = c(
    "all included canonical records",
    "title/authors/year/journal/volume/issue/pages/DOI",
    "abstract",
    "stable canonical record ID",
    "species labels",
    "country names",
    "retained topic pathways and star support where available"
  ),
  omitted_as_nonportable_ris = c(
    "workflow-specific provenance internals",
    "deduplication state",
    "screening audit structure",
    "manifestation-level provenance"
  )
)
write_json(meta, manifest, auto_unbox = TRUE, pretty = TRUE, na = "null")
cat(sprintf("PASS: wrote %d RIS records to %s (%s bytes; SHA-256 %s)\n", n, output, info$size, sha))
