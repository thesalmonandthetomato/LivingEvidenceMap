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
upstream_w04_record_id <- arg("--upstream-w04-record-id")
upstream_w04_layer_sha <- tolower(arg("--upstream-w04-layer-sha256", ""))

if (any(vapply(list(source_run_id, source_commit, publication_run_id, repository, output_dir, upstream_w04_record_id), is.null, logical(1)))) {
  stop("Required Workflow 05 publication arguments missing", call. = FALSE)
}
if (!nzchar(upstream_w04_layer_sha)) stop("Upstream Workflow 04 layer SHA is required", call. = FALSE)

paths <- list(
  layer = file.path(state_dir, "workflow05_species_layer.csv"),
  codes = file.path(state_dir, "species_codes_long.csv"),
  matches = file.path(state_dir, "species_matches.csv"),
  counts = file.path(state_dir, "species_record_counts.csv"),
  run_manifest = file.path(state_dir, "workflow05_manifest.json"),
  concepts = file.path(state_dir, "deterministic_concepts.csv")
)
for (p in paths) if (!file.exists(p)) stop(sprintf("Missing Workflow 05 state file: %s", basename(p)), call. = FALSE)

layer <- read.csv(paths$layer, stringsAsFactors = FALSE, check.names = FALSE)
codes <- read.csv(paths$codes, stringsAsFactors = FALSE, check.names = FALSE)
matches <- read.csv(paths$matches, stringsAsFactors = FALSE, check.names = FALSE)
counts <- read.csv(paths$counts, stringsAsFactors = FALSE, check.names = FALSE)
concepts <- read.csv(paths$concepts, stringsAsFactors = FALSE, check.names = FALSE)
run_manifest <- fromJSON(paths$run_manifest, simplifyVector = FALSE)

stopifnot(
  nrow(layer) > 0L,
  !anyDuplicated(layer$record_id),
  all(c("record_sequence","record_id","farmed_species_codes","farmed_species") %in% names(layer)),
  identical(names(concepts), c("coding","entity","terms")),
  nrow(concepts) == 9L,
  all(concepts$entity == "farmed species")
)
records_n <- nrow(layer)
none_n <- sum(layer$farmed_species_codes == "NONE")
coded_n <- sum(layer$farmed_species_codes != "NONE")
matches_n <- nrow(matches)
if(as.integer(run_manifest$records) != records_n ||
   as.integer(run_manifest$coded_records) != coded_n ||
   as.integer(run_manifest$none_records) != none_n ||
   as.integer(run_manifest$species_matches) != matches_n){
  stop("Workflow 05 run manifest counts do not match archived state",call.=FALSE)
}
if (any(grepl("spring salmon", concepts$terms, ignore.case = TRUE, fixed = TRUE))) stop("spring salmon must not be present", call. = FALSE)
if (!any(grepl("Salmons", concepts$terms, fixed = TRUE))) stop("Salmons missing from concepts", call. = FALSE)
if (!any(grepl("salmones", concepts$terms, fixed = TRUE))) stop("salmones missing from concepts", call. = FALSE)
if (any(grepl("primary|co-primary|assignment_role", names(layer), ignore.case = TRUE))) stop("Obsolete species-role field present in W05 layer", call. = FALSE)

named <- codes[codes$species_id != "UNSPEC_SALMON", c("record_id","species_id"), drop = FALSE]
generic_ids <- unique(codes$record_id[codes$species_id == "UNSPEC_SALMON"])
if (length(intersect(unique(named$record_id), generic_ids))) stop("UNSPEC_SALMON co-occurs with a named species in W05 codes", call. = FALSE)

concepts_sha <- digest(file = paths$concepts, algo = "sha256", serialize = FALSE)
if (!identical(tolower(as.character(run_manifest$dictionary_sha256)), tolower(concepts_sha))) {
  stop("Three-column concepts SHA does not match the validated W05 run manifest", call. = FALSE)
}

sha <- lapply(paths, function(p) digest(file = p, algo = "sha256", serialize = FALSE))

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set", call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)
archive_dir <- file.path(output_dir, "archive_files")
dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)

