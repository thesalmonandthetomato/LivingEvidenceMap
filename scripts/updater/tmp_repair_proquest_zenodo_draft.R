#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
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
or_else <- function(x, y) if (is.null(x)) y else x
scalar <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}

draft_id <- arg("--draft-id", "23058211")
restore_file <- arg("--restore-file")
expected_sha256 <- arg("--expected-sha256")
expected_bytes <- as.integer(arg("--expected-bytes", "1903525"))
output_dir <- arg("--output-dir", "outputs/updater/proquest_zenodo_repair")
target_name <- "ProQuestDocuments-2026-09-30 (3).ris"
pending_name <- "source_registry.json"

if (is.null(restore_file) || !file.exists(restore_file)) stop("Restore file not found", call. = FALSE)
if (is.null(expected_sha256) || !grepl("^[a-f0-9]{64}$", expected_sha256)) stop("Valid --expected-sha256 required", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

local_bytes <- unname(file.info(restore_file)$size)
local_sha <- digest(file = restore_file, algo = "sha256", serialize = FALSE)
if (!identical(as.integer(local_bytes), expected_bytes) || !identical(local_sha, expected_sha256)) {
  stop(sprintf("Recovery source failed preflight: bytes=%s sha256=%s", local_bytes, local_sha), call. = FALSE)
}
cat(sprintf("RECOVERY SOURCE VERIFIED bytes=%s sha256=%s\n", local_bytes, local_sha))

auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))
perform <- function(req, expected, label, timeout = 300) {
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

files_url <- sprintf("https://zenodo.org/api/records/%s/draft/files", draft_id)
get_entries <- function() {
  r <- perform(request(files_url) |> auth(), 200L, "draft file listing", 60)
  x <- resp_body_json(r, simplifyVector = FALSE)
  if (is.null(x$entries)) list() else x$entries
}
key_of <- function(x) scalar(or_else(x$key, or_else(x$filename, x$name)))
status_of <- function(x) scalar(x$status)

entries <- get_entries()
keys <- vapply(entries, function(x) or_else(key_of(x), ""), character(1))
expected_intact <- c(
  "ProQuestDocuments-2026-09-30 (1).ris",
  "ProQuestDocuments-2026-09-30 (2).ris",
  "ProQuestDocuments-2026-09-30 (4).ris",
  "ProQuestDocuments-2026-09-30.ris"
)
if (!all(expected_intact %in% keys)) stop("Repair preflight failed: verified intact RIS file missing", call. = FALSE)
if (target_name %in% keys) stop("Repair preflight failed: target RIS file already present", call. = FALSE)

pending_ix <- which(keys == pending_name)
if (length(pending_ix) > 1L) stop("Repair preflight failed: multiple source_registry.json entries", call. = FALSE)
if (length(pending_ix) == 1L) {
  pending_entry <- entries[[pending_ix]]
  if (!identical(status_of(pending_entry), "pending")) {
    stop(sprintf("Repair preflight failed: source_registry.json status is %s, not pending", status_of(pending_entry)), call. = FALSE)
  }
  pending_self <- scalar(pending_entry$links$self)
  if (is.null(pending_self)) pending_self <- paste0(files_url, "/", URLencode(pending_name, reserved = TRUE))
  cat("DELETE dangling pending source_registry.json\n")
  perform(
    request(pending_self) |> req_method("DELETE") |> auth(),
    c(200L, 204L, 504L),
    "delete dangling source_registry.json",
    60
  )
  entries <- get_entries()
  keys <- vapply(entries, function(x) or_else(key_of(x), ""), character(1))
  if (pending_name %in% keys) stop("Dangling source_registry.json still present after delete attempt", call. = FALSE)
}
if (target_name %in% keys) stop("Target unexpectedly appeared before restore", call. = FALSE)

cat(sprintf("INITIALISE %s\n", target_name))
perform(
  request(files_url) |>
    req_method("POST") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(list(key = target_name)), auto_unbox = TRUE),
  c(200L, 201L),
  "initialise missing RIS file",
  60
)

entry_url <- paste0(files_url, "/", URLencode(target_name, reserved = TRUE))
entry_resp <- perform(request(entry_url) |> auth(), 200L, "read initialised RIS entry", 60)
entry <- resp_body_json(entry_resp, simplifyVector = FALSE)
if (!identical(key_of(entry), target_name)) stop("Initialised entry key mismatch", call. = FALSE)
content_url <- scalar(entry$links$content)
commit_url <- scalar(entry$links$commit)
if (is.null(content_url) || is.null(commit_url)) stop("Initialised file entry lacks content or commit link", call. = FALSE)

cat(sprintf("UPLOAD %s bytes=%s\n", target_name, local_bytes))
perform(
  request(content_url) |>
    req_method("PUT") |>
    auth() |>
    req_headers("Content-Type" = "application/octet-stream", Expect = "") |>
    req_body_file(restore_file),
  c(200L, 201L),
  "upload restored RIS content",
  1800
)

cat(sprintf("COMMIT %s\n", target_name))
perform(
  request(commit_url) |> req_method("POST") |> auth(),
  c(200L, 201L, 202L),
  "commit restored RIS file",
  120
)

verify_url <- sprintf(
  "https://zenodo.org/api/records/%s/draft/files/%s/content",
  draft_id,
  URLencode(target_name, reserved = TRUE)
)
verify_resp <- perform(request(verify_url) |> auth(), 200L, "download restored RIS for verification", 1800)
verify_path <- file.path(output_dir, target_name)
writeBin(resp_body_raw(verify_resp), verify_path)
remote_bytes <- unname(file.info(verify_path)$size)
remote_sha <- digest(file = verify_path, algo = "sha256", serialize = FALSE)
if (!identical(as.integer(remote_bytes), expected_bytes) || !identical(remote_sha, expected_sha256)) {
  stop(sprintf("RESTORE VERIFY FAILED bytes=%s sha256=%s", remote_bytes, remote_sha), call. = FALSE)
}

entries <- get_entries()
keys <- vapply(entries, function(x) or_else(key_of(x), ""), character(1))
target_ix <- which(keys == target_name)
if (length(target_ix) != 1L || !identical(status_of(entries[[target_ix]]), "completed")) {
  stop("Restored RIS entry is not present exactly once with status=completed", call. = FALSE)
}
if (pending_name %in% keys) stop("Dangling source_registry.json reappeared", call. = FALSE)

receipt <- list(
  status = "repaired",
  draft_id = draft_id,
  deleted_pending_file = pending_name,
  restored_file = target_name,
  bytes = remote_bytes,
  sha256 = remote_sha,
  publication_action = "none",
  draft_left_unpublished = TRUE,
  repaired_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt, auto_unbox = TRUE, pretty = TRUE), file.path(output_dir, "repair_receipt.json"))
cat(sprintf("PASS: repaired draft %s; restored %s with exact SHA-256 match; draft remains unpublished\n", draft_id, target_name))
