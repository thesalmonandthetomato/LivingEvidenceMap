#!/usr/bin/env Rscript
# Pure translation-output materialisation; does not contact Lens.
suppressPackageStartupMessages(library(jsonlite))
args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag) {
  i <- match(flag,args)
  if (is.na(i) || i == length(args)) stop(sprintf("Missing required %s",flag),call.=FALSE)
  args[[i+1L]]
}
query <- arg("--query")
output <- arg("--output")
if (!is.character(query) || length(query)!=1L || !nzchar(trimws(query))) {
  stop("Lens translation produced an empty query; no search can be submitted",call.=FALSE)
}
cfg <- list(api_query=list(query=list(bool=list(must=list(list(query_string=list(query=query)))))))
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(cfg,auto_unbox=TRUE,pretty=TRUE,null="null"),output,useBytes=TRUE)
message(sprintf("Created Lens request configuration at %s",output))
