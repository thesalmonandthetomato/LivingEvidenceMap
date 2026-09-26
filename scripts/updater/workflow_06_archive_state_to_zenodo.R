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

state_dir <- normalizePath(arg("--state-dir"), mustWork = TRUE)
source_run_id <- arg("--source-run-id")
source_commit <- arg("--source-commit")
publication_run_id <- arg("--publication-run-id")
repository <- arg("--repository")
output_dir <- arg("--output-dir")
upstream_w05_record_id <- arg("--upstream-w05-record-id")
upstream_w05_layer_sha <- tolower(arg("--upstream-w05-layer-sha256", ""))

if (any(vapply(list(source_run_id, source_commit, publication_run_id, repository, output_dir, upstream_w05_record_id), is.null, logical(1)))) {
  stop("Required Workflow 06 publication arguments missing", call. = FALSE)
}
if (!nzchar(upstream_w05_layer_sha)) stop("Upstream Workflow 05 layer SHA is required", call. = FALSE)

paths <- list(
  layer = file.path(state_dir, "workflow06_geography_layer.csv"),
  semantic_jsonl = file.path(state_dir, "geography_semantic_final.jsonl"),
  unresolved = file.path(state_dir, "geography_unresolved.csv"),
  ungrounded = file.path(state_dir, "geography_ungrounded_evidence.csv"),
  failures = file.path(state_dir, "geography_llm_failures.csv"),
  discrepancies = file.path(state_dir, "geography_deterministic_qc_discrepancies.csv"),
  patterns = file.path(state_dir, "discrepancy_patterns.csv"),
  statuses = file.path(state_dir, "geography_status_counts.csv"),
  summary = file.path(state_dir, "workflow06_validated_summary.json"),
  prompt = file.path(state_dir, "workflow06_geography_prompt.txt")
)
for (p in paths) if (!file.exists(p)) stop(sprintf("Missing Workflow 06 state file: %s", basename(p)), call. = FALSE)

layer <- read.csv(paths$layer, stringsAsFactors = FALSE, check.names = FALSE)
unresolved <- read.csv(paths$unresolved, stringsAsFactors = FALSE, check.names = FALSE)
failures <- read.csv(paths$failures, stringsAsFactors = FALSE, check.names = FALSE)
discrepancies <- read.csv(paths$discrepancies, stringsAsFactors = FALSE, check.names = FALSE)
summary <- fromJSON(paths$summary, simplifyVector = FALSE)

stopifnot(
  nrow(layer) == 19407L,
  !anyDuplicated(layer$record_id),
  !anyDuplicated(layer$record_sequence),
  identical(sort(as.integer(layer$record_sequence)), seq_len(19407L)),
  sum(layer$geography_status == "RESOLVED") == 7770L,
  sum(layer$geography_status == "NONE") == 11162L,
  sum(layer$geography_status == "UNRESOLVED") == 475L,
  nrow(unresolved) == 475L,
  nrow(failures) == 4L,
  nrow(discrepancies) == 3454L,
  sum(layer$discrepancy_type == "exact_agreement") == 15953L,
  sum(layer$discrepancy_type != "exact_agreement") == 3454L,
  sum(!layer$evidence_all_grounded) == 239L,
  sum(layer$discrepancy_type == "ungrounded_evidence") == 235L,
  identical(as.character(summary$prompt_sha256), "ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a")
)

prompt_sha <- digest(file = paths$prompt, algo = "sha256", serialize = FALSE)
if (!identical(prompt_sha, "ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a")) {
  stop("Workflow 06 prompt SHA mismatch", call. = FALSE)
}

json_lines <- readLines(paths$semantic_jsonl, warn = FALSE, encoding = "UTF-8")
json_lines <- json_lines[nzchar(trimws(json_lines))]
if (length(json_lines) != 19407L) stop("Workflow 06 semantic JSONL cardinality failed", call. = FALSE)
json_ids <- vapply(json_lines, function(z) as.character(fromJSON(z, simplifyVector = FALSE)$record_id), character(1))
if (anyDuplicated(json_ids) || !setequal(json_ids, layer$record_id)) stop("Workflow 06 JSONL identity mismatch", call. = FALSE)

sha <- lapply(paths, function(p) digest(file = p, algo = "sha256", serialize = FALSE))

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)
archive_dir <- file.path(output_dir, "archive_files")
dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)

