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

api <- "https://zenodo.org/api/deposit/depositions"
auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))

perform <- function(req, expected, label, timeout = 600) {
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

# Mirror the proven fulltexttest implementation exactly:
# POST legacy deposit endpoint with an empty JSON OBJECT, not an empty array.
cat("ZENODO CREATE\n")
created_resp <- perform(
  request(api) |>
    req_method("POST") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_raw(charToRaw("{}"), type = "application/json"),
  201L,
  "draft creation",
  60
)
dep <- resp_body_json(created_resp, simplifyVector = FALSE)
dep_id <- as.character(dep$id)
bucket <- as.character(dep$links$bucket)
if (!nzchar(dep_id) || !nzchar(bucket)) stop("Zenodo draft response missing id/bucket", call. = FALSE)
cat(sprintf("ZENODO DRAFT id=%s\n", dep_id))

notes <- "Pipeline storage snapshot."
if (nzchar(source_run_id)) notes <- paste0(notes, " Source GitHub Actions run: ", source_run_id, ".")
if (nzchar(source_commit)) notes <- paste0(notes, " Source commit: ", source_commit, ".")

meta <- list(metadata = list(
  title = title,
  upload_type = "dataset",
  description = description,
  creators = list(list(name = "thesalmonandthetomato/LivingEvidenceMap")),
  keywords = list("Living Evidence Map", "salmon aquaculture", "evidence synthesis", snapshot_type),
  notes = notes
))

meta_resp <- perform(
  request(paste0(api, "/", dep_id)) |>
    req_method("PUT") |>
    auth() |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(meta, auto_unbox = TRUE),
  200L,
  "metadata update",
  60
)
dep <- resp_body_json(meta_resp, simplifyVector = FALSE)

filename <- basename(file_path)
upload_url <- paste0(bucket, "/", URLencode(filename, reserved = TRUE))
cat(sprintf("ZENODO UPLOAD %s bytes=%s\n", filename, file.info(file_path)$size))

# Direct streamed PUT to the returned legacy bucket, matching fulltexttest.
upload_resp <- perform(
  request(upload_url) |>
    req_method("PUT") |>
    auth() |>
    req_headers(Expect = "") |>
    req_body_file(file_path),
  c(200L, 201L),
  "file upload",
  900
)
uploaded <- resp_body_json(upload_resp, simplifyVector = FALSE)
cat("ZENODO UPLOAD COMPLETE\n")

published <- NULL
if (publish) {
  pub_resp <- perform(
    request(paste0(api, "/", dep_id, "/actions/publish")) |>
      req_method("POST") |>
      auth(),
    c(200L, 201L, 202L),
    "publish",
    120
  )
  published <- resp_body_json(pub_resp, simplifyVector = FALSE)
  cat(sprintf("ZENODO PUBLISHED id=%s\n", dep_id))
}

obj <- if (!is.null(published)) published else dep
sha256 <- digest(file = file_path, algo = "sha256", serialize = FALSE)
bytes <- unname(file.info(file_path)$size)

manifest <- list(
  storage = "zenodo",
  api = "legacy_deposition_httr2_fulltexttest_semantics",
  status = if (publish) "published" else "draft",
  snapshot_type = snapshot_type,
  deposition_id = dep_id,
  record_id = dep_id,
  record_url = if (!is.null(obj$links$html)) obj$links$html else paste0("https://zenodo.org/deposit/", dep_id),
  doi = if (!is.null(obj$doi)) obj$doi else NULL,
  filename = filename,
  size_bytes = bytes,
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
cat(sprintf("PASS: uploaded %s to Zenodo draft %s\n", filename, dep_id))
