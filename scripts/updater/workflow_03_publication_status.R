#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(curl)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("ERROR: missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
output_path <- arg("--output")
audit_path <- arg("--audit")
summary_path <- arg("--summary")
checkpoint_dir <- arg("--checkpoint-dir", "outputs/fresh_workflow03/checkpoints")
mode <- arg("--mode", "audit")
batch_size <- as.integer(arg("--batch-size", "25"))
max_tries <- as.integer(arg("--max-tries", "5"))

if (is.null(input_path) || is.null(output_path) || is.null(audit_path) || is.null(summary_path)) {
  stop("ERROR: --input, --output, --audit and --summary are required", call. = FALSE)
}
if (!mode %in% c("audit", "apply")) stop("ERROR: --mode must be audit or apply", call. = FALSE)
if (is.na(batch_size) || batch_size < 1L) stop("ERROR: --batch-size must be a positive integer", call. = FALSE)
if (is.na(max_tries) || max_tries < 1L) stop("ERROR: --max-tries must be a positive integer", call. = FALSE)

api_key <- trimws(Sys.getenv("OPENALEX_API_KEY", ""))
if (!nzchar(api_key)) stop("ERROR: OPENALEX_API_KEY was not found", call. = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

normalise_doi <- function(value) {
  if (is.null(value) || !length(value)) return("")
  if (is.list(value) && is.null(names(value))) {
    for (item in value) {
      d <- normalise_doi(item)
      if (nzchar(d)) return(d)
    }
    return("")
  }
  if (is.list(value)) {
    for (key in c("value", "doi", "id")) {
      if (!is.null(value[[key]])) {
        d <- normalise_doi(value[[key]])
        if (nzchar(d)) return(d)
      }
    }
    return("")
  }
  s <- tolower(trimws(as.character(value)[1]))
  s <- sub("^https?://(dx\\.)?doi\\.org/", "", s, perl = TRUE)
  s <- sub("^doi:\\s*", "", s, perl = TRUE)
  trimws(s)
}

notice_from_title <- function(title) {
  x <- as.character(title %||% "")
  if (grepl("^\\s*(retraction(?:\\s+notice)?|retracted)\\s*[:\\-—.]", x, ignore.case = TRUE, perl = TRUE)) {
    return(list(type = "retraction", downstream_eligible = FALSE))
  }
  if (grepl("^\\s*(withdrawn|withdrawal)\\s*[:\\-—.]", x, ignore.case = TRUE, perl = TRUE)) {
    return(list(type = "withdrawal", downstream_eligible = FALSE))
  }
  if (grepl("^\\s*correction\\s*[:\\-—.]", x, ignore.case = TRUE, perl = TRUE)) {
    return(list(type = "correction", downstream_eligible = TRUE))
  }
  if (grepl("^\\s*corrigendum\\s*[:\\-—.]", x, ignore.case = TRUE, perl = TRUE)) {
    return(list(type = "corrigendum", downstream_eligible = TRUE))
  }
  if (grepl("^\\s*erratum\\s*[:\\-—.]", x, ignore.case = TRUE, perl = TRUE)) {
    return(list(type = "erratum", downstream_eligible = TRUE))
  }
  NULL
}

record_id <- function(rec) {
  as.character((rec$identity %||% list())$lens_id %||% rec$record_id %||% "")
}

canonical_field <- function(rec, key, default = NULL) {
  can <- rec$canonical %||% list()
  can[[key]] %||% default
}

write_json_line <- function(x, con) {
  writeLines(toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA), con)
  flush(con)
}

