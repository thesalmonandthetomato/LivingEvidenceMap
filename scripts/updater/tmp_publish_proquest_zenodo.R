#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

draft_id <- "23058211"
reserved_doi <- "10.5281/zenodo.23058211"

scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
or_else <- function(x, y) if (is.null(x)) y else x
auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))

perform <- function(req, expected, label, timeout = 120) {
  resp <- req |>
    req_timeout(timeout) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (!(status %in% expected)) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Zenodo %s returned HTTP %d: %s", label, status, body), call. = FALSE)
  }
  resp
}

legacy_url <- paste0("https://zenodo.org/api/deposit/depositions/", draft_id)
legacy <- resp_body_json(
  perform(request(legacy_url) |> auth(), 200L, "legacy draft preflight"),
  simplifyVector = FALSE
)
if (isTRUE(legacy$submitted)) stop("Draft is already submitted/published", call. = FALSE)

legacy_doi <- unique(na.omit(c(
  scalar(legacy$doi),
  scalar(legacy$metadata$doi),
  scalar(legacy$metadata$prereserve_doi$doi),
  scalar(legacy$prereserve_doi$doi)
)))
if (!(reserved_doi %in% legacy_doi)) stop("Reserved DOI mismatch", call. = FALSE)

legacy_access <- scalar(legacy$metadata$access_right)
cat(sprintf("LEGACY ACCESS_RIGHT=%s\n", or_else(legacy_access, "<missing>")))

rdm_url <- paste0("https://zenodo.org/api/records/", draft_id, "/draft")
rdm <- resp_body_json(
  perform(request(rdm_url) |> auth(), 200L, "RDM draft preflight"),
  simplifyVector = FALSE
)
record_access <- scalar(rdm$access$record)
files_access <- scalar(rdm$access$files)
cat(sprintf("RDM ACCESS record=%s files=%s\n",
            or_else(record_access, "<missing>"),
            or_else(files_access, "<missing>")))

# Zenodo's restricted deposit corresponds to restricted file access. Require
# an explicit restricted signal from either legacy or current RDM metadata.
restricted_ok <- identical(legacy_access, "restricted") ||
                 identical(files_access, "restricted") ||
                 identical(record_access, "restricted")
if (!restricted_ok) {
  stop("Publication blocked: Zenodo metadata does not explicitly indicate restricted access", call. = FALSE)
}

files_url <- scalar(rdm$links$files)
if (is.null(files_url)) stop("RDM draft has no files link", call. = FALSE)
file_body <- resp_body_json(
  perform(request(files_url) |> auth(), 200L, "draft file listing"),
  simplifyVector = FALSE
)
entries <- if (!is.null(file_body$entries)) file_body$entries else list()
key_of <- function(x) scalar(or_else(x$key, or_else(x$filename, x$name)))
status_of <- function(x) scalar(x$status)
keys <- vapply(entries, function(x) or_else(key_of(x), ""), character(1))
statuses <- vapply(entries, function(x) or_else(status_of(x), ""), character(1))

expected <- c(
  "ProQuestDocuments-2026-09-30 (1).ris",
  "ProQuestDocuments-2026-09-30 (2).ris",
  "ProQuestDocuments-2026-09-30 (3).ris",
  "ProQuestDocuments-2026-09-30 (4).ris",
  "ProQuestDocuments-2026-09-30.ris",
  "source_registry.json",
  "records.jsonl",
  "manifest.json",
  "SHA256SUMS",
  "chunk_file_checksums.csv",
  "exact_duplicate_source_record_ids.csv"
)

if (!setequal(keys, expected)) {
  stop(sprintf(
    "Publication blocked: draft file set mismatch. Missing=[%s] Unexpected=[%s]",
    paste(setdiff(expected, keys), collapse = ", "),
    paste(setdiff(keys, expected), collapse = ", ")
  ), call. = FALSE)
}
if (any(statuses != "completed")) {
  bad <- keys[statuses != "completed"]
  stop(sprintf("Publication blocked: non-completed file entries: %s", paste(bad, collapse = ", ")), call. = FALSE)
}
cat(sprintf("FILE PREFLIGHT PASS: %d expected files, all completed\n", length(keys)))

publish_url <- scalar(rdm$links$publish)
if (is.null(publish_url)) publish_url <- scalar(legacy$links$publish)
if (is.null(publish_url)) stop("No Zenodo publish action link found", call. = FALSE)

cat("PUBLISH ACTION: submitting existing restricted draft\n")
pub <- perform(
  request(publish_url) |> req_method("POST") |> auth(),
  c(200L, 201L, 202L),
  "publish restricted draft",
  180
)
cat(sprintf("PUBLISH HTTP=%d\n", resp_status(pub)))

# Confirm published public record exists.
Sys.sleep(3)
published_url <- paste0("https://zenodo.org/api/records/", draft_id)
published <- resp_body_json(
  perform(request(published_url) |> auth(), 200L, "published record verification", 120),
  simplifyVector = FALSE
)
pub_doi <- or_else(scalar(published$doi), scalar(published$pids$doi$identifier))
pub_record_access <- scalar(published$access$record)
pub_files_access <- scalar(published$access$files)
cat(sprintf("PUBLISHED DOI=%s access.record=%s access.files=%s\n",
            or_else(pub_doi, "<missing>"),
            or_else(pub_record_access, "<missing>"),
            or_else(pub_files_access, "<missing>")))

if (!is.null(pub_doi) && !identical(pub_doi, reserved_doi)) {
  stop(sprintf("Published DOI mismatch: %s", pub_doi), call. = FALSE)
}
if (!(identical(pub_files_access, "restricted") ||
      identical(pub_record_access, "restricted") ||
      identical(legacy_access, "restricted"))) {
  stop("Published record verification did not retain restricted access signal", call. = FALSE)
}

cat("PASS: ProQuest Workflow 00 Zenodo record published with restricted access\n")
