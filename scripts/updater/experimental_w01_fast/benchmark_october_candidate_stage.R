#!/usr/bin/env Rscript
# Frozen October candidate-stage benchmark only. Never a full W01 runtime claim.
suppressPackageStartupMessages({library(jsonlite);library(data.table)})
base <- "scripts/updater/experimental_w01_fast"
metadata <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
if(!file.exists(metadata))stop("Missing frozen October candidate metadata")
output <- "october_candidate_benchmark"
if(file.exists(output)||dir.exists(output))stop("Refuse to overwrite candidate benchmark")
dir.create(output)
stages <- list()
run <- function(label,script,args){
 start <- proc.time()[["elapsed"]]
 out <- suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),c(script,args),stdout=TRUE,stderr=TRUE))
 code <- attr(out,"status");if(is.null(code))code<-0L
 seconds <- unname(proc.time()[["elapsed"]]-start)
 stages[[label]] <<- list(exit_code=as.integer(code),elapsed_seconds=round(seconds,3))
 if(code!=0L)stop(sprintf("%s failed: %s",label,paste(tail(out,16L),collapse=" | ")))
 cat(sprintf("PASS: %s elapsed %.3f seconds\\n",label,seconds))
}
run("exact",file.path(base,"build_exact_block_index.R"),
 c("--metadata",metadata,"--prior-n","135997","--output-dir",file.path(output,"exact")))
run("fuzzy",file.path(base,"build_fuzzy_candidates.R"),
 c("--metadata",metadata,"--prior-n","135997","--output-dir",file.path(output,"fuzzy")))
run("combine",file.path(base,"combine_candidates.R"),
 c("--exact",file.path(output,"exact","exact_block_candidates.csv"),
 "--fuzzy",file.path(output,"fuzzy","fuzzy_candidates.csv"),
 "--output",file.path(output,"combined.csv")))
pairs<-fread(file.path(output,"combined.csv"))
reference<-fread("reference/outputs/workflow01_candidates/all_candidate_pairs.csv")
if(nrow(pairs)!=1719L||nrow(reference)!=1719L)stop("Unexpected candidate pair size")
run("normalise_reference",file.path(base,"normalise_october_candidate_reference.R"),
 c("reference","reference/outputs/workflow01_candidates/all_candidate_pairs.csv",file.path(output,"reference_stable")))
run("normalise_fast",file.path(base,"normalise_october_candidate_reference.R"),
 c("reference",file.path(output,"combined.csv"),file.path(output,"fast_stable")))
run("compare",file.path(base,"compare_real_candidate_pairs.R"),
 c("--reference",file.path(output,"reference_stable","reference_pairs.csv"),
 "--candidate",file.path(output,"fast_stable","reference_pairs.csv"),
 "--output-dir",file.path(output,"parity")))
write_json(list(schema="w01-fast-october-candidate-stage-benchmark-v1",
 historic_manifestations=135997L,appended_manifestations=60L,
 frozen_pair_count=nrow(reference),candidate_pair_count=nrow(pairs),
 measured_candidate_generation_seconds=round(sum(vapply(stages[c("exact","fuzzy","combine")],
 function(z)z$elapsed_seconds,numeric(1))),3),
 measured_complete_pipeline=FALSE,production_modified=FALSE,
 stages=stages),file.path(output,"benchmark.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: isolated real October candidate-stage benchmark and scientific pair parity\\n")
