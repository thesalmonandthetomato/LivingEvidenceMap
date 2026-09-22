#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag), call.=FALSE)
  args[[i+1L]]
}

run_type <- arg("--run-type")
additional_farm_term <- trimws(arg("--additional-farm-term",""))
config_path <- arg("--config","config/workflow00_search_strategy.json")
output_dir <- arg("--output-dir","outputs/updater/workflow00_plan")

if (!(run_type %in% c("full","fortnightly","quarterly","expansion"))) {
  stop("--run-type must be full, fortnightly, quarterly, or expansion", call.=FALSE)
}

cfg <- fromJSON(config_path, simplifyVector=TRUE)

if (run_type=="expansion" && !nzchar(additional_farm_term)) {
  stop("Expansion mode requires --additional-farm-term", call.=FALSE)
}
if (run_type!="expansion" && nzchar(additional_farm_term)) {
  stop("--additional-farm-term is only allowed in expansion mode", call.=FALSE)
}

species_terms <- unname(cfg$species_terms)
farm_terms <- unname(cfg$farm_terms)
expanded_farm_terms <- farm_terms
if (run_type=="expansion") expanded_farm_terms <- unique(c(farm_terms, additional_farm_term))

dir.create(output_dir, recursive=TRUE, showWarnings=FALSE)

plan <- list(
  workflow="00",
  status="planned",
  created_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  run_type=run_type,
  search_version=cfg$search_version,
  immutable_species_terms=species_terms,
  base_farm_terms=farm_terms,
  additional_farm_term=if (nzchar(additional_farm_term)) additional_farm_term else NULL,
  effective_farm_terms=expanded_farm_terms,
  expansion_policy=list(
    target="farm_terms_only",
    species_terms_mutable=FALSE,
    farm_terms_replaceable=FALSE
  )
)

writeLines(toJSON(plan,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"search_plan.json"))
message(sprintf("PASS: Workflow 00 plan created for run_type=%s", run_type))
