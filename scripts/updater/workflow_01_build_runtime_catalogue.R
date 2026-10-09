#!/usr/bin/env Rscript
# Construct a topic-independent W01 source catalogue from the W00 source list.
# Optional project-specific manual RIS registries are supplied at runtime,
# not embedded in reusable pipeline code.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
get_arg <- function(flag, default=NULL) {
  idx <- which(args == flag)
  if (!length(idx)) return(default)
  if (length(idx)!=1L || idx==length(args)) stop(paste("Invalid argument",flag),call.=FALSE)
  args[[idx+1L]]
}
sources_arg <- get_arg("--w00-sources")
output <- get_arg("--output")
manual_path <- get_arg("--manual-config")
if (is.null(sources_arg) || is.null(output)) {
  stop("Required: --w00-sources CSV --output PATH [--manual-config PATH]",call.=FALSE)
}
src <- trimws(strsplit(sources_arg,",",fixed=TRUE)[[1L]])
src <- unique(src[nzchar(src)])
if (!length(src) || any(!grepl("^[a-z][a-z0-9_]*$",src))) {
  stop("W00 sources must be non-empty valid source IDs",call.=FALSE)
}
catalogue <- list(
  schema="living-evidence-map-workflow01-source-catalogue-v1",
  description="Runtime W01 catalogue derived from the selected W00 sources",
  sources=setNames(lapply(src,function(s) list(
    kind="workflow00_state",source=s,
    prepared_path=file.path("current_sources",s,"records.jsonl")
  )),src)
)
if (!is.null(manual_path)) {
  if (!file.exists(manual_path)) stop("Manual source config not found",call.=FALSE)
  manual <- fromJSON(manual_path,simplifyVector=FALSE)
  if (!identical(manual$schema,"living-evidence-map-workflow01-manual-sources-v1") ||
      is.null(manual$sources) || is.null(names(manual$sources))) {
    stop("Invalid manual source configuration",call.=FALSE)
  }
  for (s in names(manual$sources)) {
    if (!grepl("^[a-z][a-z0-9_]*$",s) || s %in% src) {
      stop(paste("Invalid or duplicate manual source",s),call.=FALSE)
    }
    registry <- manual$sources[[s]]$registry
    if (is.null(registry) || length(registry)!=1L || !nzchar(registry)) {
      stop(paste("Missing manual RIS registry for",s),call.=FALSE)
    }
    catalogue$sources[[s]] <- list(
      kind="manual_ris",registry=registry,
      prepared_path=file.path("current_sources",s,"records.jsonl")
    )
  }
}
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(catalogue,auto_unbox=TRUE,pretty=TRUE,null="null"),output)
cat(sprintf("Generated W01 runtime catalogue for %d source(s)\n",length(catalogue$sources)))
