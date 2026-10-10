#!/usr/bin/env Rscript
# Read-only scan; does not contact services or modify workflows.
files <- list.files(".github/workflows-inert", pattern="[.]ya?ml$", full.names=TRUE)
stopifnot(length(files)>0L)
for (f in files) {
  x <- paste(readLines(f, warn=FALSE), collapse="\n")
  flags <- c(
    branch=grepl("workflow01-final-architecture",x,fixed=TRUE),
    sheets=grepl("LEM_GOOGLE_SHEET_ID",x,fixed=TRUE),
    zenodo=grepl("ZENODO_ACCESS_TOKEN",x,fixed=TRUE),
    push=grepl("git push",x,fixed=TRUE)
  )
  cat(basename(f),paste(names(flags)[flags],collapse=","),"\n",sep=" | ")
}
cat("Audit complete; no workflow definitions were changed.\n")
