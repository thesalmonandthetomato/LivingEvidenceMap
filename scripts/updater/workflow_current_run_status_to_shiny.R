#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(googlesheets4)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
val <- function(x){
  if(is.null(x)||!length(x)) return("")
  z<-as.character(x[[1L]])
  if(is.na(z)) "" else z
}

status_path <- arg("--status","docs/current_run/current_run_status.json")
sheet_id <- arg("--sheet-id",Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential <- arg("--credential",Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
if(!file.exists(status_path)) stop("Current-run status file not found",call.=FALSE)
if(is.null(sheet_id)||!nzchar(sheet_id)) stop("Google Sheet ID missing",call.=FALSE)
if(is.null(credential)||!file.exists(credential)) stop("Google credential missing",call.=FALSE)

s <- fromJSON(status_path,simplifyVector=FALSE)
if(!identical(as.character(s$schema),"living-evidence-map-current-run-status-v1")) stop("Unexpected status schema",call.=FALSE)

stage <- val(s$progress$current_stage)
run_id <- if(nzchar(stage)) val(s$workflow_runs[[stage]]) else ""
cmd <- c(
  "scripts/updater/workflow_shiny_pipeline_status.R",
  "--update-id",val(s$update_id),
  "--stage",if(nzchar(stage)) stage else "status_reconcile",
  "--workflow-run-id",run_id,
  "--last-search-date",val(s$search$search_date),
  "--canonical-existing",val(s$baseline$canonical_records),
  "--search-results-total",val(s$counts$search_results),
  "--deduplicated-records",val(s$counts$deduplicated_records),
  "--enriched-records",val(s$counts$enriched_records),
  "--retracted-records",val(s$counts$retraction_exclusions),
  "--screened-include",val(s$counts$screened_include),
  "--screened-exclude",val(s$counts$screened_exclude),
  "--geography-with",val(s$counts$geography$with),
  "--geography-without",val(s$counts$geography$without),
  "--topic-with",val(s$counts$topics$with),
  "--topic-without",val(s$counts$topics$without),
  "--completed-through",val(s$progress$completed_through),
  "--active-workflow",val(s$progress$active_position),
  "--status-label",val(s$progress$status_label),
  "--sheet-id",sheet_id,
  "--credential",credential
)
st <- system2("Rscript", vapply(cmd, shQuote, character(1)))
if(st!=0L) stop("Failed syncing current-run status to Shiny backing sheet",call.=FALSE)
cat(sprintf("PASS: synced current-run status %s to Shiny\n",val(s$update_id)))
