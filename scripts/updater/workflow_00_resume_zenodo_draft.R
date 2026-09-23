#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

archive_dir <- normalizePath(arg("--archive-dir"),mustWork=TRUE)
dep_id <- arg("--deposition-id")
output_dir <- arg("--output-dir")
if (is.null(dep_id) || is.null(output_dir)) {
  stop("Required: --archive-dir --deposition-id --output-dir",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
output_dir <- normalizePath(output_dir,mustWork=TRUE)

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)

manifest_path <- list.files(
  archive_dir,
  pattern="_manifest\\.json$",
  full.names=TRUE
)
if (length(manifest_path) != 1L) stop("Expected exactly one archive manifest",call.=FALSE)
m <- fromJSON(manifest_path[[1]],simplifyVector=FALSE)

archive_paths <- list.files(archive_dir,full.names=TRUE)
archive_paths <- archive_paths[file.info(archive_paths)$isdir %in% FALSE]
if (!length(archive_paths)) stop("Archive directory is empty",call.=FALSE)

# Verify all payload files described by the manifest before any upload.
mf <- m$files
if (is.null(mf) || !length(mf)) stop("Manifest has no file metadata",call.=FALSE)
for (nm in names(mf)) {
  p <- file.path(archive_dir,nm)
  if (!file.exists(p)) stop(sprintf("Manifest file missing locally: %s",nm),call.=FALSE)
  got_bytes <- unname(file.info(p)$size)
  got_sha <- digest(file=p,algo="sha256",serialize=FALSE)
  exp_bytes <- as.numeric(mf[[nm]]$bytes)
  exp_sha <- as.character(mf[[nm]]$sha256)
  if (!identical(as.numeric(got_bytes),exp_bytes)) stop(sprintf("Byte mismatch: %s",nm),call.=FALSE)
  if (!identical(tolower(got_sha),tolower(exp_sha))) stop(sprintf("SHA-256 mismatch: %s",nm),call.=FALSE)
}

api <- "https://zenodo.org/api/deposit/depositions"
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
perform <- function(req,expected,label,timeout=600) {
  resp <- req |>
    req_timeout(timeout) |>
    req_error(is_error=function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (!(status %in% expected)) {
    body <- tryCatch(resp_body_string(resp),error=function(e) "")
    stop(sprintf("Zenodo %s returned HTTP %d: %s",label,status,body),call.=FALSE)
  }
  resp
}

dep <- perform(
  request(paste0(api,"/",dep_id)) |> auth(),
  200L,
  "draft read",
  120
) |> resp_body_json(simplifyVector=FALSE)

if (isTRUE(dep$submitted)) stop("Zenodo draft is already published; refusing blind resume",call.=FALSE)
bucket <- as.character(dep$links$bucket)
if (!nzchar(bucket)) stop("Zenodo draft has no bucket link",call.=FALSE)

uploaded <- vector("list",length(archive_paths))
for (i in seq_along(archive_paths)) {
  p <- archive_paths[[i]]
  fn <- basename(p)
  upload_url <- paste0(bucket,"/",URLencode(fn,reserved=TRUE))
  cat(sprintf("ZENODO RESUME UPLOAD %s bytes=%s\n",fn,file.info(p)$size))

  upload_resp <- NULL
  for (attempt in seq_len(5L)) {
    resp <- request(upload_url) |>
      req_method("PUT") |>
      auth() |>
      req_headers(Expect="") |>
      req_body_file(p) |>
      req_timeout(1800) |>
      req_error(is_error=function(resp) FALSE) |>
      req_perform()
    status <- resp_status(resp)
    if (status %in% c(200L,201L)) {
      upload_resp <- resp
      break
    }
    body <- tryCatch(resp_body_string(resp),error=function(e) "")
    transient <- status %in% c(429L,500L,502L,503L,504L)
    if (!transient || attempt == 5L) {
      stop(sprintf(
        "Zenodo resume upload failed for %s after %d attempt(s), HTTP %d: %s",
        fn,attempt,status,body
      ),call.=FALSE)
    }
    delay <- min(60,2^(attempt-1L)*5)
    message(sprintf(
      "Transient Zenodo HTTP %d uploading %s; retry %d/5 after %ds",
      status,fn,attempt+1L,delay
    ))
    Sys.sleep(delay)
  }
  uploaded[[i]] <- resp_body_json(upload_resp,simplifyVector=FALSE)
}

published <- perform(
  request(paste0(api,"/",dep_id,"/actions/publish")) |>
    req_method("POST") |>
    auth(),
  c(200L,201L,202L),
  "publish",
  120
) |> resp_body_json(simplifyVector=FALSE)

run_id <- as.character(m$github_run_id)
sources <- unlist(m$sources,use.names=FALSE)
title <- if (!is.null(published$metadata$title)) published$metadata$title else dep$metadata$title

receipt <- list(
  status="published",
  github_run_id=run_id,
  github_run_url=as.character(m$github_run_url),
  run_type=as.character(m$run_type),
  search_version=as.character(m$search_version),
  sources=sources,
  zenodo_record_id=as.character(if (is.null(published$record_id)) published$id else published$record_id),
  zenodo_deposition_id=as.character(dep_id),
  doi=if (is.null(published$doi)) NA_character_ else published$doi,
  record_url=if (!is.null(published$links$html)) published$links$html else paste0("https://zenodo.org/records/",dep_id),
  title=title,
  visibility="restricted",
  total_bytes=sum(file.info(archive_paths)$size),
  archive_files=lapply(seq_along(archive_paths),function(i) {
    p <- archive_paths[[i]]
    z <- uploaded[[i]]
    list(
      filename=basename(p),
      bytes=unname(file.info(p)$size),
      sha256=digest(file=p,algo="sha256",serialize=FALSE),
      zenodo_checksum=if (is.null(z$checksum)) NULL else z$checksum
    )
  }),
  manifest_sha256=digest(file=manifest_path[[1]],algo="sha256",serialize=FALSE),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)

writeLines(
  toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
  file.path(output_dir,"zenodo_receipt.json")
)
cat(sprintf("PASS: resumed and published Zenodo record %s for Workflow 00 run %s\n",
            receipt$zenodo_record_id,run_id))
