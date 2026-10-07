suppressPackageStartupMessages(library(jsonlite))

td <- tempfile("w02-stale-patch-")
dir.create(td, recursive=TRUE)

write_jsonl <- function(xs, path) {
  con <- file(path, "wt", encoding="UTF-8"); on.exit(close(con))
  for (x in xs) writeLines(toJSON(x, auto_unbox=TRUE, null="null", na="null"), con, useBytes=TRUE)
}
read_jsonl <- function(path) {
  x <- readLines(path, warn=FALSE, encoding="UTF-8"); x <- x[nzchar(trimws(x))]
  lapply(x, fromJSON, simplifyVector=FALSE)
}

input <- file.path(td, "input.jsonl")
patch <- file.path(td, "patch.jsonl")
out <- file.path(td, "out.jsonl")
report <- file.path(td, "report.json")

write_jsonl(list(list(
  identity=list(record_id="work-test"),
  canonical=list(doi="10.9999/new", title="Existing title", abstract=NULL)
)), input)

write_jsonl(list(list(
  record_id="work-test",
  input_doi="https://doi.org/10.9999/old",
  abstract=list(value="STALE ABSTRACT", provider="test"),
  metadata_enrichment=list(status="old-provenance")
)), patch)

status <- system2(
  file.path(R.home("bin"), "Rscript"),
  c("scripts/updater/workflow_02_apply_patch.R",
    "--input", input, "--patch", patch, "--output", out, "--report", report,
    "--mode", "fill_missing"),
  stdout=FALSE, stderr=FALSE
)
stopifnot(status == 0L)
z <- read_jsonl(out)[[1L]]
r <- fromJSON(report, simplifyVector=FALSE)
stopifnot(
  is.null(z$canonical$abstract),
  is.null(z$metadata_enrichment),
  as.integer(r$stale_patch_records) == 1L,
  identical(as.character(r$stale_patches[[1L]]$reason), "input_doi_changed")
)

status <- system2(
  file.path(R.home("bin"), "Rscript"),
  c("scripts/updater/workflow_02_apply_patch.R",
    "--input", input, "--patch", patch,
    "--output", file.path(td, "exact.jsonl"),
    "--report", file.path(td, "exact-report.json"),
    "--mode", "exact"),
  stdout=FALSE, stderr=FALSE
)
stopifnot(status != 0L)

# DOI URL/prefix normalisation must not invalidate a compatible patch.
write_jsonl(list(list(
  record_id="work-test",
  input_doi="https://doi.org/10.9999/new",
  abstract=list(value="VALID ABSTRACT", provider="test"),
  metadata_enrichment=list(status="current")
)), patch)

status <- system2(
  file.path(R.home("bin"), "Rscript"),
  c("scripts/updater/workflow_02_apply_patch.R",
    "--input", input, "--patch", patch,
    "--output", out, "--report", report,
    "--mode", "fill_missing"),
  stdout=FALSE, stderr=FALSE
)
stopifnot(status == 0L)
z <- read_jsonl(out)[[1L]]
r <- fromJSON(report, simplifyVector=FALSE)
stopifnot(
  identical(as.character(z$canonical$abstract), "VALID ABSTRACT"),
  identical(as.character(z$metadata_enrichment$status), "current"),
  as.integer(r$stale_patch_records) == 0L
)

cat("PASS: W02 stale enrichment patches are rejected on DOI identity change\n")
