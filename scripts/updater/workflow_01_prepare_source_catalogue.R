#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))\n`%||%` <- function(x,y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

catalogue_path <- arg("--catalogue")
output_manifest <- arg("--output-manifest")
restore_script <- "scripts/updater/workflow_01_restore_manual_ris_from_zenodo.R"
if (is.null(catalogue_path) || is.null(output_manifest)) {
  stop("Required: --catalogue --output-manifest",call.=FALSE)
}
if (!file.exists(catalogue_path)) stop(sprintf("Catalogue not found: %s",catalogue_path),call.=FALSE)
if (!file.exists(restore_script)) stop("Manual RIS restore script not found",call.=FALSE)

x <- fromJSON(catalogue_path,simplifyVector=FALSE)
if (!identical(x$schema,"living-evidence-map-workflow01-source-catalogue-v1")) {
  stop("Unsupported Workflow 01 source catalogue schema",call.=FALSE)
}
sources <- x$sources
if (is.null(sources) || !length(sources) || is.null(names(sources))) stop("Source catalogue contains no sources",call.=FALSE)

rscript <- file.path(R.home("bin"),"Rscript")
input_paths <- list()
manual_restored <- list()

for (src in names(sources)) {
  z <- sources[[src]]
  kind <- as.character(z$kind %||% "")
  prepared <- as.character(z$prepared_path %||% "")
  if (!nzchar(prepared)) stop(sprintf("Catalogue source %s lacks prepared_path",src),call.=FALSE)

  if (identical(kind,"manual_ris")) {
    registry <- as.character(z$registry %||% "")
    if (!nzchar(registry) || !file.exists(registry)) stop(sprintf("Manual RIS registry missing for %s: %s",src,registry),call.=FALSE)
    dir.create(dirname(prepared),recursive=TRUE,showWarnings=FALSE)
    status <- system2(
      rscript,
      c(restore_script,"--registry",registry,"--source",src,"--output",prepared)
    )
    if (status != 0L) stop(sprintf("Manual RIS restore failed for %s",src),call.=FALSE)
    manual_restored[[src]] <- registry
  } else if (!identical(kind,"workflow00_state")) {
    stop(sprintf("Unsupported catalogue source kind for %s: %s",src,kind),call.=FALSE)
  }

  if (!file.exists(prepared) || file.info(prepared)$size <= 0) {
    stop(sprintf("Prepared source input missing/empty for %s: %s",src,prepared),call.=FALSE)
  }
  input_paths[[src]] <- prepared
}

manifest <- list(
  schema="living-evidence-map-workflow01-source-inputs-v1",
  status="validated",
  sources=input_paths,
  manual_ris_registries=manual_restored,
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
dir.create(dirname(output_manifest),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null"),output_manifest)

cat(sprintf(
  "PASS: prepared Workflow 01 source-input manifest with %d sources (%d manual RIS)\n",
  length(input_paths),length(manual_restored)
))