write_checkpoint_manifest <- function(phase, processed_batches, total_batches, processed_dois, total_dois, failed_batches, extra = list()) {
  payload <- c(list(
    workflow = "workflow_03_publication_status",
    implementation_language = "R",
    phase = phase,
    processed_batches = processed_batches,
    total_batches = total_batches,
    processed_dois = processed_dois,
    total_dois = total_dois,
    failed_batches = failed_batches,
    updated_at = now_utc()
  ), extra)
  writeLines(
    toJSON(payload, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
    file.path(checkpoint_dir, "checkpoint_manifest.json")
  )
}

openalex_batch <- function(dois, api_key, max_tries = 5L) {
  if (!length(dois)) return(list(found = list(), attempts = 0L))
  filter_value <- paste0("doi:", paste(dois, collapse = "|"))
  params <- c(
    filter = filter_value,
    api_key = api_key,
    select = "id,doi,display_name,is_retracted",
    `per-page` = as.character(length(dois))
  )
  qs <- paste(
    paste0(vapply(names(params), curl_escape, character(1)), "=", vapply(unname(params), curl_escape, character(1))),
    collapse = "&"
  )
  url <- paste0("https://api.openalex.org/works?", qs)
  last_error <- NULL

  for (attempt in seq_len(max_tries)) {
    try_result <- tryCatch({
      h <- new_handle()
      handle_setheaders(h, "User-Agent" = "LivingEvidenceMap/Workflow03-R")
      handle_setopt(h, timeout = 30L)
      resp <- curl_fetch_memory(url, handle = h)
      status <- as.integer(resp$status_code)
      body_txt <- rawToChar(resp$content)
      if (status < 200L || status >= 300L) {
        stop(sprintf("OpenAlex HTTP %d: %s", status, substr(body_txt, 1, 500)), call. = FALSE)
      }
      body <- fromJSON(body_txt, simplifyVector = FALSE)
      found <- list()
      for (work in body$results %||% list()) {
        doi <- normalise_doi(work$doi)
        if (nzchar(doi)) {
          found[[doi]] <- list(
            openalex_id = work$id %||% NULL,
            openalex_title = work$display_name %||% NULL,
            openalex_is_retracted = isTRUE(work$is_retracted)
          )
        }
      }
      list(ok = TRUE, found = found)
    }, error = function(e) list(ok = FALSE, error = conditionMessage(e)))

    if (isTRUE(try_result$ok)) return(list(found = try_result$found, attempts = attempt))
    last_error <- try_result$error
    message(sprintf("WARNING: OpenAlex batch attempt %d/%d failed: %s", attempt, max_tries, last_error))
    if (attempt < max_tries) {
      wait <- c(2, 4, 8, 16, 30)[min(attempt, 5L)]
      message(sprintf("Retrying this batch in %d seconds", wait))
      Sys.sleep(wait)
    }
  }
  stop(last_error %||% "OpenAlex batch lookup failed", call. = FALSE)
}

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(summary_path), recursive = TRUE, showWarnings = FALSE)
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(input_path)) stop(sprintf("ERROR: input file not found: %s", input_path), call. = FALSE)

message("Workflow 03: loading canonical JSONL and validating record identities")
lines <- readLines(input_path, warn = FALSE, encoding = "UTF-8")
lines <- lines[nzchar(trimws(lines))]
if (!length(lines)) stop("ERROR: canonical input contains zero records", call. = FALSE)

n <- length(lines)
ids <- character(n)
audits <- vector("list", n)
doi_to_indices <- new.env(hash = TRUE, parent = emptyenv())
eligible_indices <- integer()

for (i in seq_len(n)) {
  rec <- tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE), error = function(e) {
    stop(sprintf("ERROR: invalid JSON at input line %d: %s", i, conditionMessage(e)), call. = FALSE)
  })
  rid <- record_id(rec)
  if (!nzchar(rid)) stop(sprintf("ERROR: missing Lens ID at input line %d", i), call. = FALSE)
  ids[[i]] <- rid

  dedup <- rec$deduplication %||% list()
  title <- canonical_field(rec, "title", "")
  doi <- normalise_doi(canonical_field(rec, "doi", ""))

  if (!identical(dedup$downstream_eligible, TRUE)) {
    audits[[i]] <- list(
      record_id = rid, title = title, doi = doi,
      notice_type = NULL, notice_source = NULL,
      openalex_id = NULL, openalex_title = NULL, openalex_is_retracted = FALSE,
      openalex_lookup_status = "not_queried_dedup_ineligible", openalex_error = NULL,
      notice_present = FALSE, downstream_eligible = FALSE
    )
  } else {
    eligible_indices <- c(eligible_indices, i)
    title_notice <- notice_from_title(title)
    audits[[i]] <- list(
      record_id = rid, title = title, doi = doi,
      notice_type = if (is.null(title_notice)) NULL else title_notice$type,
      notice_source = if (is.null(title_notice)) NULL else "title_rule",
      openalex_id = NULL, openalex_title = NULL, openalex_is_retracted = FALSE,
      openalex_lookup_status = if (!is.null(title_notice)) "not_queried_notice" else if (nzchar(doi)) "pending" else "not_queried_no_doi",
      openalex_error = NULL,
      notice_present = !is.null(title_notice),
      downstream_eligible = if (is.null(title_notice)) TRUE else isTRUE(title_notice$downstream_eligible)
    )
    if (is.null(title_notice) && nzchar(doi)) {
      old <- if (exists(doi, doi_to_indices, inherits = FALSE)) get(doi, doi_to_indices) else integer()
      assign(doi, c(old, i), doi_to_indices)
    }
  }

  if (i %% 1000L == 0L || i == n) message(sprintf("Workflow 03 input scan: %d/%d records", i, n))
}

