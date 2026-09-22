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

if (is.null(file_path) || !file.exists(file_path)) {
  stop("Required --file does not exist", call. = FALSE)
}

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required", call. = FALSE)

api_root <- "https://zenodo.org/api"
auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))
perform_json <- function(req, expected) {
  resp <- req |> req_retry(max_tries = 5, retry_on_failure = TRUE) |> req_timeout(600) |> req_perform()
  status <- resp_status(resp)
  if (!(status %in% expected)) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Zenodo API returned HTTP %d: %s", status, body), call. = FALSE)
  }
  resp_body_json(resp, simplifyVector = FALSE)
}

created <- perform_json(
  request(paste0(api_root, "/deposit/depositions")) |>
    req_method("POST") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list()),
  201L
)

deposition_id <- as.character(created$id)
bucket <- as.character(created$links$bucket)
if (!nzchar(deposition_id) || !nzchar(bucket)) stop("Zenodo did not return deposition ID/bucket", call. = FALSE)

metadata <- list(
  metadata = list(
    title = title,
    upload_type = "dataset",
    description = description,
    creators = list(list(name = "Haddaway, Neal")),
    keywords = list("Living Evidence Map", "salmon aquaculture", "evidence synthesis", snapshot_type),
    notes = paste(
      "Pipeline storage snapshot.",
      if (nzchar(source_run_id)) paste0("Source GitHub Actions run: ", source_run_id, ".") else "",
      if (nzchar(source_commit)) paste0("Source commit: ", source_commit, ".") else ""
    )
  )
)

updated <- perform_json(
  request(paste0(api_root, "/deposit/depositions/", deposition_id)) |>
    req_method("PUT") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(metadata),
  200L
)

filename <- basename(file_path)
upload_url <- paste0(bucket, "/", URLencode(filename, reserved = TRUE))
resp <- request(upload_url) |>
  req_method("PUT") |>
  auth() |>
  req_body_file(file_path) |>
  req_retry(max_tries = 5, retry_on_failure = TRUE) |>
  req_timeout(3600) |>
  req_perform()

if (resp_status(resp) != 200L) {
  body <- tryCatch(resp_body_string(resp), error = function(e) "")
  stop(sprintf("Zenodo file upload failed HTTP %d: %s", resp_status(resp), body), call. = FALSE)
}
uploaded <- resp_body_json(resp, simplifyVector = FALSE)

published <- NULL
if (publish) {
  published <- perform_json(
    request(paste0(api_root, "/deposit/depositions/", deposition_id, "/actions/publish")) |>
      req_method("POST") |>
      auth(),
    c(202L, 201L)
  )
}

sha256 <- digest(file = file_path, algo = "sha256", serialize = FALSE)
bytes <- file.info(file_path)$size
record_id <- if (!is.null(published$id)) as.character(published$id) else deposition_id
doi <- if (!is.null(published$doi)) as.character(published$doi) else NULL
record_url <- if (!is.null(published$links$html)) as.character(published$links$html) else
              if (!is.null(updated$links$html)) as.character(updated$links$html) else NULL

manifest <- list(
  storage = "zenodo",
  status = if (publish) "published" else "draft",
  snapshot_type = snapshot_type,
  deposition_id = deposition_id,
  record_id = record_id,
  doi = doi,
  record_url = record_url,
  filename = filename,
  size_bytes = unname(bytes),
  sha256 = sha256,
  zenodo_checksum = if (!is.null(uploaded$checksum)) uploaded$checksum else NULL,
  source_run_id = if (nzchar(source_run_id)) source_run_id else NULL,
  source_commit = if (nzchar(source_commit)) source_commit else NULL,
  uploaded_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  authoritative_storage = TRUE,
  git_lfs_required = FALSE
)

dir.create(dirname(output_manifest), recursive = TRUE, showWarnings = FALSE)
write_json(manifest, output_manifest, pretty = TRUE, auto_unbox = TRUE, null = "null")
cat(sprintf("PASS: uploaded %s (%s bytes) to Zenodo deposition %s [%s]\n",
            filename, format(bytes, scientific=FALSE), deposition_id,
            if (publish) "published" else "draft"))