all_paths <- list.files(state_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
if (length(all_paths)) suppressWarnings(Sys.setFileTime(all_paths, as.POSIXct("2000-01-01", tz = "UTC")))

archive_name <- sprintf("LivingEvidenceMap_workflow06_run-%s_geography_state.tar.gz", source_run_id)
archive_path <- file.path(archive_dir, archive_name)
old <- setwd(dirname(state_dir)); on.exit(setwd(old), add = TRUE)
utils::tar(archive_path, files = basename(state_dir), compression = "gzip", tar = "internal")
setwd(old); on.exit(NULL, add = FALSE)
if (!file.exists(archive_path) || file.info(archive_path)$size <= 0) stop("Failed to create Workflow 06 archive", call. = FALSE)

manifest <- list(
  schema = "living-evidence-map-workflow06-geography-archive-v1",
  workflow = "06",
  state = "semantic_geography_coding",
  source_github_run_id = as.character(source_run_id),
  source_github_commit = as.character(source_commit),
  publication_github_run_id = as.character(publication_run_id),
  source_github_run_url = sprintf("https://github.com/%s/actions/runs/%s", repository, source_run_id),
  repository = repository,
  upstream_workflow05_zenodo_record_id = as.character(upstream_w05_record_id),
  upstream_workflow05_species_layer_sha256 = upstream_w05_layer_sha,
  records = 19407L,
  model = "gpt-5.6-luna",
  reasoning = "low",
  prompt_sha256 = prompt_sha,
  resolved_n = 7770L,
  none_n = 11162L,
  unresolved_n = 475L,
  evidence_not_grounded_n = 239L,
  ungrounded_evidence_discrepancy_n = 235L,
  llm_failures_n = 4L,
  exact_agreement_discrepancy_class_n = 15953L,
  qc_discrepancies_n = 3454L,
  workflow06_geography_layer_sha256 = sha$layer,
  geography_semantic_jsonl_sha256 = sha$semantic_jsonl,
  geography_unresolved_sha256 = sha$unresolved,
  geography_ungrounded_evidence_sha256 = sha$ungrounded,
  geography_llm_failures_sha256 = sha$failures,
  geography_qc_discrepancies_sha256 = sha$discrepancies,
  discrepancy_patterns_sha256 = sha$patterns,
  geography_status_counts_sha256 = sha$statuses,
  validated_summary_sha256 = sha$summary,
  prompt_file_sha256 = sha$prompt,
  file_visibility = "restricted"
)

manifest_name <- sprintf("LivingEvidenceMap_workflow06_run-%s_manifest.json", source_run_id)
manifest_path <- file.path(archive_dir, manifest_name)
writeLines(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA), manifest_path, useBytes = TRUE)

api <- "https://zenodo.org/api/deposit/depositions"
auth <- function(req) req |> req_headers(Authorization = paste("Bearer", token))
perform <- function(req, expected, label, timeout = 600) {
  resp <- req |> req_timeout(timeout) |> req_error(is_error = function(resp) FALSE) |> req_perform()
  st <- resp_status(resp)
  if (!(st %in% expected)) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Zenodo %s HTTP %d: %s", label, st, body), call. = FALSE)
  }
  resp
}

metadata <- list(metadata = list(
  title = sprintf("Living Evidence Map Workflow 06 semantic geography-coding state | run %s", source_run_id),
  upload_type = "dataset",
  publication_date = format(Sys.Date(), "%Y-%m-%d"),
  description = paste0(
    "<p>Sparse semantic geography-coding state for Living Evidence Map Workflow 06.</p>",
    "<p>The layer is keyed by stable canonical record_id and records substantive study geography inferred only from titles and abstracts, with exact evidence spans and deterministic geography comparison fields retained for quality control.</p>",
    "<p>Records: 19,407; RESOLVED: 7,770; NONE: 11,162; UNRESOLVED: 475.</p>"
  ),
  creators = list(list(name = "Haddaway, Neal")),
  access_right = "restricted",
  access_conditions = "Files contain bibliographic record identifiers, exact evidence spans and model-derived geography coding provenance.",
  keywords = list("Living Evidence Map","Workflow 06","geography coding","semantic annotation","evidence synthesis")
))

created <- perform(
  request(api) |> req_method("POST") |> auth() |> req_headers("Content-Type" = "application/json") |>
    req_body_raw(charToRaw("{}"), type = "application/json"),
  201L, "draft creation", 60
) |> resp_body_json(simplifyVector = FALSE)

dep_id <- as.character(created$id)
bucket <- as.character(created$links$bucket)
perform(
  request(paste0(api, "/", dep_id)) |> req_method("PUT") |> auth() |>
    req_headers("Content-Type" = "application/json") |> req_body_json(metadata, auto_unbox = TRUE),
  200L, "metadata update", 60
)

upload_paths <- c(archive_path, manifest_path)
uploaded <- vector("list", length(upload_paths))
for (i in seq_along(upload_paths)) {
  p <- upload_paths[[i]]
  fn <- basename(p)
  ok <- NULL
  for (attempt in seq_len(5L)) {
    resp <- request(paste0(bucket, "/", URLencode(fn, reserved = TRUE))) |> req_method("PUT") |> auth() |>
      req_headers(Expect = "") |> req_body_file(p) |> req_timeout(1800) |>
      req_error(is_error = function(resp) FALSE) |> req_perform()
    st <- resp_status(resp)
    if (st %in% c(200L, 201L)) { ok <- resp; break }
    if (!(st %in% c(429L,500L,502L,503L,504L)) || attempt == 5L) {
      stop(sprintf("Workflow 06 upload failed for %s HTTP %d", fn, st), call. = FALSE)
    }
    Sys.sleep(min(60, 5 * 2^(attempt - 1L)))
  }
  uploaded[[i]] <- resp_body_json(ok, simplifyVector = FALSE)
}

published <- perform(
  request(paste0(api, "/", dep_id, "/actions/publish")) |> req_method("POST") |> auth(),
  c(200L,201L,202L), "publish", 120
) |> resp_body_json(simplifyVector = FALSE)

record_id <- as.character(if (is.null(published$record_id)) published$id else published$record_id)
receipt <- c(manifest, list(
  status = "published",
  zenodo_record_id = record_id,
  zenodo_deposition_id = dep_id,
  doi = if (is.null(published$doi)) NA_character_ else published$doi,
  record_url = if (!is.null(published$links$html)) published$links$html else paste0("https://zenodo.org/records/", record_id),
  visibility = "restricted",
  manifest_sha256 = digest(file = manifest_path, algo = "sha256", serialize = FALSE),
  published_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
))

writeLines(toJSON(receipt, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA),
           file.path(output_dir, "zenodo_receipt.json"), useBytes = TRUE)
cat(sprintf("PASS: published restricted Workflow 06 geography state as Zenodo record %s\n", record_id))
