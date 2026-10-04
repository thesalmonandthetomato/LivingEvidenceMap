#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}
req <- function(x, label) {
  if (is.null(x) || !nzchar(trimws(as.character(x)))) stop(label, " is required", call. = FALSE)
  as.character(x)
}

input <- req(arg("--canonical"), "--canonical")
stage <- toupper(req(arg("--stage"), "--stage"))
if (!stage %in% c("W01", "W08")) stop("--stage must be W01 or W08", call. = FALSE)
run_id <- req(arg("--run-id", Sys.getenv("GITHUB_RUN_ID", "")), "--run-id")
status_path <- arg("--status", "docs/current_run/current_run_status.json")
output_dir <- arg("--output-dir", "docs/reporting/workflow_09_inputs/current")
membership_path <- arg("--membership", file.path(output_dir, "w01_source_membership.csv"))
if (!file.exists(input)) stop("Canonical JSONL not found: ", input, call. = FALSE)

known_labels <- c(
  lens = "The Lens",
  scopus = "Scopus",
  openalex = "OpenAlex",
  agricola = "AGRICOLA",
  wos = "WoSCC",
  cab = "CAB Abstracts",
  proquest = "ProQuest/PQD&T"
)
pretty_label <- function(code) {
  if (code %in% names(known_labels)) return(unname(known_labels[[code]]))
  tools::toTitleCase(gsub("[_-]+", " ", code))
}

