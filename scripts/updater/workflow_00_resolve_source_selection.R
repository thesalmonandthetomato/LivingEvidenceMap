#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

run_type <- arg("--run-type")
saved_path <- arg("--saved","data/workflow00/source_selection.json")
output_path <- arg("--output","outputs/updater/workflow00_plan/source_selection.json")
ebsco_config <- arg("--ebsco-config","config/workflow00_ebsco_sources.json")

if (!(run_type %in% c("full","fortnightly","expansion"))) stop("Invalid run type",call.=FALSE)
cfg <- fromJSON(ebsco_config,simplifyVector=FALSE)
ebsco_sources <- names(cfg$sources)
base_sources <- c("lens","scopus","openalex","agricola","pubmed","ethos","cba","epmc_preprints","wos")
supported <- c(base_sources,ebsco_sources)

env_name <- function(src) paste0("W00_SELECT_",toupper(gsub("[^A-Za-z0-9]","_",src)))
selected_from_env <- function() {
  supported[vapply(supported,function(src) identical(tolower(Sys.getenv(env_name(src))),"true"),logical(1))]
}

if (run_type=="full") {
  selected <- selected_from_env()
  if (!length(selected)) stop("Select at least one source for a full Workflow 00 run",call.=FALSE)
  origin <- "full_run_inputs"
  baseline_run_id <- Sys.getenv("GITHUB_RUN_ID")
} else {
  if (!file.exists(saved_path)) {
    stop(sprintf("%s requires a saved full-run source selection at %s",run_type,saved_path),call.=FALSE)
  }
  saved <- fromJSON(saved_path,simplifyVector=FALSE)
  if (!identical(saved$schema,"living-evidence-map-workflow00-source-selection-v1")) {
    stop("Unsupported saved Workflow 00 source-selection schema",call.=FALSE)
  }
  selected <- trimws(as.character(unlist(saved$selected_sources,use.names=FALSE)))
  selected <- selected[nzchar(selected)]
  unknown <- setdiff(selected,supported)
  if (length(unknown)) stop(sprintf("Saved source selection contains unsupported sources: %s",paste(unknown,collapse=", ")),call.=FALSE)
  if (!length(selected)) stop("Saved source selection is empty",call.=FALSE)
  origin <- "saved_full_run"
  baseline_run_id <- as.character(saved$baseline_run_id)
}

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
out <- list(
  schema="living-evidence-map-workflow00-source-selection-v1",
  run_type=run_type,
  selection_origin=origin,
  baseline_run_id=baseline_run_id,
  selected_sources=selected,
  selected_source_count=length(selected),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(out,auto_unbox=TRUE,pretty=TRUE,null="null"),output_path)

gh <- Sys.getenv("GITHUB_OUTPUT")
if (nzchar(gh)) {
  con <- file(gh,"at")
  on.exit(close(con),add=TRUE)
  for (src in supported) {
    cat(sprintf("selected_%s=%s\n",src,if(src %in% selected)"true" else "false"),file=con)
  }
  cat(sprintf("selected_sources_csv=%s\n",paste(selected,collapse=",")),file=con)
  cat("selected_sources_json<<EOF\n",file=con)
  cat(toJSON(unname(selected),auto_unbox=TRUE),file=con)
  cat("\nEOF\n",file=con)
}
message(sprintf("PASS: Workflow 00 %s source selection: %s",run_type,paste(selected,collapse=", ")))
