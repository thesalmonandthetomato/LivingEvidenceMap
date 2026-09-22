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
effective_farm_terms <- if (run_type=="expansion") additional_farm_term else farm_terms

join_or <- function(x) paste(x,collapse=" OR ")
species <- join_or(species_terms)
farm <- join_or(effective_farm_terms)

lens_block <- function(terms) {
  sprintf("(title:(%s) OR abstract:(%s) OR keyword:(%s))",terms,terms,terms)
}
lens_query <- sprintf("(%s AND %s)", lens_block(species), lens_block(farm))

scopus_query <- sprintf("TITLE-ABS-KEY((%s) AND (%s))", species, farm)

oa_quote <- function(x) {
  # preserve already quoted phrases, quote individual OQL terms otherwise
  x <- gsub('^"|"$','',x)
  paste0('"',x,'"')
}
oa_species <- paste(vapply(species_terms,oa_quote,character(1)),collapse=" or ")
oa_farm_terms <- if (run_type=="expansion") additional_farm_term else farm_terms
oa_farm <- paste(vapply(oa_farm_terms,oa_quote,character(1)),collapse=" or ")
openalex_query <- sprintf("works where title/abstract has ((%s) and (%s))",oa_species,oa_farm)

agricola_query <- sprintf("SRC:AGR AND TITLE_ABS:((%s) AND (%s))",species,farm)
europe_pmc_query <- sprintf("TITLE_ABS:((%s) AND (%s))",species,farm)

wos_component <- function(tag, farm_terms_string) {
  sprintf("%s=((%s) AND (%s))",tag,species,farm_terms_string)
}
wos_query <- paste0(
  "(",wos_component("TI",farm),") OR (",
  wos_component("AB",farm),") OR (",
  wos_component("AK",farm),")"
)

# Fortnightly date windows are source-specific. Only fields whose day-level semantics
# have been explicitly verified are encoded here.
today <- Sys.Date()
from_date <- today - 14L
if (run_type=="fortnightly") {
  scopus_query <- sprintf("(%s) AND ORIG-LOAD-DATE AFT %s",
                          scopus_query,format(from_date,"%Y%m%d"))
  agricola_query <- sprintf("(%s) AND FIRST_PDATE:[%s TO %s]",
                            agricola_query,format(from_date,"%Y-%m-%d"),format(today,"%Y-%m-%d"))
  europe_pmc_query <- sprintf("(%s) AND FIRST_PDATE:[%s TO %s]",
                              europe_pmc_query,format(from_date,"%Y-%m-%d"),format(today,"%Y-%m-%d"))
  wos_query <- sprintf("(%s) AND DOP=%s/%s",
                       wos_query,format(from_date,"%Y-%m-%d"),format(today,"%Y-%m-%d"))
}

queries <- list(
  lens=lens_query,
  scopus=scopus_query,
  openalex=openalex_query,
  agricola=agricola_query,
  europe_pmc=europe_pmc_query,
  wos=wos_query
)

support <- list(
  lens=list(full=TRUE,fortnightly=FALSE,quarterly=TRUE,expansion=TRUE),
  scopus=list(full=TRUE,fortnightly=TRUE,quarterly=TRUE,expansion=TRUE),
  openalex=list(full=TRUE,fortnightly=TRUE,quarterly=TRUE,expansion=TRUE),
  agricola=list(full=TRUE,fortnightly=TRUE,quarterly=TRUE,expansion=TRUE),
  europe_pmc=list(full=TRUE,fortnightly=TRUE,quarterly=TRUE,expansion=TRUE),
  wos=list(full=TRUE,fortnightly=TRUE,quarterly=TRUE,expansion=TRUE)
)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
plan <- list(
  workflow="00",
  status="planned",
  created_at=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
  run_type=run_type,
  search_version=cfg$search_version,
  immutable_species_terms=species_terms,
  base_farm_terms=farm_terms,
  additional_farm_term=if(nzchar(additional_farm_term)) additional_farm_term else NULL,
  effective_farm_terms=effective_farm_terms,
  expansion_policy=list(
    target="farm_terms_only",
    species_terms_mutable=FALSE,
    farm_terms_replaceable=FALSE,
    retrieval_rule=if(run_type=="expansion") "immutable species block AND new farm term only; existing corpus reconciliation removes already-known records" else NULL
  ),
  fortnightly_window=if(run_type=="fortnightly") list(from=as.character(from_date),to=as.character(today)) else NULL,
  source_queries=queries,
  source_mode_support=support
)

writeLines(toJSON(plan,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"search_plan.json"))
writeLines(toJSON(queries,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_dir,"source_queries.json"))
message(sprintf("PASS: Workflow 00 plan created for run_type=%s",run_type))