manual_meta <- list()
for (p in list.files("user_input", pattern = "^workflow00_ris_.*\\.json$", full.names = TRUE)) {
  z <- tryCatch(fromJSON(p, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(z)) next
  code <- as.character((z$database %||% list())$short_name %||% "")
  if (!nzchar(code)) next
  manual_meta[[code]] <- list(
    label = as.character((z$database %||% list())$name %||% pretty_label(code)),
    search_date = as.character((z$search %||% list())$search_date %||% "")
  )
}

state_sources <- character()
state_date <- ""
state_path <- "docs/search_record/state/current.json"
if (file.exists(state_path)) {
  st <- tryCatch(fromJSON(state_path, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.null(st)) {
    state_sources <- names(st$sources %||% list())
    sid <- as.character(st$state_id %||% "")
    m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", sid)
    if (m[[1L]] > 0L) state_date <- regmatches(sid, m)
  }
}
fallback_date <- ""
if (file.exists(status_path)) {
  st <- fromJSON(status_path, simplifyVector = FALSE)
  fallback_date <- as.character(st$search$search_date %||% "")
}

read_canonical_ids <- function(path) {
  ids <- character()
  con <- file(path, "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  repeat {
    lines <- readLines(con, n = 5000L, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[nzchar(trimws(lines))]
    if (!length(lines)) next
    ids <- c(ids, vapply(lines, function(line) {
      rec <- fromJSON(line, simplifyVector = FALSE)
      rid <- as.character((rec$identity %||% list())$record_id %||% "")
      if (!nzchar(rid)) stop("Canonical record missing identity.record_id", call. = FALSE)
      rid
    }, character(1)))
  }
  if (!length(ids) || anyDuplicated(ids)) stop("Canonical record IDs are empty or duplicated", call. = FALSE)
  ids
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
prefix <- tolower(stage)
source_csv <- file.path(output_dir, paste0(prefix, "_source_summary.csv"))
intersection_csv <- file.path(output_dir, paste0(prefix, "_source_intersections.csv"))
manifest_json <- file.path(output_dir, paste0(prefix, "_source_manifest.json"))

if (stage == "W01") {
  source_manifestations <- integer()
  source_works <- integer()
  intersection_counts <- integer()
  membership_rows <- list()
  n_records <- 0L

  con <- file(input, "rt", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  repeat {
    lines <- readLines(con, n = 1000L, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[nzchar(trimws(lines))]
    for (line in lines) {
      rec <- fromJSON(line, simplifyVector = FALSE)
      rid <- as.character((rec$identity %||% list())$record_id %||% "")
      if (!nzchar(rid)) stop("Canonical record missing identity.record_id", call. = FALSE)

      mans <- rec$manifestations %||% list()
      if (!length(mans)) stop("W01 canonical record has no manifestations: ", rid, call. = FALSE)
      src_all <- vapply(mans, function(m) as.character(m$source %||% ""), character(1))
      if (any(!nzchar(src_all))) stop("Blank manifestation source in W01 record: ", rid, call. = FALSE)

      tab <- table(src_all)
      for (code in names(tab)) {
        if (!code %in% names(source_manifestations)) source_manifestations[[code]] <- 0L
        source_manifestations[[code]] <- source_manifestations[[code]] + as.integer(tab[[code]])
      }

      src <- sort(unique(src_all))
      for (code in src) {
        if (!code %in% names(source_works)) source_works[[code]] <- 0L
        source_works[[code]] <- source_works[[code]] + 1L
      }

      key <- paste(src, collapse = "|")
      if (!key %in% names(intersection_counts)) intersection_counts[[key]] <- 0L
      intersection_counts[[key]] <- intersection_counts[[key]] + 1L

      n_records <- n_records + 1L
      membership_rows[[n_records]] <- data.frame(
        record_id = rid,
        intersection_key = key,
        stringsAsFactors = FALSE
      )
    }
  }
  close(con)
  on.exit(NULL, add = FALSE)

  membership <- do.call(rbind, membership_rows)
  if (nrow(membership) != n_records || anyDuplicated(membership$record_id)) {
    stop("W01 source membership does not reconcile to canonical records", call. = FALSE)
  }
  write.csv(membership, membership_path, row.names = FALSE, quote = TRUE)

  codes <- sort(unique(c(names(source_manifestations), names(source_works))))
  source_summary <- data.frame(
    source_code = codes,
    database = vapply(codes, function(code) {
      if (code %in% names(known_labels)) unname(known_labels[[code]])
      else if (!is.null(manual_meta[[code]]) && nzchar(manual_meta[[code]]$label)) manual_meta[[code]]$label
      else pretty_label(code)
    }, character(1)),
    manifestations = as.integer(source_manifestations[codes]),
    canonical_works = as.integer(source_works[codes]),
    search_date = vapply(codes, function(code) {
      if (!is.null(manual_meta[[code]]) && nzchar(manual_meta[[code]]$search_date)) manual_meta[[code]]$search_date
      else if (code %in% state_sources && nzchar(state_date)) state_date
      else fallback_date
    }, character(1)),
    stringsAsFactors = FALSE
  )

  ikeys <- names(intersection_counts)
  intersection_summary <- data.frame(
    intersection_key = ikeys,
    degree = vapply(strsplit(ikeys, "|", fixed = TRUE), length, integer(1)),
    records = as.integer(intersection_counts),
    stringsAsFactors = FALSE
  )

} else {
  if (!file.exists(membership_path)) {
    stop("W08 source snapshot requires W01 source membership: ", membership_path, call. = FALSE)
  }
  membership <- read.csv(membership_path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c("record_id", "intersection_key")
  if (!all(required %in% names(membership)) || anyDuplicated(membership$record_id)) {
    stop("Invalid W01 source membership file", call. = FALSE)
  }

  included_ids <- read_canonical_ids(input)
  missing_ids <- setdiff(included_ids, membership$record_id)
  if (length(missing_ids)) {
    stop(sprintf(
      "W08 canonical contains %d record IDs absent from W01 source membership; first: %s",
      length(missing_ids), missing_ids[[1L]]
    ), call. = FALSE)
  }

  included_membership <- membership[match(included_ids, membership$record_id), , drop = FALSE]
  if (nrow(included_membership) != length(included_ids)) {
    stop("W08 membership subset does not reconcile to included canonical records", call. = FALSE)
  }

  key_tab <- sort(table(included_membership$intersection_key), decreasing = TRUE)
  intersection_summary <- data.frame(
    intersection_key = names(key_tab),
    degree = vapply(strsplit(names(key_tab), "|", fixed = TRUE), length, integer(1)),
    records = as.integer(key_tab),
    stringsAsFactors = FALSE
  )

  source_codes <- sort(unique(unlist(strsplit(included_membership$intersection_key, "|", fixed = TRUE))))
  source_works <- setNames(integer(length(source_codes)), source_codes)
  for (key in included_membership$intersection_key) {
    for (code in strsplit(key, "|", fixed = TRUE)[[1L]]) {
      source_works[[code]] <- source_works[[code]] + 1L
    }
  }

  source_summary <- data.frame(
    source_code = source_codes,
    database = vapply(source_codes, function(code) {
      if (code %in% names(known_labels)) unname(known_labels[[code]])
      else if (!is.null(manual_meta[[code]]) && nzchar(manual_meta[[code]]$label)) manual_meta[[code]]$label
      else pretty_label(code)
    }, character(1)),
    manifestations = NA_integer_,
    canonical_works = as.integer(source_works[source_codes]),
    search_date = vapply(source_codes, function(code) {
      if (!is.null(manual_meta[[code]]) && nzchar(manual_meta[[code]]$search_date)) manual_meta[[code]]$search_date
      else if (code %in% state_sources && nzchar(state_date)) state_date
      else fallback_date
    }, character(1)),
    stringsAsFactors = FALSE
  )

  n_records <- length(included_ids)
}

source_summary <- source_summary[order(source_summary$database), , drop = FALSE]
intersection_summary <- intersection_summary[
  order(-intersection_summary$records, -intersection_summary$degree, intersection_summary$intersection_key),
  , drop = FALSE
]

if (sum(intersection_summary$records) != n_records) {
  stop("Intersection counts do not reconcile to canonical records", call. = FALSE)
}
if (sum(source_summary$canonical_works) < n_records) {
  stop("Source-work counts are inconsistent", call. = FALSE)
}

write.csv(source_summary, source_csv, row.names = FALSE, quote = TRUE)
write.csv(intersection_summary, intersection_csv, row.names = FALSE, quote = TRUE)

manifest <- list(
  schema = "living-evidence-map-workflow09-source-snapshot-v2",
  stage = stage,
  source_run_id = as.character(run_id),
  canonical_records = n_records,
  source_count = nrow(source_summary),
  intersection_count = nrow(intersection_summary),
  canonical_sha256 = digest(file = input, algo = "sha256", serialize = FALSE),
  source_summary_file = basename(source_csv),
  source_summary_sha256 = digest(file = source_csv, algo = "sha256", serialize = FALSE),
  intersections_file = basename(intersection_csv),
  intersections_sha256 = digest(file = intersection_csv, algo = "sha256", serialize = FALSE),
  w01_source_membership_file = if (file.exists(membership_path)) basename(membership_path) else NULL,
  w01_source_membership_sha256 = if (file.exists(membership_path)) digest(file = membership_path, algo = "sha256", serialize = FALSE) else NULL,
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null"), manifest_json, useBytes = TRUE)

cat(sprintf(
  "PASS: wrote %s source snapshot (%d records; %d sources; %d intersections)%s\n",
  stage, n_records, nrow(source_summary), nrow(intersection_summary),
  if (stage == "W01") sprintf("; membership rows=%d", nrow(membership)) else ""
))
