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

# MVP must start with empty, schema-preserving Zenodo registries.
registries <- list.files("docs",pattern="^zenodo_registry[.]csv$",recursive=TRUE,full.names=TRUE)
stopifnot(length(registries)==9L)
nonempty <- registries[vapply(registries,function(p) length(readLines(p,warn=FALSE))>1L,logical(1))]
if(length(nonempty)) {
  cat("Non-empty Zenodo registry: ",paste(nonempty,collapse=", "),"\n",sep="")
  unsafe_found <- TRUE
}
# W10 must never publish to another repository or internal path.
w10 <- paste(readLines(".github/workflows-inert/workflow_10_dashboard.yml",warn=FALSE),collapse="\n")
if(any(vapply(c("salmonevidencemap","public-site","SALMON_EVIDENCE_MAP_PUBLISH_TOKEN",
                "Commit internal output registry archive"),grepl,logical(1),x=w10,fixed=TRUE))) {
  cat("W10 has a publication target outside docs.\n")
  unsafe_found <- TRUE
}
cat("Audit complete; no workflow definitions were changed.\\n")
if (mode == "enforce" && unsafe_found) stop("Unsafe targets remain: release refused")