if (anyDuplicated(ids)) stop(sprintf("ERROR: duplicate Lens ID detected before Workflow 03: %s", ids[duplicated(ids)][1]), call. = FALSE)
message(sprintf("Workflow 03 input validation PASS: %d records; %d dedup-downstream-eligible", n, length(eligible_indices)))

dois <- sort(ls(doi_to_indices, all.names = TRUE))
total_dois <- length(dois)
total_batches <- if (total_dois) ceiling(total_dois / batch_size) else 0L
message(sprintf("Workflow 03: %d unique DOI(s) require OpenAlex publication-status checks in %d batch(es)", total_dois, total_batches))

lookup_checkpoint <- file.path(checkpoint_dir, "doi_lookup_results.jsonl")
failed_checkpoint <- file.path(checkpoint_dir, "failed_batches.jsonl")
if (file.exists(lookup_checkpoint)) file.remove(lookup_checkpoint)
if (file.exists(failed_checkpoint)) file.remove(failed_checkpoint)
lookup_con <- file(lookup_checkpoint, "at", encoding = "UTF-8")
failed_con <- file(failed_checkpoint, "at", encoding = "UTF-8")
on.exit(try(close(lookup_con), silent = TRUE), add = TRUE)
on.exit(try(close(failed_con), silent = TRUE), add = TRUE)

failed_batches <- list()
write_checkpoint_manifest("doi_lookup", 0L, total_batches, 0L, total_dois, 0L)

if (total_dois) {
  for (batch_no in seq_len(total_batches)) {
    start <- (batch_no - 1L) * batch_size + 1L
    end <- min(batch_no * batch_size, total_dois)
    batch <- dois[start:end]
    message(sprintf("OpenAlex publication-status check: batch %d/%d (%d DOIs; %d/%d DOI positions)", batch_no, total_batches, length(batch), end, total_dois))

    result <- tryCatch(openalex_batch(batch, api_key, max_tries = max_tries), error = function(e) list(error = conditionMessage(e)))
    if (!is.null(result$error)) {
      fail_row <- list(batch = batch_no, dois = batch, error = result$error, failed_at = now_utc())
      failed_batches[[length(failed_batches) + 1L]] <- fail_row
      write_json_line(fail_row, failed_con)
      for (doi in batch) {
        for (i in get(doi, doi_to_indices, inherits = FALSE)) {
          audits[[i]]$openalex_lookup_status <- "failed"
          audits[[i]]$openalex_error <- result$error
        }
      }
      message(sprintf("ERROR RECORDED: batch %d/%d failed after retries; continuing to collect a complete failure report", batch_no, total_batches))
    } else {
      found <- result$found
      for (doi in batch) {
        row <- found[[doi]]
        for (i in get(doi, doi_to_indices, inherits = FALSE)) {
          if (is.null(row)) {
            audits[[i]]$openalex_lookup_status <- "not_found"
          } else {
            audits[[i]]$openalex_id <- row$openalex_id
            audits[[i]]$openalex_title <- row$openalex_title
            audits[[i]]$openalex_is_retracted <- isTRUE(row$openalex_is_retracted)
            audits[[i]]$openalex_lookup_status <- "matched"
            audits[[i]]$openalex_error <- NULL
            if (isTRUE(row$openalex_is_retracted)) {
              audits[[i]]$notice_type <- "retracted_original"
              audits[[i]]$notice_source <- "openalex"
              audits[[i]]$notice_present <- TRUE
              audits[[i]]$downstream_eligible <- FALSE
            }
          }
        }
        write_json_line(list(
          doi = doi,
          lookup_status = if (is.null(row)) "not_found" else "matched",
          openalex_id = if (is.null(row)) NULL else row$openalex_id,
          openalex_is_retracted = if (is.null(row)) FALSE else isTRUE(row$openalex_is_retracted),
          batch = batch_no, attempts = result$attempts, checked_at = now_utc()
        ), lookup_con)
      }
    }
    write_checkpoint_manifest("doi_lookup", batch_no, total_batches, end, total_dois, length(failed_batches), list(last_completed_batch = batch_no))
  }
}
close(lookup_con)
close(failed_con)

