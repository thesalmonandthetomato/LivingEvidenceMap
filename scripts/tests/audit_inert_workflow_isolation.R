#!/usr/bin/env Rscript
# Read-only scan; does not contact services or modify workflows.
args <- commandArgs(trailingOnly=TRUE)
mode <- if(length(args)) args[[1L]] else "report"
phase <- if(length(args)>1L) args[[2L]] else "bootstrap"
stopifnot(mode %in% c("report","enforce"),phase %in% c("bootstrap","update"))
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
  unsafe_found <- unsafe_found || any(flags[c("branch","hardcoded_sheet")])
  cat(basename(f),paste(names(flags)[flags],collapse=","),"\n",sep=" | ")
}

# Zenodo is expected to populate new test records after the first publication.
registries <- list.files("docs",pattern="^zenodo_registry[.]csv$",recursive=TRUE,full.names=TRUE)
stopifnot(length(registries)==9L)
nonempty <- registries[vapply(registries,function(p) length(readLines(p,warn=FALSE))>1L,logical(1))]
if(phase=="bootstrap" && length(nonempty)) {
  cat("First-run registries contain existing records: ",paste(nonempty,collapse=", "),"\n",sep="")
  unsafe_found <- TRUE
}
if(phase=="update" && !length(nonempty)) {
  cat("Update mode has no previously published test registry state.\n")
  unsafe_found <- TRUE
}
stages <- c("workflow_00_search_orchestrator.yml","workflow_01_production.yml",
            "workflow_02_batched.yml","workflow_02_production.yml",
            sprintf("workflow_%02d_production.yml",3:8))
for(name in stages){
  x <- paste(readLines(file.path(".github/workflows-inert",name),warn=FALSE),collapse="\n")
  if(!grepl("      first_run:",x,fixed=TRUE) ||
     !grepl("workflow_validate_first_run.R",x,fixed=TRUE)) {
    cat("First-run contract missing from ",name,"\n",sep="")
    unsafe_found <- TRUE
  }
}
# W10 must never publish to another repository or internal path.
w10 <- paste(readLines(".github/workflows-inert/workflow_10_dashboard.yml",warn=FALSE),collapse="\n")
if(any(vapply(c("salmonevidencemap","public-site","SALMON_EVIDENCE_MAP_PUBLISH_TOKEN",
                "Commit internal output registry archive"),grepl,logical(1),x=w10,fixed=TRUE))) {
  cat("W10 has a publication target outside docs.\n")
  unsafe_found <- TRUE
}
if (phase=="bootstrap" && file.exists("docs/current_run/current_run_status.json")) {
  cat("Inherited current-run status detected; test isolation refused.\\n")
  unsafe_found <- TRUE
}
cat("Static destination audit complete; end-to-end first-run execution remains separately unvalidated.\\n")
if (mode == "enforce" && unsafe_found) stop("Unsafe targets remain: release refused")
