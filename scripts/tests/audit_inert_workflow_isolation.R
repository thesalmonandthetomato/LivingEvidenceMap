#!/usr/bin/env Rscript
# Read-only scan; does not contact services or modify workflows.
args <- commandArgs(trailingOnly=TRUE)
mode <- if(length(args)) args[[1L]] else "report"
stopifnot(mode %in% c("report","enforce"))
unsafe_found <- FALSE
files <- list.files(".github/workflows-inert", pattern="[.]ya?ml$", full.names=TRUE)
stopifnot(length(files)>0L)
for (f in files) {
  x <- paste(readLines(f, warn=FALSE), collapse="\n")
  flags <- c(
    branch=grepl("workflow01-final-architecture",x,fixed=TRUE),
    sheets=grepl("LEM_GOOGLE_SHEET_ID",x,fixed=TRUE),
    hardcoded_sheet=grepl("1e9-V67-8lwPO6YBqeGJWn-SFanWSze5Gi2ToKR4bXvA",x,fixed=TRUE) |
      grepl("1x00D0idQz558dKp3gB0z-mcUBVrw8jjllqGAZdqYlcs",x,fixed=TRUE),
    zenodo=grepl("ZENODO_ACCESS_TOKEN",x,fixed=TRUE),
    push=grepl("git push",x,fixed=TRUE)
  )
  unsafe_found <- unsafe_found || any(flags[c("branch","hardcoded_sheet","zenodo","push")])
  cat(basename(f),paste(names(flags)[flags],collapse=","),"\n",sep=" | ")
}
cat("Audit complete; no workflow definitions were changed.\\n")
if (mode == "enforce" && unsafe_found) stop("Unsafe targets remain: release refused")