message("Workflow 03: writing complete audit table")
audit_tmp <- paste0(audit_path, ".tmp")
audit_con <- file(audit_tmp, "wt", encoding = "UTF-8")
for (i in seq_len(n)) write_json_line(audits[[i]], audit_con)
close(audit_con)
if (!file.rename(audit_tmp, audit_path)) stop("ERROR: could not atomically promote publication-status audit file", call. = FALSE)

checked_at <- now_utc()
eligible_rows <- audits[eligible_indices]
count_type <- function(type) sum(vapply(eligible_rows, function(x) identical(x$notice_type, type), logical(1)))
count_status <- function(status) sum(vapply(eligible_rows, function(x) identical(x$openalex_lookup_status, status), logical(1)))
summary <- list(
  workflow = "workflow_03_publication_status",
  implementation_language = "R",
  mode = mode,
  checked_at = checked_at,
  input_records = n,
  dedup_downstream_eligible_records = length(eligible_indices),
  unique_dois_queried = total_dois,
  notices_total = sum(vapply(eligible_rows, function(x) isTRUE(x$notice_present), logical(1))),
  retraction_notices = count_type("retraction"),
  withdrawal_notices = count_type("withdrawal"),
  correction_notices = count_type("correction"),
  corrigendum_notices = count_type("corrigendum"),
  erratum_notices = count_type("erratum"),
  openalex_retracted_originals = count_type("retracted_original"),
  downstream_excluded_by_notice = sum(vapply(eligible_rows, function(x) isTRUE(x$notice_present) && !isTRUE(x$downstream_eligible), logical(1))),
  retained_notice_records = sum(vapply(eligible_rows, function(x) isTRUE(x$notice_present) && isTRUE(x$downstream_eligible), logical(1))),
  openalex_not_found = count_status("not_found"),
  openalex_failed_records = count_status("failed"),
  failed_batches = failed_batches,
  records_removed = 0L,
  checkpoint_dir = checkpoint_dir
)
writeLines(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), summary_path)
write_checkpoint_manifest("audit_complete", total_batches, total_batches, total_dois, total_dois, length(failed_batches), list(summary_path = summary_path, audit_path = audit_path))

if (length(failed_batches)) {
  message(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null"))
  stop(sprintf("ERROR: OpenAlex technical failures remain in %d batch(es), affecting %d record(s). Workflow 03 is blocked; canonical state has not been changed.", length(failed_batches), summary$openalex_failed_records), call. = FALSE)
}

if (mode == "apply") {
  message("Workflow 03: provider checks cleared; building canonical notices annotations")
  out_tmp <- paste0(output_path, ".tmp")
  out_con <- file(out_tmp, "wt", encoding = "UTF-8")
  for (i in seq_len(n)) {
    rec <- fromJSON(lines[[i]], simplifyVector = FALSE)
    row <- audits[[i]]
    rec$publication_status <- NULL
    rec$notices <- NULL
    if (identical((rec$deduplication %||% list())$downstream_eligible, TRUE) && isTRUE(row$notice_present)) {
      rec$notices <- list(
        type = row$notice_type,
        status = if (isTRUE(row$downstream_eligible)) "retained" else "excluded_from_downstream",
        source = row$notice_source,
        downstream_eligible = isTRUE(row$downstream_eligible),
        doi_for_lookup = if (identical(row$notice_source, "openalex")) row$doi else NULL,
        openalex_id = if (identical(row$notice_source, "openalex")) row$openalex_id else NULL,
        checked_at = checked_at
      )
    }
    write_json_line(rec, out_con)
    if (i %% 1000L == 0L || i == n) {
      message(sprintf("Workflow 03 apply output: %d/%d records", i, n))
      write_checkpoint_manifest("apply_output", total_batches, total_batches, total_dois, total_dois, 0L, list(processed_records = i, total_records = n))
    }
  }
  close(out_con)
  if (!file.rename(out_tmp, output_path)) stop("ERROR: could not atomically promote annotated output file", call. = FALSE)
  write_checkpoint_manifest("apply_output_complete", total_batches, total_batches, total_dois, total_dois, 0L, list(processed_records = n, total_records = n))
} else {
  writeLines(character(), output_path)
}

message(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null"))
message("PASS: Workflow 03 R notice stage completed; retractions/withdrawals block downstream work, corrections/corrigenda/errata remain eligible; provider failures = 0.")
