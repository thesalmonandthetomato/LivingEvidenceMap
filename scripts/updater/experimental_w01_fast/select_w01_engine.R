#!/usr/bin/env Rscript
# Isolated W01 engine-selection gate. This does NOT publish or dispatch anything.
# The production workflow is unchanged; this gate is pre-integration only.
a <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,a)
  if(is.na(i)) return(default)
  if(i==length(a)) stop("Missing value for ",flag)
  a[[i+1L]]
}
mode <- arg("--engine","legacy")
purpose <- arg("--purpose","preflight")
if(!identical(purpose,"preflight")) stop("Only non-publishing preflight is supported")
if(!mode %in% c("legacy","fast")) stop("Unsupported W01 engine: ",mode)
if(identical(mode,"legacy")) {
  cat("PASS: legacy engine remains default; production workflow is unchanged\n")
} else {
  required <- c(
    "scripts/updater/experimental_w01_fast/run_full_incremental_update.R",
    "scripts/updater/experimental_w01_fast/write_direct_delta.R",
    "scripts/updater/workflow_01_replay_delta.R",
    "scripts/updater/workflow_02_validate_canonical_handoff.R")
  if(any(!file.exists(required))) stop("Fast engine dependency unavailable")
  invisible(lapply(required,function(x)parse(file=x)))
  cat("PASS: fast engine explicitly selected; dependencies parse; no execution, publication or dispatch\n")
}
