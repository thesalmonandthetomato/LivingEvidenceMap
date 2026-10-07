suppressPackageStartupMessages({
  library(jsonlite)
  library(data.table)
  library(digest)
})

repo_root <- normalizePath(".", mustWork=TRUE)
rscript <- file.path(R.home("bin"), "Rscript")

run_status <- function(args) {
  suppressWarnings(system2(rscript, args=args, stdout=FALSE, stderr=FALSE))
}

td <- tempfile("w01-source-order-regression-")
dir.create(td, recursive=TRUE)
prev <- file.path(td, "previous")
checkpoint <- file.path(td, "checkpoint")
out <- file.path(td, "out")
dir.create(prev)
dir.create(file.path(checkpoint, "source_manifestations"), recursive=TRUE)

writeLines('{"record":"zeta-old"}', file.path(prev, "zeta_records_for_deduplication.jsonl"))
writeLines('{"record":"alpha-old"}', file.path(prev, "alpha_records_for_deduplication.jsonl"))
writeLines('{"record":"zeta-new"}', file.path(checkpoint, "source_manifestations", "zeta_new.jsonl"))
writeLines('{"record":"alpha-new"}', file.path(checkpoint, "source_manifestations", "alpha_new.jsonl"))

manifest <- list(
  new_source_manifestations_by_source=list(zeta=1L, alpha=1L),
  source_order=c("zeta","alpha"),
  source_files=list(
    zeta="zeta_records_for_deduplication.jsonl",
    alpha="alpha_records_for_deduplication.jsonl"
  )
)
writeLines(
  toJSON(manifest, auto_unbox=TRUE, pretty=TRUE),
  file.path(checkpoint, "checkpoint_manifest.json")
)

status <- run_status(c(
  "scripts/updater/workflow_01_apply_checkpoint_sources.R",
  "--previous-seed", prev,
  "--checkpoint-dir", checkpoint,
  "--output-dir", out
))
stopifnot(status == 0L)

rebuilt <- fromJSON(file.path(out, "source_inputs.json"), simplifyVector=FALSE)
stopifnot(identical(names(rebuilt$sources), c("zeta","alpha")))
stopifnot(identical(
  readLines(file.path(out, "zeta_records_for_deduplication.jsonl"), warn=FALSE),
  c('{"record":"zeta-old"}','{"record":"zeta-new"}')
))
stopifnot(identical(
  readLines(file.path(out, "alpha_records_for_deduplication.jsonl"), warn=FALSE),
  c('{"record":"alpha-old"}','{"record":"alpha-new"}')
))

legacy <- manifest
legacy$source_order <- NULL
writeLines(
  toJSON(legacy, auto_unbox=TRUE, pretty=TRUE),
  file.path(checkpoint, "checkpoint_manifest.json")
)
unlink(out, recursive=TRUE)
status <- run_status(c(
  "scripts/updater/workflow_01_apply_checkpoint_sources.R",
  "--previous-seed", prev,
  "--checkpoint-dir", checkpoint,
  "--output-dir", out
))
stopifnot(status != 0L)

meta_ok <- data.table(
  idx=1:2,
  source=c("zeta","alpha"),
  source_record_id=c("z1","a1")
)
meta_ok_path <- file.path(td, "metadata-ok.csv")
fwrite(meta_ok, meta_ok_path)
payload <- paste(
  paste(meta_ok$idx, meta_ok$source, meta_ok$source_record_id, sep="\t"),
  collapse="\n"
)
identity_manifest <- list(
  dedup_index_identity=list(
    rows=nrow(meta_ok),
    sha256=digest(payload, algo="sha256", serialize=FALSE)
  )
)
identity_manifest_path <- file.path(td, "identity-manifest.json")
writeLines(toJSON(identity_manifest, auto_unbox=TRUE, pretty=TRUE), identity_manifest_path)

status <- run_status(c(
  "scripts/updater/workflow_01_validate_index_identity.R",
  "--metadata", meta_ok_path,
  "--checkpoint-manifest", identity_manifest_path
))
stopifnot(status == 0L)

meta_bad <- copy(meta_ok)
meta_bad[, source := rev(source)]
meta_bad[, source_record_id := rev(source_record_id)]
meta_bad_path <- file.path(td, "metadata-bad.csv")
fwrite(meta_bad, meta_bad_path)
status <- run_status(c(
  "scripts/updater/workflow_01_validate_index_identity.R",
  "--metadata", meta_bad_path,
  "--checkpoint-manifest", identity_manifest_path
))
stopifnot(status != 0L)

builder <- paste(
  readLines("scripts/updater/workflow_01_build_pending_checkpoint.R", warn=FALSE),
  collapse="\n"
)
stopifnot(
  grepl("source_order=unname(source_order)", builder, fixed=TRUE),
  grepl("dedup_index_identity=list(", builder, fixed=TRUE),
  !grepl("for(src in sort(current_sources))", builder, fixed=TRUE)
)

cat("PASS: W01 checkpoint source order and dedup index identity are fail-closed\n")
