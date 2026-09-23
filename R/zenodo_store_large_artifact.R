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

file_path <- arg("--file")
title <- arg("--title", "Living Evidence Map pipeline snapshot")
description <- arg("--description", "Large pipeline snapshot for the Living Evidence Map.")
snapshot_type <- arg("--snapshot-type", "pipeline_snapshot")
source_run_id <- arg("--source-run-id", "")
source_commit <- arg("--source-commit", "")
output_manifest <- arg("--output-manifest", "zenodo_snapshot_manifest.json")
publish <- identical(tolower(arg("--publish", "false")), "true")

if (is.null(file_path) || !file.exists(file_path)) stop("Required --file does not exist", call. = FALSE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required", call. = FALSE)

api_root <- "https://zenodo.org/api"
auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))

perform_json <- function(req, expected, label) {
  resp <- req |>
    req_retry(max_tries = 8, retry_on_failure = TRUE) |>
    req_timeout(600) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (!(status %in% expected)) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Zenodo %s returned HTTP %d: %s", label, status, body), call. = FALSE)
  }
  resp_body_json(resp, simplifyVector = FALSE)
}

# Read-only authentication preflight against the current records API.
preflight <- perform_json(
  request(paste0(api_root, "/records?size=1")) |>
    req_method("GET") |>
    auth(),
  200L,
  "authentication preflight"
)
cat("PASS: Zenodo authentication preflight succeeded\n")

today <- format(Sys.Date(), "%Y-%m-%d")
draft_payload <- list(
  access = list(
    record = "public",
    files = "public"
  ),
  files = list(enabled = TRUE),
  metadata = list(
    title = title,
    publication_date = today,
    resource_type = list(id = "dataset"),
    creators = list(list(
      person_or_org = list(
        type = "personal",
        family_name = "Haddaway",
        given_name = "Neal"
      )
    )),
    description = description,
    subjects = list(
      list(subject = "Living Evidence Map"),
      list(subject = "salmon aquaculture"),
      list(subject = "evidence synthesis"),
      list(subject = snapshot_type)
    )
  )
)

created <- perform_json(
  request(paste0(api_root, "/records")) |>
    req_method("POST") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(draft_payload, auto_unbox = TRUE),
  201L,
  "draft creation"
)

record_id <- as.character(created$id)
if (!nzchar(record_id)) stop("Zenodo did not return a record ID", call. = FALSE)
draft_url <- as.character(created$links$self)
files_url <- as.character(created$links$files)
publish_url <- as.character(created$links$publish)
if (!nzchar(draft_url) || !nzchar(files_url)) stop("Zenodo draft response missing required links", call. = FALSE)

filename <- basename(file_path)

# 1. Initialise the file key.
initialised <- perform_json(
  request(files_url) |>
    req_method("POST") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(list(key = filename)), auto_unbox = TRUE),
  201L,
  "file initialisation"
)

if (!length(initialised$entries)) stop("Zenodo file initialisation returned no entries", call. = FALSE)
entry <- initialised$entries[[1L]]
content_url <- as.character(entry$links$content)
commit_url <- as.character(entry$links$commit)
if (!nzchar(content_url) || !nzchar(commit_url)) stop("Zenodo file entry missing content/commit links", call. = FALSE)

# 2. Stream file content.
upload_resp <- request(content_url) |>
  req_method("PUT") |>
  auth() |>
  req_headers("Content-Type" = "application/octet-stream") |>
  req_body_file(file_path) |>
  req_retry(max_tries = 5, retry_on_failure = TRUE) |>
  req_timeout(3600) |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

if (!(resp_status(upload_resp) %in% c(200L, 201L))) {
  body <- tryCatch(resp_body_string(upload_resp), error = function(e) "")
  stop(sprintf("Zenodo file upload returned HTTP %d: %s", resp_status(upload_resp), body), call. = FALSE)
}

# 3. Commit uploaded file.
committed <- perform_json(
  request(commit_url) |>
    req_method("POST") |>
    auth(),
  c(200L, 201L),
  "file commit"
)

published <- NULL
if (publish) {
  if (!nzchar(publish_url)) stop("Zenodo draft response missing publish link", call. = FALSE)
  published <- perform_json(
    request(publish_url) |>
      req_method("POST") |>
      auth(),
    c(200L, 201L, 202L),
    "publish"
  )
}

sha256 <- digest(file = file_path, algo = "sha256", serialize = FALSE)
bytes <- unname(file.info(file_path)$size)
final_obj <- if (publish && !is.null(published)) published else created
doi <- if (!is.null(final_obj$pids$doi$identifier)) as.character(final_obj$pids$doi$identifier) else NULL
record_url <- if (!is.null(final_obj$links$self_html)) as.character(final_obj$links$self_html) else NULL
checksum <- if (!is.null(committed$checksum)) as.character(committed$checksum) else NULL

manifest <- list(
  storage = "zenodo",
  api = "inveniordm_records",
  status = if (publish) "published" else "draft",
  snapshot_type = snapshot_type,
  record_id = record_id,
  doi = doi,
  record_url = record_url,
  filename = filename,
  size_bytes = bytes,
  sha256 = sha256,
  zenodo_checksum = checksum,
  source_run_id = if (nzchar(source_run_id)) source_run_id else NULL,
  source_commit = if (nzchar(source_commit)) source_commit else NULL,
  uploaded_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  authoritative_storage = TRUE,
  git_lfs_required = FALSE
)

dir.create(dirname(output_manifest), recursive = TRUE, showWarnings = FALSE)
write_json(manifest, output_manifest, pretty = TRUE, auto_unbox = TRUE, null = "null")
cat(sprintf("PASS: uploaded %s (%s bytes) to Zenodo record %s [%s]\n",
            filename, format(bytes, scientific = FALSE), record_id,
            if (publish) "published" else "draft"))