all_paths <- list.files(state_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
if (length(all_paths)) suppressWarnings(Sys.setFileTime(all_paths, as.POSIXct("2000-01-01", tz = "UTC")))

archive_name <- sprintf("LivingEvidenceMap_workflow05_run-%s_species_state.tar.gz", source_run_id)
archive_path <- file.path(archive_dir, archive_name)
old <- setwd(dirname(state_dir)); on.exit(setwd(old), add = TRUE)
utils::tar(archive_path, files = basename(state_dir), compression = "gzip", tar = "internal")
setwd(old); on.exit(NULL, add = FALSE)
if (!file.exists(archive_path) || file.info(archive_path)$size <= 0) stop("Failed to create Workflow 05 archive", call. = FALSE)

manifest <- list(
  schema = "living-evidence-map-workflow05-species-archive-v1",
  workflow = "05",
  state = "deterministic_species_coding",
  source_github_run_id = as.character(source_run_id),
  source_github_commit = as.character(source_commit),
  publication_github_run_id = as.character(publication_run_id),
  source_github_run_url = sprintf("https://github.com/%s/actions/runs/%s", repository, source_run_id),
  repository = repository,
  upstream_workflow04_zenodo_record_id = as.character(upstream_w04_record_id),
  upstream_workflow04_final_screening_layer_sha256 = upstream_w04_layer_sha,
  records = records_n,
  coded_records = coded_n,
  none_records = none_n,
  species_matches = matches_n,
  concept_rows = 9L,
  concept_schema = c("coding","entity","terms"),
  workflow05_species_layer_sha256 = sha$layer,
  species_codes_long_sha256 = sha$codes,
  species_matches_sha256 = sha$matches,
  species_record_counts_sha256 = sha$counts,
  workflow05_run_manifest_sha256 = sha$run_manifest,
  deterministic_concepts_sha256 = sha$concepts,
  file_visibility = "restricted",
  files = list(
    state_archive = list(
      filename = archive_name,
      bytes = unname(file.info(archive_path)$size),
      sha256 = digest(file = archive_path, algo = "sha256", serialize = FALSE)
    )
  )
)

manifest_name <- sprintf("LivingEvidenceMap_workflow05_run-%s_manifest.json", source_run_id)
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
  title = sprintf("Living Evidence Map Workflow 05 deterministic species-coding state | run %s", source_run_id),
  upload_type = "dataset",
  publication_date = format(Sys.Date(), "%Y-%m-%d"),
  description = paste0(
    "<p>Sparse deterministic species-coding state for Living Evidence Map Workflow 05.</p>",
    "<p>The layer is keyed by stable canonical record_id and records species codes derived from titles and abstracts using the versioned three-column coding/entity/terms vocabulary. ",
    "It does not duplicate the upstream canonical bibliographic database.</p>",
    "<p>Records: ", records_n, "; coded to at least one species category: ", coded_n, "; NONE: ", none_n, "; deterministic lexical matches: ", matches_n, ".</p>"
  ),
  creators = list(list(name = "Haddaway, Neal")),
  access_right = "restricted",
  access_conditions = "Files contain bibliographic record identifiers and deterministic coding provenance.",
  keywords = list(
    "Living Evidence Map", "Workflow 05", "species coding", "deterministic annotation",
    "evidence synthesis", paste0("LivingEvidenceMap-workflow05-run-", source_run_id)
  )
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
      stop(sprintf("Workflow 05 upload failed for %s HTTP %d", fn, st), call. = FALSE)
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
  archive_files = lapply(seq_along(upload_paths), function(i) {
    p <- upload_paths[[i]]; z <- uploaded[[i]]
    list(
      filename = basename(p),
      bytes = unname(file.info(p)$size),
      sha256 = digest(file = p, algo = "sha256", serialize = FALSE),
      zenodo_checksum = if (is.null(z$checksum)) NULL else z$checksum
    )
  }),
  manifest_sha256 = digest(file = manifest_path, algo = "sha256", serialize = FALSE),
  published_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
))

writeLines(
  toJSON(receipt, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = NA),
  file.path(output_dir, "zenodo_receipt.json"),
  useBytes = TRUE
)
cat(sprintf("PASS: published restricted Workflow 05 species state as Zenodo record %s\n", record_id))
