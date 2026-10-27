#!/usr/bin/env Rscript
# One-off final decision overlay for W04 citation-chasing run 40298490744.
# Does not modify original model output, human review, or W04 architecture.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
args <- commandArgs(trailingOnly=TRUE)
if(length(args)!=2L) stop("Usage: Rscript script.R ORIGINAL_REVIEW_QUEUE OUTPUT_DIR")
input <- args[[1L]]; out <- args[[2L]]
rows <- lapply(readLines(input,warn=FALSE),function(x)fromJSON(x,simplifyVector=FALSE))
ids <- vapply(rows,function(x)as.character(x$record_id),character(1))
stopifnot(length(ids)==2944L,!anyDuplicated(ids))
stopifnot(all(vapply(rows,function(x)identical(x$screening$decision,"uncertain"),logical(1))))
dir.create(out,recursive=TRUE,showWarnings=FALSE)
p <- file.path(out,"oneoff_final_decision_overlay.jsonl")
overlay <- lapply(ids,function(id)list(
  record_id=id,final_decision="exclude",original_decision="uncertain",
  origin="oneoff_user_authorised_citation_chasing_override",
  source_run_id="40298490744",
  rationale="One-off strict aquaculture relevance rule for original W04 citation-chasing uncertainties"
))
writeLines(vapply(overlay,function(x)toJSON(x,auto_unbox=TRUE),character(1)),p,useBytes=TRUE)
manifest <- list(schema="w04-oneoff-final-decision-overlay-v1",
  source_run_id="40298490744",records=length(overlay),
  decision="exclude",overlay_sha256=digest(file=p,algo="sha256",serialize=FALSE))
write_json(manifest,file.path(out,"manifest.json"),pretty=TRUE,auto_unbox=TRUE)
cat("PASS: created immutable one-off 2944-record exclusion overlay\n")
