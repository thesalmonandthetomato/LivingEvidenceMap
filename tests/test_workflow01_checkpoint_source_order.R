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


# End-to-end checkpoint contract: adjudicate artifact -> canonicalise inputs ->
# checkpoint files -> restore contract, including a negative missing-file test.
workflow_yaml <- readLines(".github/workflows/workflow_01_production.yml",warn=FALSE)
handoff_upload <- paste(workflow_yaml[grep("name: Transfer stage adjudicate working state",workflow_yaml,fixed=TRUE):
  grep("^  canonicalise:",workflow_yaml)[[1L]]],collapse="\\n")
stopifnot(grepl("outputs/workflow01_incremental_assisted/final_incremental_decisions.csv",
               handoff_upload,fixed=TRUE))
stopifnot(grepl("outputs/workflow01_incremental_assisted/final_incremental_decisions.csv",
               paste(workflow_yaml,collapse="\\n"),fixed=TRUE))

fixture <- file.path(td,"build-checkpoint-fixture")
seed <- file.path(fixture,"seed")
previous_root <- file.path(fixture,"previous_state")
review <- file.path(fixture,"review")
dir.create(seed,recursive=TRUE)
dir.create(file.path(previous_root,"workflow01_seed"),recursive=TRUE)
dir.create(review)
for(src in c("zeta","alpha")) {
  old_row <- paste0('{"id":"',src,'-old"}')
  new_row <- paste0('{"id":"',src,'-new"}')
  writeLines(old_row,file.path(previous_root,"workflow01_seed",
                             paste0(src,"_records_for_deduplication.jsonl")))
  writeLines(c(old_row,new_row),
             file.path(seed,paste0(src,"_records_for_deduplication.jsonl")))
}
writeLines(toJSON(list(schema="living-evidence-map-workflow01-source-inputs-v1",
  sources=list(
    zeta=list(file.path(seed,"zeta_records_for_deduplication.jsonl")),
    alpha=list(file.path(seed,"alpha_records_for_deduplication.jsonl"))
  )),auto_unbox=TRUE,pretty=TRUE),file.path(seed,"source_inputs.json"))
checkpoint_metadata <- data.table(idx=1:4,source=c("zeta","zeta","alpha","alpha"),
  source_record_id=c("z-old","z-new","a-old","a-new"))
metadata_file <- file.path(fixture,"metadata.csv")
fwrite(checkpoint_metadata,metadata_file)
incremental_file <- file.path(fixture,"incremental_decisions.csv")
fwrite(data.table(record_i=2L,record_j=4L,decision="not_duplicate"),incremental_file)
adjudications_file <- file.path(fixture,"all_adjudications.jsonl")
writeLines('{"review_case_id":"fixture","promotion":"human_review"}',adjudications_file)
pre_summary_file <- file.path(fixture,"pre_summary.json")
writeLines('{"source_manifestations":4,"manual_review_pairs":1}',pre_summary_file)
writeLines('{"review_case_id":"fixture"}',file.path(review,"human_review_cases.jsonl"))
writeLines(toJSON(list(pending_count=1L,queue_sha256="fixture-queue-hash"),
                  auto_unbox=TRUE),file.path(review,"review_manifest.json"))
pointer_w00 <- "docs/search_record/zenodo/run-45130154568.json"
pointer_w01 <- "docs/deduplication/zenodo/run-40218882441.json"
stopifnot(file.exists(pointer_w00),file.exists(pointer_w01))
build_checkpoint <- function(incremental,output) {
  run_status(c(
    "scripts/updater/workflow_01_build_pending_checkpoint.R",
    "--previous-root",previous_root,
    "--current-seed-root",seed,
    "--incremental-rescore",incremental,
    "--adjudications",adjudications_file,
    "--review-package",review,
    "--pre-summary",pre_summary_file,
    "--metadata",metadata_file,
    "--previous-pointer",pointer_w01,
    "--workflow00-pointer",paste0("workflow00_registry/",pointer_w00),
    "--output-dir",output,
    "--run-id","45168128006"
  ))
}
out_good <- file.path(fixture,"checkpoint-success")
stopifnot(build_checkpoint(incremental_file,out_good)==0L)
check_manifest <- fromJSON(file.path(out_good,"checkpoint_manifest.json"),simplifyVector=FALSE)
stopifnot(
  identical(check_manifest$schema,"living-evidence-map-workflow01-pending-checkpoint-v1"),
  as.integer(check_manifest$new_source_manifestations)==2L,
  as.integer(check_manifest$pending_human_cases)==1L,
  identical(check_manifest$files$incremental_rescored_pairs_sha256,
            digest(file=incremental_file,algo="sha256",serialize=FALSE))
)
expected_checkpoint_files <- c(
  "incremental_rescored_pairs.csv","all_adjudications.jsonl",
  "pre_adjudication_summary.json","previous_workflow01_pointer.json",
  "workflow00_pointer.json","human_review_package/review_manifest.json",
  "human_review_package/human_review_cases.jsonl","checkpoint_manifest.json"
)
stopifnot(all(file.exists(file.path(out_good,expected_checkpoint_files))))
out_missing <- file.path(fixture,"checkpoint-missing-input")
stopifnot(build_checkpoint(file.path(fixture,"does_not_exist.csv"),out_missing)!=0L)
stopifnot(!file.exists(file.path(out_missing,"checkpoint_manifest.json")))
cat("PASS: W01 checkpoint successful handoff and fail-closed missing input regression\\n")

cat("PASS: W01 checkpoint source order and dedup index identity are fail-closed\n")
