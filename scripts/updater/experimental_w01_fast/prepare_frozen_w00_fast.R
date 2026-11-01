#!/usr/bin/env Rscript
# Experimental W01-Fast benchmark orchestration. Runs production preparatory scripts
# read-only in the runner workspace; never publishes or modifies canonical state.
suppressPackageStartupMessages({library(jsonlite);library(yaml)})
w00 <- "docs/search_record/zenodo/run-39298022062.json"
w01 <- "docs/deduplication/zenodo/run-39140209398.json"
root <- "outputs/experimental_w01_fast"
dir.create(root, recursive=TRUE, showWarnings=FALSE)
report <- list(schema="experimental-w01-fast-real-benchmark-v1",
  workflow00_pointer=w00, previous_workflow01_pointer=w01,
  production_w01_modified=FALSE, production_publication_allowed=FALSE,
  stages=list())
save_report <- function() writeLines(
  toJSON(report,pretty=TRUE,auto_unbox=TRUE,null="null"),
  file.path(root,"benchmark-stages.json"))
run_step <- function(name, executable, args) {
  cat("BEGIN SHADOW:", name, "\n"); flush.console()
  start <- proc.time()[["elapsed"]]
  code <- suppressWarnings(system2(executable,args,stdout="",stderr=""))
  secs <- round(proc.time()[["elapsed"]]-start,2)
  report$stages[[length(report$stages)+1L]] <<- list(
    name=name, exit_code=as.integer(code), seconds=secs)
  save_report()
  cat("END SHADOW:",name,"status",code,"seconds",secs,"\n")
  if (!identical(as.integer(code),0L)) stop(sprintf("Benchmark stage failed: %s",name),call.=FALSE)
}
workflow <- yaml::read_yaml(".github/workflows/workflow_01_production.yml")
steps <- workflow$jobs$prepare$steps
required <- c(
  "Restore latest Workflow 01 state from baseline plus deltas",
  "Restore current Workflow 00 source subset",
  "Prepare updated and preserved API source inputs",
  "Build runtime source catalogue and validate source inputs",
  "Build provenance-safe prior-plus-new manifestation union")
for (name in required) {
  matching <- Filter(function(x) identical(x$name,name),steps)
  if (length(matching)!=1L || !is.character(matching[[1L]]$run) ||
      !identical(matching[[1L]]$shell,"bash"))
    stop(sprintf("Missing or unexpected production shell stage: %s",name))
  script <- matching[[1L]]$run
  script <- gsub("${{ inputs.workflow00_pointer_path }}",w00,script,fixed=TRUE)
  script <- gsub("${{ inputs.previous_workflow01_pointer_path }}",w01,script,fixed=TRUE)
  if (grepl("${{",script,fixed=TRUE)) stop(paste("Unresolved workflow input in",name))
  path <- tempfile(pattern="w01-fast-stage-",fileext=".sh")
  writeLines(script,path)
  run_step(name,"bash",c("-euo","pipefail",path))
}

# Generate *metadata only*, avoiding conventional candidate generation entirely.
run_step("normalise_metadata_only","Rscript",c(
  "scripts/updater/workflow_01_deduplication_incremental_candidates.R",
  "--input-manifest","outputs/workflow01_union/source_inputs.json",
  "--old-manifestation-map","previous_state/workflow01_full_five_source/manifestation_cluster_map.csv",
  "--output-dir","outputs/workflow01_candidates",
  "--score-n","1","--validate-index-only","true"))
stopifnot(file.exists("outputs/workflow01_candidates/normalised_metadata.csv"),
 file.exists("outputs/workflow01_union/source_inputs.json"),
 file.exists("previous_state/canonical/records.jsonl"))
cat("PASS: frozen authoritative W00 state and prior W01 restored, metadata-only preparation; no ordinary pair generation\\n")
